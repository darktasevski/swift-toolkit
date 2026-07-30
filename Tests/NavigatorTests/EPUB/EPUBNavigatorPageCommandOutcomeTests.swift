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
                documentIsCurrent: false,
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
                documentIsCurrent: true,
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
                documentIsCurrent: true,
                taskIsCancelled: false
            ),
            .miss
        )
    }

    func testDocumentAvailableAtACommandGateIsReportedAsMiss() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .documentAvailable(generation: 7),
                targetIsCurrent: true,
                documentIsCurrent: false,
                taskIsCancelled: false
            ),
            .miss
        )
    }

    func testCancelledReadySpreadWaitIsReportedAsCancelled() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .cancelled,
                targetIsCurrent: true,
                documentIsCurrent: false,
                taskIsCancelled: false
            ),
            .cancelled
        )
    }

    func testCallerCancellationWinsOverAReadyCurrentSpread() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .ready(
                    generation: 7,
                    frameCapability: EPUBSpreadFrameCapability()
                ),
                targetIsCurrent: true,
                documentIsCurrent: true,
                taskIsCancelled: true
            ),
            .cancelled
        )
    }

    func testReadySpreadWaitSelectionFollowsALiveDocumentCapability() {
        let capability = EPUBSpreadFrameCapability()

        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadWaitTarget(
                currentCapability: capability,
                currentGeneration: 7
            ),
            .document(capability)
        )
    }

    func testReadySpreadWaitSelectionFallsBackToTheCurrentGeneration() {
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadWaitTarget(
                currentCapability: nil,
                currentGeneration: 7
            ),
            .generation(7)
        )
    }

    func testGenerationFallbackUsesTheReadyResultsCapabilityOrRefusesWhenItIsGone() {
        let readyCapability = EPUBSpreadFrameCapability()
        let outcome = EPUBSpreadReadiness.WaitOutcome.ready(
            generation: 7,
            frameCapability: readyCapability
        )

        XCTAssertTrue(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: outcome,
                currentCapability: readyCapability,
                currentGeneration: 7
            )
        )
        XCTAssertFalse(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: outcome,
                currentCapability: nil,
                currentGeneration: 7
            )
        )
    }

    func testDocumentCurrencyToleratesAGenerationThatAdvancedAfterReadinessPublished() {
        // The `>=` rather than `==`. The bounded wait resumes through a task group, so several
        // main-actor suspensions separate the `.ready` publish from the currency read, and a
        // same-document mutation can land in any of them. An equality gate turns that into a
        // silent `.cancelled` — the exact bug this path exists to fix, one line further down.
        let capability = EPUBSpreadFrameCapability()

        XCTAssertTrue(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: .ready(generation: 7, frameCapability: capability),
                currentCapability: capability,
                currentGeneration: 9
            )
        )
        XCTAssertTrue(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: .ready(generation: 7, frameCapability: capability),
                currentCapability: capability,
                currentGeneration: 7
            )
        )
    }

    func testDocumentCurrencyRejectsAReplacedOrAbsentDocument() {
        let capability = EPUBSpreadFrameCapability()

        XCTAssertFalse(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: .ready(generation: 7, frameCapability: capability),
                currentCapability: EPUBSpreadFrameCapability(),
                currentGeneration: 7
            )
        )
        // Nil is the document being gone outright — a replacement load, invalidation or
        // `pagehide`. Distinct from a different capability only in cause, not in verdict.
        XCTAssertFalse(
            EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                for: .ready(generation: 7, frameCapability: capability),
                currentCapability: nil,
                currentGeneration: 7
            )
        )
    }

    func testDocumentCurrencyIsFalseForEveryOutcomeThatBoundNoDocument() {
        let capability = EPUBSpreadFrameCapability()
        let outcomes: [EPUBSpreadReadiness.WaitOutcome] = [
            .timedOut,
            .cancelled,
            .invalidated,
            .failed(generation: 7),
            .documentAvailable(generation: 7),
        ]

        for outcome in outcomes {
            XCTAssertFalse(
                EPUBNavigatorViewController.readySpreadDocumentIsCurrent(
                    for: outcome,
                    currentCapability: capability,
                    currentGeneration: 7
                ),
                "\(outcome) bound no document, so no world of its can be current"
            )
        }
    }

    func testReadinessPublishedForAReplacedDocumentIsReportedAsCancelled() {
        // The document the wait resolved against is gone by the time the caller
        // resumes — a replacement load, invalidation or `pagehide`. The landing
        // bound a world that no longer exists, so the command was superseded and
        // must stop SILENTLY rather than advance a fallback rung against the
        // document that replaced it.
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .ready(
                    generation: 7,
                    frameCapability: EPUBSpreadFrameCapability()
                ),
                targetIsCurrent: true,
                documentIsCurrent: false,
                taskIsCancelled: false
            ),
            .cancelled
        )
    }

    func testAStaleDocumentDoesNotDowngradeATimeoutToCancellation() {
        // Document currency gates only a `.ready` outcome, because only a
        // `.ready` outcome bound a document. A timeout or failure resolved
        // against nothing, so its own disposition governs: `.miss`, which lets
        // the caller's next fallback rung run. Folding currency into the top
        // guard turned every such outcome into a silent `.cancelled` — a tap
        // that does nothing, with no fallback and no logged failure.
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .timedOut,
                targetIsCurrent: true,
                documentIsCurrent: false,
                taskIsCancelled: false
            ),
            .miss
        )
        XCTAssertEqual(
            EPUBNavigatorViewController.readySpreadNavigationDisposition(
                for: .failed(generation: 7),
                targetIsCurrent: true,
                documentIsCurrent: false,
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

    // MARK: - CSS settings mutation outcome

    func testSucceededCSSMutationSucceeds() {
        XCTAssertEqual(
            EPUBSpreadView.cssMutationOutcome(succeeded: true, cancelled: false),
            .succeeded
        )
    }

    func testCancelledCSSMutationIsSupersededNotFailed() {
        // A cancelled CSS mutation was replaced by a newer settings change or a
        // teardown; releasing it as superseded keeps the document command-ready
        // rather than revoking it as a genuine failure would.
        XCTAssertEqual(
            EPUBSpreadView.cssMutationOutcome(succeeded: false, cancelled: true),
            .superseded
        )
    }

    func testFailedCSSMutationFails() {
        XCTAssertEqual(
            EPUBSpreadView.cssMutationOutcome(succeeded: false, cancelled: false),
            .failed
        )
    }

    func testSucceededCSSMutationWinsOverLateCancellation() {
        // A write that completed before cancellation landed is a success, not a
        // supersession — the DOM already carries the new CSS.
        XCTAssertEqual(
            EPUBSpreadView.cssMutationOutcome(succeeded: true, cancelled: true),
            .succeeded
        )
    }
}
