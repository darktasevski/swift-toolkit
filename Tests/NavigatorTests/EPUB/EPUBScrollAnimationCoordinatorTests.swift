//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBScrollAnimationCoordinatorTests: XCTestCase {
    func testCancellationResumesOnlyTheMatchingPendingRequest() async {
        let coordinator = EPUBScrollAnimationCoordinator()
        var finished = false
        let waiter = Task { @MainActor in
            await coordinator.waitUntilSettled()
            finished = true
        }

        waiter.cancel()
        _ = await waiter.value

        XCTAssertTrue(finished)
        XCTAssertFalse(coordinator.hasPendingRequest)
    }

    func testStaleRequestCannotClearNewerRequest() async throws {
        let coordinator = EPUBScrollAnimationCoordinator()
        let first = Task { @MainActor in
            await coordinator.waitUntilSettled()
        }
        await waitUntil { coordinator.hasPendingRequest }
        let staleRequest = try XCTUnwrap(coordinator.takePendingRequest())
        let second = Task { @MainActor in
            await coordinator.waitUntilSettled()
        }
        await waitUntil { coordinator.hasPendingRequest }

        XCTAssertNil(coordinator.takePendingRequest(matching: staleRequest))
        XCTAssertTrue(coordinator.hasPendingRequest)

        staleRequest.resume()
        await first.value
        coordinator.finish()
        await second.value
    }

    func testCancellingStaleFirstWaiterAfterNewerWaiterPreservesNewerRequest() async {
        let coordinator = EPUBScrollAnimationCoordinator()
        let first = Task { @MainActor in
            await coordinator.waitUntilSettled()
        }
        await waitUntil { coordinator.hasPendingRequest }

        let second = Task { @MainActor in
            await coordinator.waitUntilSettled()
        }
        await waitUntil { coordinator.hasPendingRequest }

        first.cancel()
        await Task.yield()

        XCTAssertTrue(coordinator.hasPendingRequest)
        coordinator.finish()
        await first.value
        await second.value
    }

    func testTakingPendingRequestClearsItBeforeResumption() async throws {
        let coordinator = EPUBScrollAnimationCoordinator()
        var finished = false
        let waiter = Task { @MainActor in
            await coordinator.waitUntilSettled()
            finished = true
        }
        await waitUntil { coordinator.hasPendingRequest }

        let request = try XCTUnwrap(coordinator.takePendingRequest())
        XCTAssertFalse(coordinator.hasPendingRequest)
        XCTAssertFalse(finished)

        request.resume()
        _ = await waiter.value
        XCTAssertTrue(finished)
    }

    /// A superseded wait's fallback timer cannot end the wait that replaced
    /// it; that wait ends on its own timer.
    func testASupersededWaitsFallbackLeavesTheNewerWaitToItsOwnTimer() async throws {
        let coordinator = EPUBScrollAnimationCoordinator()
        let clock = ContinuousClock()
        let firstStart = clock.now
        let first = Task { @MainActor in
            await coordinator.waitUntilSettled()
        }
        await waitUntil { coordinator.hasPendingRequest }
        // Holding the superseded request keeps its fallback timer live, so the
        // timer reaches the request match rather than a nil weak reference.
        let superseded = try XCTUnwrap(coordinator.takePendingRequest())
        superseded.resume()
        await first.value
        try await clock.sleep(for: .milliseconds(400))

        let secondStart = clock.now
        // The superseded timer fires 800 ms after `firstStart`; a stall that
        // lets it fire before the newer wait exists leaves nothing under test.
        try XCTSkipIf(
            firstStart.duration(to: secondStart) >= .milliseconds(800),
            "The main actor stalled past the superseded wait's fallback"
        )
        await coordinator.waitUntilSettled()

        XCTAssertGreaterThanOrEqual(
            secondStart.duration(to: clock.now),
            .milliseconds(800),
            "The superseded wait's fallback ended the newer wait"
        )
        XCTAssertEqual(coordinator.lastSettlementForTesting, .fellBack)
        withExtendedLifetime(superseded) {}
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        iterations: Int = 100
    ) async {
        for _ in 0 ..< iterations {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}
