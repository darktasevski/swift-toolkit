//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

@MainActor
final class EPUBNavigatorPageCommandOutcomeTests: XCTestCase {
    func testSucceededPageCommandProceedsToLandingAndJumpNotification() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .succeeded),
            .landed
        )
    }

    func testFailedPageCommandIsReportedAsMissWithoutFallback() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .failed),
            .miss
        )
    }

    func testCancelledPageCommandIsReportedAsCancelledWithoutFallback() {
        XCTAssertEqual(
            EPUBNavigatorViewController.navigationDisposition(for: .cancelled),
            .cancelled
        )
    }

    func testSucceededPageTurnIsReportedAsMoved() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .succeeded),
            .moved
        )
    }

    func testBoundaryPageTurnFallsBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .boundary),
            .crossResource
        )
    }

    func testFailedPageTurnDoesNotFallBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .failed),
            .failed
        )
    }

    func testCancelledPageTurnDoesNotFallBackToCrossResourceNavigation() {
        XCTAssertEqual(
            EPUBNavigatorViewController.pageTurnNavigationDisposition(for: .cancelled),
            .cancelled
        )
    }

    func testInvalidatedReadySpreadWaitIsReportedAsCancelled() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .invalidated,
                targetIsCurrent: true,
                generationIsCurrent: false,
                taskIsCancelled: false
            ),
            .cancelled
        )
    }

    func testReplacedReadySpreadTargetIsReportedAsCancelled() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .ready(
                    generation: 7,
                    frameCapability: EPUBSpreadFrameCapability()
                ),
                targetIsCurrent: false,
                generationIsCurrent: true,
                taskIsCancelled: false
            ),
            .cancelled
        )
    }

    func testCurrentReadySpreadTimeoutIsReportedAsMiss() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .timedOut,
                targetIsCurrent: true,
                generationIsCurrent: true,
                taskIsCancelled: false
            ),
            .miss
        )
    }

    func testBridgeVerificationIsNotAnimatedAfterAResourceHop() {
        // A cross-resource landing positions the document at the FULL target
        // locator during spread initialization (pre-reveal), so the bridge run
        // that follows is a verification of an already-positioned page — it
        // must never animate, or the user sees a second scroll after reveal.
        XCTAssertFalse(
            EPUBNavigatorViewController.bridgeCommandAnimated(
                requestedAnimated: true,
                didHopToResource: true
            )
        )
    }

    func testBridgeCommandKeepsCallerAnimationWithoutAResourceHop() {
        // A same-resource landing has no pre-positioning hop: the bridge IS the
        // user-visible motion and honors the caller's animation request.
        XCTAssertTrue(
            EPUBNavigatorViewController.bridgeCommandAnimated(
                requestedAnimated: true,
                didHopToResource: false
            )
        )
        XCTAssertFalse(
            EPUBNavigatorViewController.bridgeCommandAnimated(
                requestedAnimated: false,
                didHopToResource: false
            )
        )
    }
}
