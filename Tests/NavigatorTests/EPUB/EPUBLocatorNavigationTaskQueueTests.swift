//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBLocatorNavigationTaskQueueTests: XCTestCase {
    func testPreservesLandedAndMissTerminalOutcomes() async {
        let queue = EPUBLocatorNavigationTaskQueue()

        let landed = await queue.run { .landed }
        let miss = await queue.run { .miss }

        XCTAssertEqual(landed, .landed)
        XCTAssertEqual(miss, .miss)
    }

    func testLatestRequestCancelsPredecessorWithoutConflatingSuccessorMiss() async {
        let queue = EPUBLocatorNavigationTaskQueue()
        var firstStarted = false
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await queue.run {
                firstStarted = true
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
                return .landed
            }
        }
        await waitUntil { firstStarted }

        let second = Task { @MainActor in
            await queue.run { .miss }
        }
        await Task.yield()
        releaseFirst?.resume()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(secondOutcome, .miss)
    }

    func testUnresponsivePredecessorReleasesSuccessorWhenAcknowledgementBudgetElapses() async {
        // A predecessor that never observes cancellation must not stall the
        // successor forever: once the bounded acknowledgement budget elapses,
        // the successor runs and returns its own outcome. The budget is driven
        // by an injected delay the test resolves deterministically.
        var releaseBudget: CheckedContinuation<Void, Never>?
        let queue = EPUBLocatorNavigationTaskQueue(
            predecessorAcknowledgement: {
                await withCheckedContinuation { releaseBudget = $0 }
            }
        )

        var firstStarted = false
        var releaseFirstBody: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await queue.run {
                firstStarted = true
                // Ignores cancellation; only the test releases it, at teardown.
                await withCheckedContinuation { releaseFirstBody = $0 }
                return .landed
            }
        }
        await waitUntil { firstStarted }

        var secondRan = false
        let second = Task { @MainActor in
            await queue.run {
                secondRan = true
                return .miss
            }
        }

        // The successor blocks on the predecessor acknowledgement budget: its
        // operation must not run until the budget is released.
        await waitUntil { releaseBudget != nil }
        XCTAssertFalse(secondRan)

        // The budget elapses without the predecessor ever acknowledging.
        releaseBudget?.resume()

        await waitUntil { secondRan }
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .miss)

        // Teardown: unblock the stuck predecessor so no continuation leaks.
        releaseFirstBody?.resume()
        _ = await first.value
    }

    func testSupersedingRunFiresCancellationRelayBeforeAcknowledgingPredecessor() async {
        // Design Y ordering: a superseding request must positively signal the
        // predecessor's in-flight bridge (the relay round-trip) BEFORE it waits
        // for the bounded predecessor acknowledgement, and only then run its own
        // operation. The relay aborts the predecessor's suspended JS so its
        // acknowledgement arrives promptly instead of after the full frame
        // timeout. All closures run on the MainActor, so the shared recorder is
        // race-free.
        var order: [String] = []
        let queue = EPUBLocatorNavigationTaskQueue(
            predecessorAcknowledgement: { order.append("ack") }
        )

        var firstStarted = false
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await queue.run {
                firstStarted = true
                await withCheckedContinuation { releaseFirst = $0 }
                return .landed
            }
        }
        await waitUntil { firstStarted }

        let second = Task { @MainActor in
            await queue.run {
                order.append("op")
                return .miss
            } cancellationRelay: {
                order.append("relay")
            }
        }

        // The successor proceeds through relay → ack → op without the
        // predecessor ever acknowledging on its own (the injected ack returns
        // immediately, standing in for the bounded budget elapsing).
        await waitUntil { order.contains("op") }
        releaseFirst?.resume()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(secondOutcome, .miss)
        XCTAssertEqual(order, ["relay", "ack", "op"])
    }

    func testSuccessorCancelledWhileAwaitingAcknowledgementReturnsCancelledPromptly() async {
        // A successor that is itself cancelled while waiting for the predecessor
        // acknowledgement must return .cancelled promptly, without running its
        // operation and without waiting out the predecessor or the budget —
        // both of which are wired here to never resolve on their own.
        let queue = EPUBLocatorNavigationTaskQueue(
            predecessorAcknowledgement: {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )

        var firstStarted = false
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await queue.run {
                firstStarted = true
                await withCheckedContinuation { releaseFirst = $0 }
                return .landed
            }
        }
        await waitUntil { firstStarted }

        var secondOperationRan = false
        let second = Task { @MainActor in
            await queue.run {
                secondOperationRan = true
                return .miss
            }
        }
        // Let the successor reach the (never-resolving) acknowledgement wait.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(secondOperationRan)

        second.cancel()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .cancelled)
        XCTAssertFalse(secondOperationRan, "a cancelled successor must not run its operation")

        // Teardown: unblock the stuck predecessor so no continuation leaks.
        releaseFirst?.resume()
        _ = await first.value
    }

    func testChainedSupersessionCancelsEveryPredecessorButTheLatest() async {
        // Three rapid requests where the middle one is itself mid-acknowledgement
        // when the third supersedes it: the first two must both report
        // .cancelled and only the latest runs its operation. The budget blocks
        // so each successor is provably parked in its acknowledgement wait.
        var budgetContinuations: [CheckedContinuation<Void, Never>] = []
        let queue = EPUBLocatorNavigationTaskQueue(
            predecessorAcknowledgement: {
                await withCheckedContinuation { budgetContinuations.append($0) }
            }
        )

        var firstStarted = false
        var releaseFirst: CheckedContinuation<Void, Never>?
        let first = Task { @MainActor in
            await queue.run {
                firstStarted = true
                await withCheckedContinuation { releaseFirst = $0 }
                return .landed
            }
        }
        await waitUntil { firstStarted }

        let second = Task { @MainActor in await queue.run { .landed } }
        await waitUntil { budgetContinuations.count == 1 }

        var thirdRan = false
        let third = Task { @MainActor in
            await queue.run {
                thirdRan = true
                return .miss
            }
        }
        await waitUntil { budgetContinuations.count == 2 }

        // Release both parked budgets; the middle request is already cancelled by
        // the third, so it returns .cancelled regardless.
        for continuation in budgetContinuations {
            continuation.resume()
        }

        let secondOutcome = await second.value
        let thirdOutcome = await third.value
        XCTAssertEqual(secondOutcome, .cancelled)
        XCTAssertEqual(thirdOutcome, .miss)
        XCTAssertTrue(thirdRan)

        // Teardown: unblock the original predecessor and drain its outcome.
        releaseFirst?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
    }

    func testFirstRunNeverFiresCancellationRelay() async {
        // With no predecessor there is no in-flight bridge to cancel: the relay
        // must not fire, so a solitary navigation never issues a spurious
        // invalidate round-trip.
        var relayFired = false
        let queue = EPUBLocatorNavigationTaskQueue()

        let outcome = await queue.run {
            .landed
        } cancellationRelay: {
            relayFired = true
        }

        XCTAssertEqual(outcome, .landed)
        XCTAssertFalse(relayFired)
    }

    func testCancelPendingCancelsActiveNavigationToCancelled() async {
        // A view-lifecycle teardown (spread reload / process-termination rebuild)
        // must give the in-flight navigation an explicit .cancelled terminal
        // outcome, not rely on the operation self-resolving once its webview is
        // torn down three layers away.
        let queue = EPUBLocatorNavigationTaskQueue()

        var started = false
        var releaseOperation: CheckedContinuation<Void, Never>?
        let run = Task { @MainActor in
            await queue.run {
                started = true
                await withCheckedContinuation { releaseOperation = $0 }
                return .landed
            }
        }
        await waitUntil { started }

        queue.cancelPending()

        // The parked operation drains once released; the post-operation flip
        // reports .cancelled because the task was cancelled.
        releaseOperation?.resume()
        let outcome = await run.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testCancelPendingFiresCancellationRelayToAbortInFlightCommand() async {
        // The teardown drain must also fire the active request's relay so the
        // suspended JavaScript command is positively invalidated, matching the
        // supersession path rather than leaving JS to self-error on a dead
        // webview.
        var relayFired = false
        let queue = EPUBLocatorNavigationTaskQueue()

        var started = false
        var releaseOperation: CheckedContinuation<Void, Never>?
        let run = Task { @MainActor in
            await queue.run {
                started = true
                await withCheckedContinuation { releaseOperation = $0 }
                return .landed
            } cancellationRelay: {
                relayFired = true
            }
        }
        await waitUntil { started }

        queue.cancelPending()
        await waitUntil { relayFired }

        releaseOperation?.resume()
        _ = await run.value
        XCTAssertTrue(relayFired)
    }

    func testCancelPendingWithNoActiveNavigationIsNoOpAndQueueStaysUsable() async {
        // Draining an idle queue must be a clean no-op: there is no entry, so no
        // relay fires, and a subsequent navigation runs normally.
        var relayFired = false
        let queue = EPUBLocatorNavigationTaskQueue()

        queue.cancelPending()
        await Task.yield()
        XCTAssertFalse(relayFired)

        let outcome = await queue.run {
            .landed
        } cancellationRelay: {
            relayFired = true
        }
        XCTAssertEqual(outcome, .landed)
        XCTAssertFalse(relayFired)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0 ..< 100 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}
