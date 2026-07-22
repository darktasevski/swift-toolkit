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
