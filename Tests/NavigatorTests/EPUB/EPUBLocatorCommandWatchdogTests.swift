//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import Synchronization
import XCTest

/// `callAsyncJavaScript` has no timeout of its own. When the page's main thread is
/// wedged — a runaway script, a stalled compositor, a content process that hangs
/// without ever delivering `webViewWebContentProcessDidTerminate` — the continuation
/// is simply never resumed, and every deadline above it becomes decorative: the
/// operation-wide budget cannot expire a wait that is not bounded by anything.
///
/// These pin the native watchdog that makes the deadline real at that boundary, and
/// the injected monotonic clock that makes it observable without waiting in real time.
final class EPUBLocatorCommandWatchdogTests: XCTestCase {
    /// `nonisolated static` so the `@Sendable` clock closures below can read it:
    /// `XCTestCase` is not `Sendable`, so an instance property is unreachable from one.
    private nonisolated static let base = ContinuousClock().now

    /// A sleeper that never returns. Racing against it proves a fast operation is
    /// returned on its own completion rather than after the deadline elapses — with a
    /// real clock that assertion could only be made by waiting out the whole budget.
    private static let neverFires: @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    private static let firesImmediately: @Sendable (ContinuousClock.Instant) async throws -> Void = { _ in }

    @MainActor
    func testAPromptOperationReturnsItsOwnValueWithoutWaitingOutTheDeadline() async throws {
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .milliseconds(5000))
        let clock = EPUBMonotonicClock(now: { Self.base }, sleep: Self.neverFires)

        let value = try await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
            "landed"
        }

        XCTAssertEqual(value, "landed")
    }

    /// The failure this exists for: a call that never returns. Without the watchdog the
    /// enclosing navigation hangs forever and reports no outcome at all.
    @MainActor
    func testANonReturningOperationIsBoundedByTheDeadline() async {
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .milliseconds(5000))
        let clock = EPUBMonotonicClock(now: { Self.base }, sleep: Self.firesImmediately)

        do {
            _ = try await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
                try await Task.sleep(for: .seconds(3600))
                return "never"
            }
            XCTFail("A non-returning operation must not be allowed to complete")
        } catch is EPUBLocatorCommandWatchdog.Expired {
            // Expected.
        } catch {
            XCTFail("Expected the watchdog's own expiry, got \(type(of: error))")
        }
    }

    /// An operation started with nothing left to spend is not started at all: a rung
    /// that arrives already over budget must not buy one more round-trip.
    @MainActor
    func testAnExhaustedDeadlineNeverStartsTheOperation() async {
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .milliseconds(250))
        let clock = EPUBMonotonicClock(
            now: { Self.base.advanced(by: .milliseconds(4000)) },
            sleep: Self.neverFires
        )
        let didRun = Mutex(false)

        do {
            _ = try await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
                didRun.withLock { $0 = true }
                return "ran"
            }
            XCTFail("An exhausted deadline must not run the operation")
        } catch is EPUBLocatorCommandWatchdog.Expired {
            XCTAssertFalse(didRun.withLock { $0 }, "The operation must not have been started")
        } catch {
            XCTFail("Expected the watchdog's own expiry, got \(type(of: error))")
        }
    }

    /// The clock-injection proof: the deadline is nowhere near expiry in real time, but
    /// the authority reads "now" through the injected clock, so the scripted instant
    /// alone decides. A `ContinuousClock()` read inside the watchdog would pass the
    /// remaining-budget check here and hang on `neverFires` instead.
    @MainActor
    func testExpiryIsDecidedByTheInjectedClockRatherThanRealTime() async {
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .seconds(3600))
        let clock = EPUBMonotonicClock(
            now: { Self.base.advanced(by: .seconds(7200)) },
            sleep: Self.neverFires
        )

        do {
            _ = try await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) { "ran" }
            XCTFail("The injected clock reports the deadline as spent")
        } catch is EPUBLocatorCommandWatchdog.Expired {
            // Expected.
        } catch {
            XCTFail("Expected the watchdog's own expiry, got \(type(of: error))")
        }
    }

    /// The watchdog bounds the wait; it does not reclassify what the operation reports.
    /// A WebKit failure must stay distinguishable from an unresponsive call, because the
    /// two map to different truths upstream (a current-document failure is a miss; a
    /// call that never returned is the deadline being enforced).
    @MainActor
    func testAnOperationsOwnFailurePropagatesRatherThanBecomingAnExpiry() async {
        struct WebKitFailure: Error {}
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .milliseconds(5000))
        let clock = EPUBMonotonicClock(now: { Self.base }, sleep: Self.neverFires)

        do {
            _ = try await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
                throw WebKitFailure()
            }
            XCTFail("The operation's failure must surface")
        } catch is WebKitFailure {
            // Expected.
        } catch {
            XCTFail("Expected the operation's own error, got \(type(of: error))")
        }
    }

    /// The sleeper is asked to wait until the operation deadline's absolute instant, not
    /// for a duration computed at the call site — the same anti-re-arming property the
    /// deadline arithmetic has, extended to the watchdog.
    @MainActor
    func testTheWatchdogSleepsUntilTheOperationsAbsoluteExpiryInstant() async {
        let deadline = EPUBLocatorOperationDeadline(startingAt: Self.base, budget: .milliseconds(5000))
        let requested = Mutex<ContinuousClock.Instant?>(nil)
        let clock = EPUBMonotonicClock(
            now: { Self.base },
            sleep: { instant in requested.withLock { $0 = instant } }
        )

        _ = try? await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
            try await Task.sleep(for: .seconds(3600))
            return "never"
        }

        XCTAssertEqual(requested.withLock { $0 }, deadline.expiresAt)
    }

    /// The production clock must actually be monotonic and actually wait: the default
    /// binding is what ships, and a stubbed-out default would make every test above
    /// vacuous.
    func testTheContinuousBindingAdvancesAndWaits() async throws {
        let clock = EPUBMonotonicClock.continuous
        let start = clock.now()
        try await clock.sleep(start.advanced(by: .milliseconds(2)))
        XCTAssertGreaterThanOrEqual(clock.now(), start.advanced(by: .milliseconds(2)))
    }
}
