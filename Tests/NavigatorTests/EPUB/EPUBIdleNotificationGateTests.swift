//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBIdleNotificationGateTests: XCTestCase {
    func testRequestWhileIdleRunsImmediately() {
        let gate = EPUBIdleNotificationGate(isIdle: true)

        XCTAssertTrue(gate.request())
    }

    func testRequestWhileBusyStashesUntilIdleEdge() {
        let gate = EPUBIdleNotificationGate(isIdle: false)

        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.setIdle(true))
    }

    func testMultipleBusyRequestsDrainExactlyOnce() {
        let gate = EPUBIdleNotificationGate(isIdle: false)

        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.request())

        // The busy→idle edge releases the coalesced request exactly once.
        XCTAssertTrue(gate.setIdle(true))
        XCTAssertFalse(gate.setIdle(true))
    }

    func testIdleEdgeWithoutPendingRequestDoesNotRun() {
        let gate = EPUBIdleNotificationGate(isIdle: false)

        XCTAssertFalse(gate.setIdle(true))
    }

    func testDrainClearsPendingSoLaterRequestReevaluates() {
        let gate = EPUBIdleNotificationGate(isIdle: false)

        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.setIdle(true))

        // Already idle and drained: a new request runs immediately.
        XCTAssertTrue(gate.request())
    }

    func testBusyTransitionAfterDrainRequiresNewRequest() {
        let gate = EPUBIdleNotificationGate(isIdle: true)

        XCTAssertTrue(gate.request())

        // Going busy without a fresh request must not re-fire on the next idle.
        XCTAssertFalse(gate.setIdle(false))
        XCTAssertFalse(gate.setIdle(true))
    }

    func testRequestWhileBusyThenBusyAgainStillDrainsOnFirstIdle() {
        let gate = EPUBIdleNotificationGate(isIdle: false)

        XCTAssertFalse(gate.request())
        // A redundant busy transition preserves the pending request.
        XCTAssertFalse(gate.setIdle(false))
        XCTAssertTrue(gate.setIdle(true))
    }
}
