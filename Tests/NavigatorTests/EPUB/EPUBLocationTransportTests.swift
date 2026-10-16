//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
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

        XCTAssertEqual(fixture.log, ["slotFreed", "completed"])
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

        XCTAssertEqual(fixture.log, ["expired", "slotFreed", "lateCompletion"])
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

        XCTAssertEqual(fixture.log, ["slotFreed"], "A closed call reported to its caller")
        XCTAssertTrue(fixture.start())
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

        XCTAssertEqual(fixture.events, [.handshakeFailed(capability, .injectionFailed)])
    }

    /// A completed injection proves nothing on its own: the frame must still
    /// register, and it is waited for only until the attempt's deadline.
    func test_aHandshakeWaitsForTheRegistrationOnlyUntilItsDeadline() throws {
        let fixture = try BridgeFixture()
        let capability = EPUBSpreadFrameCapability()
        fixture.bridge.setFrameCapability(capability)

        fixture.scripts.complete(0, with: .success(NSNull()))
        XCTAssertEqual(fixture.events, [], "A completed injection was reported before its deadline")
        fixture.deadlines.advance(by: fixture.budget)

        XCTAssertEqual(fixture.events, [.handshakeFailed(capability, .registrationMissing)])
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
    private(set) var log: [String] = []

    init() {
        transport = EPUBLocationTransport(scheduler: deadlines.scheduler)
        transport.onSlotFreed = { [unowned self] in log.append("slotFreed") }
        transport.onLateCompletion = { [unowned self] in log.append("lateCompletion") }
    }

    @discardableResult
    func start(until deadline: EPUBLocatorOperationDeadline? = nil) -> Bool {
        transport.start(
            until: deadline ?? EPUBLocatorOperationDeadline(startingAt: deadlines.now, budget: budget),
            invocation: calls.invocation,
            deliver: { [unowned self] delivery in
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

    var count: Int {
        calls.count
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
