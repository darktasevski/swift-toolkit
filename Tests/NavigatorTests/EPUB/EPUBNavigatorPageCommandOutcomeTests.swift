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

    func testAppliedAnchorCommandLands() {
        XCTAssertEqual(
            EPUBReflowableSpreadView.anchorLandingDecision(for: .applied),
            .landed
        )
    }

    func testMissedAnchorCommandDegradesToProgression() {
        // A genuine miss (fuzzy anchor unresolvable in the live DOM, stale
        // index) must degrade to the coarse progression landing rather than
        // failing initialization outright — a blank, never-revealed spread
        // is worse than an imprecise one.
        XCTAssertEqual(
            EPUBReflowableSpreadView.anchorLandingDecision(for: .miss),
            .degradeToProgression
        )
    }

    func testCancelledAnchorCommandNeverDegrades() {
        // Cancellation must propagate, not degrade — collapsing it into the
        // progression fallback would let a cancelled command silently
        // "succeed" via the caller's own fallback ladder.
        XCTAssertEqual(
            EPUBReflowableSpreadView.anchorLandingDecision(for: .cancelled),
            .cancelled
        )
    }

    // MARK: - Spread-level readiness gate disposition

    func testReadyReadinessGateProceeds() {
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(
                for: .ready(
                    generation: 3,
                    frameCapability: EPUBSpreadFrameCapability()
                )
            ),
            .proceed
        )
    }

    func testCancelledReadinessGateIsCancelled() {
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(for: .cancelled),
            .cancelled
        )
    }

    func testInvalidatedReadinessGateIsCancelledNotFailed() {
        // A stale-lifecycle `.invalidated` — the generation advanced under the
        // wait via teardown, reload, or replacement — is an interruption, not a
        // hard failure. Surfacing it as `.cancelled` (mirroring the
        // controller-level `readySpreadNavigationDisposition`) keeps a caller's
        // progression / cross-resource fallback from fighting the new document.
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(for: .invalidated),
            .cancelled
        )
    }

    func testFailedReadinessGateFails() {
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(
                for: .failed(generation: 5)
            ),
            .failed
        )
    }

    func testTimedOutReadinessGateFails() {
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(for: .timedOut),
            .failed
        )
    }

    func testDocumentAvailableReadinessGateFails() {
        // A command-readiness gate never expects a bare document-availability
        // resolution; treat the unexpected outcome as a hard failure rather
        // than silently proceeding to write geometry.
        XCTAssertEqual(
            EPUBSpreadView.readinessGateDisposition(
                for: .documentAvailable(generation: 2)
            ),
            .failed
        )
    }
}
