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
