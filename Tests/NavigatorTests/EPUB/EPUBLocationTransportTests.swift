//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Synchronization
import WebKit
import XCTest

/// The location transport's accounting, driven with deadlines and actual
/// completions the test fires independently: one physical call per web view,
/// a deadline that ends the caller's wait without freeing the slot, and
/// completions that cannot keep their owner alive.
@MainActor
final class EPUBLocationTransportTests: XCTestCase {
    // MARK: - Transport

    func test_aCallInFlightKeepsEveryOtherCallOut() {
        let fixture = TransportFixture()

        XCTAssertTrue(fixture.start())
        for _ in 0 ..< 5 {
            XCTAssertFalse(fixture.start(), "A second call started while the first was outstanding")
        }

        XCTAssertEqual(fixture.calls.count, 1)
    }

    func test_aCompletionBeforeTheDeadlineIsDeliveredOnceAndFreesTheSlot() {
        let fixture = TransportFixture()
        fixture.start()

        fixture.calls.complete(0, with: .success("answer"))
        fixture.deadlines.advance(by: .seconds(10))

        XCTAssertEqual(fixture.log, ["slotFreed", "completed", "slotAvailable"])
        XCTAssertFalse(fixture.transport.isOccupied)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "The completed call's deadline is still armed")
        XCTAssertTrue(fixture.start(), "The freed slot refused the next call")
        XCTAssertEqual(fixture.calls.count, 2)
    }

    /// A deadline ends the caller's wait, not the call: the slot stays taken
    /// until WebKit actually answers, and that late answer is discarded.
    func test_anExpiredCallKeepsTheSlotUntilItActuallyCompletes() {
        let fixture = TransportFixture()
        fixture.start()

        fixture.deadlines.advance(by: fixture.budget)
        XCTAssertEqual(fixture.log, ["expired"])
        XCTAssertTrue(fixture.transport.isOccupied, "The deadline freed a slot WebKit still holds")
        for _ in 0 ..< 5 {
            XCTAssertFalse(fixture.start(), "A call started beside an expired one")
        }
        XCTAssertEqual(fixture.calls.count, 1)

        fixture.calls.complete(0, with: .success("late answer"))

        XCTAssertEqual(fixture.log, ["expired", "slotFreed", "lateCompletion", "slotAvailable"])
        XCTAssertFalse(fixture.transport.isOccupied)
        XCTAssertTrue(fixture.start())
    }

    func test_closingSilencesTheOutstandingCallWithoutFreeingItsSlot() {
        let fixture = TransportFixture()
        fixture.start()

        fixture.transport.close()
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "Closing left the deadline armed")
        fixture.deadlines.advance(by: fixture.budget)
        XCTAssertFalse(fixture.start(), "Closing freed a slot WebKit still holds")

        fixture.calls.complete(0, with: .success("answer"))

        XCTAssertEqual(fixture.log, ["slotFreed", "slotAvailable"], "A closed call reported to its caller")
        XCTAssertTrue(fixture.start())
    }

    func test_aCallAnsweredDuringItsInvocationIsDeliveredAndFreesTheSlot() {
        let fixture = TransportFixture()

        XCTAssertTrue(fixture.start(invocation: { $0(.success("answer")) }))

        XCTAssertEqual(fixture.log, ["slotFreed", "completed", "slotAvailable"])
        XCTAssertFalse(fixture.transport.isOccupied)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "The answered call's deadline is still armed")
    }

    func test_closingAnExpiredCallSilencesItsLateCompletion() {
        let fixture = TransportFixture()
        fixture.start()
        fixture.deadlines.advance(by: fixture.budget)

        fixture.transport.close()
        fixture.calls.complete(0, with: .success("late answer"))

        XCTAssertEqual(fixture.log, ["expired", "slotFreed", "slotAvailable"], "A closed call reported its late completion")
    }

    /// A slot refilled before the completion finishes reporting is not
    /// available, whether the owner's queued work or the caller took it.
    func test_aCompletionWhoseSlotIsRetakenReportsNoSlotAvailable() {
        let queued = TransportFixture()
        queued.start()
        queued.transport.onSlotFreed = { [unowned queued] in
            queued.log.append("slotFreed")
            queued.start()
        }
        queued.calls.complete(0, with: .success("answer"))
        XCTAssertEqual(queued.log, ["slotFreed", "completed"], "The owner's queued call took the slot")

        let caller = TransportFixture()
        caller.start(deliver: { [unowned caller] _ in
            caller.log.append("completed")
            caller.start()
        })
        caller.calls.complete(0, with: .success("answer"))
        XCTAssertEqual(caller.log, ["slotFreed", "completed"], "The caller's next call took the slot")
    }

    func test_aSpentDeadlineStartsNothing() {
        let fixture = TransportFixture()
        let spent = EPUBLocatorOperationDeadline(startingAt: fixture.deadlines.now, budget: .zero)

        XCTAssertFalse(fixture.start(until: spent))

        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertFalse(fixture.transport.isOccupied)
    }

    func test_anOutstandingCompletionDoesNotKeepTheTransportAlive() {
        let deadlines = ManualDeadlines()
        let calls = HeldCalls()
        var transport: EPUBLocationTransport? = EPUBLocationTransport(scheduler: deadlines.scheduler)
        weak let weakTransport = transport
        var delivered = false
        transport?.start(
            until: EPUBLocatorOperationDeadline(startingAt: deadlines.now, budget: .seconds(5)),
            invocation: calls.invocation,
            deliver: { _ in delivered = true }
        )

        transport = nil
        XCTAssertNil(weakTransport, "The outstanding completion kept the transport alive")

        calls.complete(0, with: .success("late answer"))
        deadlines.advance(by: .seconds(10))
        XCTAssertFalse(delivered, "A completion outliving its transport still reported")
    }

    // MARK: - Reflowable hand-off

    /// Neither an unanswered injection nor the hints and document changes that
    /// follow it may start a second call. Once the first call answers, only
    /// the latest capability is injected.
    func test_aHandshakeWaitsOutAnUnansweredCallThenInjectsOnlyTheLatestCapability() throws {
        let fixture = try BridgeFixture()
        let first = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(first)
        XCTAssertEqual(fixture.scripts.injectedCapabilities, [first])

        fixture.deadlines.advance(by: fixture.budget)
        XCTAssertEqual(fixture.events, [.handshakeFailed(first, .injectionUnresponsive)])
        for _ in 0 ..< 5 {
            XCTAssertEqual(try fixture.read(), .transportOccupied)
        }

        fixture.bridge.beginDocument()
        let second = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(second)
        let third = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(third)
        XCTAssertEqual(fixture.scripts.count, 1, "A call started beside the unanswered injection")

        fixture.scripts.complete(0, with: .success(NSNull()))

        XCTAssertEqual(fixture.events, [.handshakeFailed(first, .injectionUnresponsive), .lateCompletion])
        XCTAssertEqual(fixture.scripts.injectedCapabilities, [first, third])
    }

    func test_aHandshakeReportsAnInjectionWebKitRejected() throws {
        let fixture = try BridgeFixture()
        let capability = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(capability)

        fixture.scripts.complete(0, with: .failure(URLError(.cancelled)))
        fixture.deadlines.advance(by: fixture.budget)

        XCTAssertEqual(fixture.events, [.handshakeFailed(capability, .injectionFailed), .slotAvailable])
    }

    /// A completed injection proves nothing on its own: the frame must still
    /// register, and it is waited for only until the attempt's deadline.
    func test_aHandshakeWaitsForTheRegistrationOnlyUntilItsDeadline() throws {
        let fixture = try BridgeFixture()
        let capability = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(capability)

        fixture.scripts.complete(0, with: .success(NSNull()))
        XCTAssertEqual(fixture.events, [.slotAvailable], "A completed injection reported more than the freed slot")
        fixture.deadlines.advance(by: fixture.budget)

        XCTAssertEqual(fixture.events, [.slotAvailable, .handshakeFailed(capability, .registrationMissing)])
    }

    func test_aHandshakeThatNeverGetsTheTransportReportsIt() throws {
        let fixture = try BridgeFixture()
        fixture.bridge.setFrameCapability(EPUBSpreadFrameCapability())
        fixture.deadlines.advance(by: fixture.budget)

        let waiting = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(waiting)
        fixture.deadlines.advance(by: fixture.budget)

        XCTAssertEqual(fixture.events.last, .handshakeFailed(waiting, .transportOccupied))
        XCTAssertEqual(fixture.scripts.count, 1)
    }

    /// Re-issuing the capability starts a new attempt, and the superseded
    /// injection's answer is not that attempt's verdict.
    func test_aReissuedCapabilityIgnoresTheSupersededInjectionsAnswer() throws {
        let fixture = try BridgeFixture()
        let capability = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(capability)
        fixture.bridge.setFrameCapability(capability)

        fixture.scripts.complete(0, with: .failure(URLError(.cancelled)))

        XCTAssertEqual(fixture.scripts.injectedCapabilities, [capability, capability])
        XCTAssertEqual(fixture.events, [], "The superseded injection's failure ended the new attempt")
        fixture.deadlines.advance(by: fixture.budget)
        XCTAssertEqual(fixture.events, [.handshakeFailed(capability, .injectionUnresponsive)])
    }

    func test_aNewCapabilityIgnoresTheSupersededInjectionsAnswer() throws {
        let fixture = try BridgeFixture()
        let first = EPUBSpreadFrameCapability()
        let second = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(first)
        fixture.bridge.setFrameCapability(second)

        fixture.scripts.complete(0, with: .failure(URLError(.cancelled)))

        XCTAssertEqual(fixture.scripts.injectedCapabilities, [first, second])
        XCTAssertEqual(fixture.events, [], "The superseded injection's failure ended the new attempt")
        fixture.deadlines.advance(by: fixture.budget)
        XCTAssertEqual(fixture.events, [.handshakeFailed(second, .injectionUnresponsive)])
    }

    /// An injection answered before its invocation returns frees the slot
    /// while the attempt is already injecting, so it is not injected again.
    func test_anInjectionAnsweredDuringItsInvocationIsInjectedOnce() throws {
        let fixture = try BridgeFixture()
        let capability = EPUBSpreadFrameCapability()
        fixture.scripts.answerNextCallSynchronously(with: .failure(URLError(.cancelled)))

        fixture.bridge.setFrameCapability(capability)

        XCTAssertEqual(fixture.scripts.count, 1, "The attempt injected again into the slot its own answer freed")
        XCTAssertEqual(fixture.events, [.handshakeFailed(capability, .injectionFailed), .slotAvailable])
    }

    /// Clearing the spread drops a hand-off without a verdict, and its
    /// injection's late answer reports only the slot it frees.
    func test_revokingTheCapabilityDropsAHandshakeWithoutAVerdict() throws {
        let fixture = try BridgeFixture()
        fixture.bridge.setFrameCapability(EPUBSpreadFrameCapability())

        fixture.bridge.revokeFrameCapability()
        fixture.deadlines.advance(by: fixture.budget)
        fixture.scripts.complete(0, with: .success(NSNull()))

        XCTAssertEqual(fixture.events, [.slotAvailable])
    }

    func test_aNewDocumentDropsAHandshakeWithoutAVerdict() throws {
        let fixture = try BridgeFixture()
        fixture.bridge.setFrameCapability(EPUBSpreadFrameCapability())

        fixture.bridge.beginDocument()
        fixture.deadlines.advance(by: fixture.budget)

        XCTAssertEqual(fixture.events, [])
    }

    func test_anOutstandingInjectionDoesNotKeepTheBridgeAlive() throws {
        var fixture: BridgeFixture? = try BridgeFixture()
        fixture?.bridge.setFrameCapability(EPUBSpreadFrameCapability())
        let scripts = try XCTUnwrap(fixture?.scripts)
        weak let weakBridge = fixture?.bridge

        fixture = nil
        XCTAssertNil(weakBridge, "The outstanding injection kept the bridge alive")

        scripts.complete(0, with: .success(NSNull()))
    }

    func test_fixedLayoutInjectionStaysOffTheLocationTransport() throws {
        let fixture = try BridgeFixture(layout: .fixed)

        fixture.bridge.setFrameCapability(EPUBSpreadFrameCapability())

        XCTAssertEqual(fixture.scripts.count, 0)
        XCTAssertEqual(try fixture.read(), .frameUnavailable)
    }

    // MARK: - Read answers

    func test_aReadAnswerDecodesOnlyAnExactSampleForTheExpectedCapability() {
        let capability = EPUBSpreadFrameCapability()
        let id = capability.id.uuidString
        let sample: [String: Any] = ["capability": id, "first": 0.25, "last": 0.5]

        XCTAssertEqual(
            EPUBProgressionReadOutcome.decoding(sample, expecting: capability),
            .sample(EPUBProgressionSample(capability: capability, range: 0.25 ... 0.5))
        )

        let malformed: [(String, Any)] = [
            ("another capability", ["capability": UUID().uuidString, "first": 0.25, "last": 0.5]),
            ("a non-string capability", ["capability": 1, "first": 0.25, "last": 0.5]),
            ("an extra key", ["capability": id, "first": 0.25, "last": 0.5, "href": "x"]),
            ("a missing key", ["capability": id, "first": 0.25]),
            ("a Boolean end", ["capability": id, "first": NSNumber(value: false), "last": 0.5]),
            ("a string end", ["capability": id, "first": "0.25", "last": 0.5]),
            ("a non-finite end", ["capability": id, "first": Double.nan, "last": 0.5]),
            ("an end above 1", ["capability": id, "first": 0.25, "last": 1.5]),
            ("an end below 0", ["capability": id, "first": -0.25, "last": 0.5]),
            ("a reversed range", ["capability": id, "first": 0.5, "last": 0.25]),
            ("a bare number", 0.25),
        ]
        for (label, value) in malformed {
            XCTAssertEqual(
                EPUBProgressionReadOutcome.decoding(value, expecting: capability),
                .invalid,
                "An answer with \(label) was accepted"
            )
        }
    }

    /// `readProgression` answers `null` when the document cannot measure or no
    /// longer holds the capability, and WebKit delivers that as `NSNull`. The
    /// fixed script never answers `undefined`, which the completion-handler API
    /// would deliver as a boxed `nil`; such an answer fails closed.
    func test_aNullReadAnswerIsUnavailableAndAnUndefinedOneInvalid() {
        let capability = EPUBSpreadFrameCapability()
        let undefined = Any?.none as Any

        XCTAssertEqual(EPUBProgressionReadOutcome.decoding(NSNull(), expecting: capability), .unavailable)
        XCTAssertEqual(EPUBProgressionReadOutcome.decoding(undefined, expecting: capability), .invalid)
    }

    // MARK: - Clock-driven deadlines

    /// Long enough for a deadline the scheduler wrongly lets through to fire.
    private static let silenceWindow: Duration = .milliseconds(200)

    func test_aClockDeadlineFiresWhenItsSleepEnds() async throws {
        let gate = GatedClock()
        let instant = ContinuousClock().now.advanced(by: .seconds(5))
        var fired = false
        _ = EPUBDeadlineScheduler.clock(gate.clock).schedule(instant) { fired = true }
        try await gate.waitForSleep()
        XCTAssertEqual(gate.requestedInstants, [instant])

        gate.open(.success(()))

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !fired, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(fired, "The deadline never fired after its sleep ended")
    }

    /// A sleep that ends after the deadline was cancelled, as one racing the
    /// cancellation can, fires nothing.
    func test_aCancelledClockDeadlineStaysSilentWhenItsSleepEnds() async throws {
        let gate = GatedClock()
        var fired = false
        let scheduled = EPUBDeadlineScheduler.clock(gate.clock).schedule(ContinuousClock().now) { fired = true }
        try await gate.waitForSleep()

        scheduled.cancel()
        gate.open(.success(()))
        try await Task.sleep(for: Self.silenceWindow)

        XCTAssertFalse(fired, "A cancelled deadline fired")
    }

    func test_aClockDeadlineStaysSilentWhenItsSleepThrows() async throws {
        struct SleepFailed: Error {}
        let gate = GatedClock()
        var fired = false
        _ = EPUBDeadlineScheduler.clock(gate.clock).schedule(ContinuousClock().now) { fired = true }
        try await gate.waitForSleep()

        gate.open(.failure(SleepFailed()))
        try await Task.sleep(for: Self.silenceWindow)

        XCTAssertFalse(fired, "A deadline whose sleep threw fired")
    }
}

// MARK: - Fixtures

/// Deadlines that fire only when the test advances time past them.
@MainActor
final class ManualDeadlines {
    private struct Armed {
        let instant: ContinuousClock.Instant
        let action: @MainActor () -> Void
    }

    private(set) var now = ContinuousClock().now
    private var armed: [Int: Armed] = [:]
    private var lastID = 0

    var armedCount: Int {
        armed.count
    }

    var scheduler: EPUBDeadlineScheduler {
        EPUBDeadlineScheduler(
            now: { self.now },
            schedule: { instant, action in self.arm(at: instant, action) }
        )
    }

    /// Moves time on and fires, earliest first, every deadline due by then.
    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        let due = armed
            .filter { $0.value.instant <= now }
            .sorted { ($0.value.instant, $0.key) < ($1.value.instant, $1.key) }
        for (id, deadline) in due where armed.removeValue(forKey: id) != nil {
            deadline.action()
        }
    }

    private func arm(at instant: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> EPUBScheduledDeadline {
        lastID += 1
        let id = lastID
        armed[id] = Armed(instant: instant, action: action)
        return EPUBScheduledDeadline(cancel: { [weak self] in
            self?.armed[id] = nil
        })
    }
}

/// A clock whose sleep ends only when the test opens it, returning or throwing
/// as told whether or not the sleeping task was cancelled.
private final class GatedClock: Sendable {
    private struct State {
        var requestedInstants: [ContinuousClock.Instant] = []
        var sleeper: CheckedContinuation<Void, any Error>?
    }

    private let state = Mutex(State())

    var clock: EPUBMonotonicClock {
        EPUBMonotonicClock(
            now: { ContinuousClock().now },
            sleep: { instant in try await self.sleep(until: instant) }
        )
    }

    var requestedInstants: [ContinuousClock.Instant] {
        state.withLock { $0.requestedInstants }
    }

    /// Waits until a sleep is waiting for the gate.
    func waitForSleep() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.withLock({ $0.sleeper == nil }) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Setup: the deadline never started its sleep")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func open(_ outcome: Result<Void, any Error>) {
        let sleeper = state.withLock { state in
            defer { state.sleeper = nil }
            return state.sleeper
        }
        sleeper?.resume(with: outcome)
    }

    private func sleep(until instant: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.requestedInstants.append(instant)
                state.sleeper = continuation
            }
        }
    }
}

/// Physical calls held open until the test completes them.
@MainActor
private final class HeldCalls {
    private var completions: [@MainActor @Sendable (Result<Any, any Error>) -> Void] = []

    var count: Int {
        completions.count
    }

    var invocation: EPUBLocationTransport.Invocation {
        { completion in self.completions.append(completion) }
    }

    func complete(_ index: Int, with result: Result<Any, any Error>) {
        completions[index](result)
    }
}

@MainActor
private final class TransportFixture {
    let deadlines = ManualDeadlines()
    let calls = HeldCalls()
    let transport: EPUBLocationTransport
    let budget: Duration = .seconds(5)
    var log: [String] = []

    init() {
        transport = EPUBLocationTransport(scheduler: deadlines.scheduler)
        transport.onSlotFreed = { [unowned self] in log.append("slotFreed") }
        transport.onLateCompletion = { [unowned self] in log.append("lateCompletion") }
        transport.onSlotAvailable = { [unowned self] in log.append("slotAvailable") }
    }

    @discardableResult
    func start(
        until deadline: EPUBLocatorOperationDeadline? = nil,
        invocation: EPUBLocationTransport.Invocation? = nil,
        deliver: (@MainActor (EPUBLocationTransport.Delivery) -> Void)? = nil
    ) -> Bool {
        transport.start(
            until: deadline ?? EPUBLocatorOperationDeadline(startingAt: deadlines.now, budget: budget),
            invocation: invocation ?? calls.invocation,
            deliver: deliver ?? { [unowned self] delivery in
                switch delivery {
                case .completed:
                    log.append("completed")
                case .expired:
                    log.append("expired")
                }
            }
        )
    }
}

/// Location scripts held open until the test completes them.
@MainActor
final class HeldScripts {
    private struct Call {
        let script: String
        let arguments: [String: Any]
        let completion: @MainActor @Sendable (Result<Any, any Error>) -> Void
    }

    private var calls: [Call] = []
    private var synchronousAnswer: Result<Any, any Error>?

    var count: Int {
        calls.count
    }

    /// Answers the next call inside its invocation, before the invocation
    /// returns; later calls are held as usual.
    func answerNextCallSynchronously(with result: Result<Any, any Error>) {
        synchronousAnswer = result
    }

    /// The capability each injection carried, in call order.
    var injectedCapabilities: [EPUBSpreadFrameCapability] {
        calls
            .filter { $0.script.contains("acceptFrameCapability") }
            .compactMap { ($0.arguments["capability"] as? String).flatMap(UUID.init(uuidString:)) }
            .map { EPUBSpreadFrameCapability(id: $0) }
    }

    var invocation: EPUBLocatorCommandBridge.LocationScriptInvocation {
        { _, script, arguments, _, completion in
            self.calls.append(Call(script: script, arguments: arguments, completion: completion))
            if let answer = self.synchronousAnswer {
                self.synchronousAnswer = nil
                completion(answer)
            }
        }
    }

    func complete(_ index: Int, with result: Result<Any, any Error>) {
        calls[index].completion(result)
    }
}

/// A bridge attached to a web view that never loads anything, whose location
/// scripts and deadlines the test controls.
@MainActor
private final class BridgeFixture {
    let deadlines = ManualDeadlines()
    let scripts = HeldScripts()
    let webView = WKWebView()
    let bridge: EPUBLocatorCommandBridge
    let budget: Duration = .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
    private(set) var events: [EPUBLocationTransportEvent] = []

    init(layout: EPUBLocatorFrameLayout = .reflowable) throws {
        bridge = try EPUBLocatorCommandBridge(
            layout: layout,
            publicationBaseURL: XCTUnwrap(HTTPURL(string: "https://readium.test/")),
            deadlineScheduler: deadlines.scheduler,
            invokeLocationScript: scripts.invocation
        )
        bridge.attach(to: webView)
        bridge.onLocationTransportEvent = { [unowned self] event in
            events.append(event)
        }
    }

    func read() throws -> EPUBLocatorCommandBridge.ProgressionReadStart {
        try bridge.readProgression(
            targetHREF: XCTUnwrap(AnyURL(string: "chapter.xhtml")),
            deadline: EPUBLocatorOperationDeadline(startingAt: deadlines.now, budget: budget),
            completion: { _ in }
        )
    }
}
