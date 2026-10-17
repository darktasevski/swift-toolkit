//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

@MainActor
final class EPUBSpreadViewCommandOutcomeTests: XCTestCase {
    func testNavigatorForwardsNativeInputBeforeReportsAndExcludesSelection() throws {
        let fixture = makeFixture(layout: .reflowable)
        let locator = Locator(href: RelativeURL(path: "chapter.html")!.anyURL, mediaType: .html)
        let navigator = try EPUBNavigatorViewController(publication: fixture.viewModel.publication, initialLocation: locator)
        let delegate = NavigationInputDelegate()
        navigator.delegate = delegate
        let spread = makeReflowableSpreadView()
        spread.delegate = navigator
        spread.scrollViewWillBeginDragging(spread.scrollView)
        XCTAssertEqual(delegate.inputs, 1)
        navigator.spreadView(spread, selectionDidChange: Locator.Text(highlight: "selected"), frame: .zero, domRange: nil)
        XCTAssertNotNil(navigator.currentSelection)
        spread.scrollViewWillBeginDragging(spread.scrollView)
        XCTAssertEqual(delegate.inputs, 1, "Selection dragging must not admit navigation")
    }

    func testVoiceOverPageScrollAdmitsBeforeTurningPages() throws {
        let fixture = makeFixture(layout: .reflowable)
        let locator = Locator(href: RelativeURL(path: "chapter.html")!.anyURL, mediaType: .html)
        let navigator = try EPUBNavigatorViewController(publication: fixture.viewModel.publication, initialLocation: locator)
        let delegate = NavigationInputDelegate()
        navigator.delegate = delegate
        let directions: [UIAccessibilityScrollDirection] = [.next, .previous, .left, .right, .up, .down]
        for (index, direction) in directions.enumerated() {
            XCTAssertTrue(navigator.accessibilityScroll(direction))
            XCTAssertEqual(delegate.inputs, index + 1, "VoiceOver scroll \(direction.rawValue) must admit")
        }
    }

    func testNativeDragAdmitsPaginatedAndContinuousNavigation() {
        for scrolling in [false, true] {
            let spread = makeReflowableSpreadView(scroll: scrolling)
            let delegate = TestSpreadDelegate()
            spread.delegate = delegate
            spread.scrollViewWillBeginDragging(spread.scrollView)
            XCTAssertEqual(delegate.navigationInputs, 1)
            spread.scrollViewDidScroll(spread.scrollView)
            XCTAssertEqual(delegate.navigationInputs, 1, "Geometry is not another input")
        }
    }

    func testFreshReflowablePaginationImmediatelyAwaitsItsPageCommand() async {
        let spreadView = makeReflowableSpreadView(
            scroll: true,
            scripts: [activeAnimationFramesUserScript()]
        )
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        let (pagination, delegate) = makePagination(spreadView: spreadView)
        _ = delegate
        let hostWindow = hostView(pagination)
        defer { hostWindow.isHidden = true }

        let outcome = await pagination.goToIndex(
            0,
            location: .end,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testFreshFixedPaginationImmediatelyAwaitsItsPageCommand() async {
        let spreadView = makeFixedSpreadView(
            scripts: [activeAnimationFramesUserScript()]
        )
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        let (pagination, delegate) = makePagination(spreadView: spreadView)
        _ = delegate
        let hostWindow = hostView(pagination)
        defer { hostWindow.isHidden = true }

        let outcome = await pagination.goToIndex(
            0,
            location: .start,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testReplacementReflowableLoadStartsItsGenerationSynchronously() async throws {
        let spreadView = makeReflowableSpreadView()
        try await waitForDocumentLoad(in: spreadView)
        let firstGeneration = spreadView.readiness.generation

        spreadView.loadSpread()

        XCTAssertEqual(spreadView.readiness.generation, firstGeneration + 1)
        XCTAssertEqual(
            spreadView.readiness.state,
            .loading(generation: firstGeneration + 1)
        )
    }

    func testCancellingLoadingLocationDoesNotApplyAfterInitialization() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)

        let navigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()
        navigation.cancel()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        let offsetAfterCancellation = spreadView.scrollView.contentOffset

        try await initializeReflowableSpread(spreadView)

        XCTAssertEqual(spreadView.scrollView.contentOffset, offsetAfterCancellation)
    }

    func testCancellingOlderLoadingLocationDoesNotClearNewerLocation() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)

        let olderNavigation = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        await Task.yield()
        let newerNavigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()
        olderNavigation.cancel()

        let olderOutcome = await olderNavigation.value
        XCTAssertEqual(olderOutcome, .cancelled)
        try await initializeReflowableSpread(spreadView)

        let newerOutcome = await newerNavigation.value
        XCTAssertEqual(newerOutcome, .succeeded)
        XCTAssertEqual(
            spreadView.scrollView.contentOffset.y,
            spreadView.scrollView.contentSize.height - spreadView.scrollView.bounds.height,
            accuracy: 1
        )
    }

    func testSuccessfulReflowablePageTurnReturnsSucceededAndRemainsReady() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)

        let outcome = await spreadView.go(
            to: .right,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    /// An animated turn's writer lease holds readiness in `.initializing`
    /// while it waits, and the scroll-quiet signal, not the fallback timer,
    /// ends that wait. The page scrolls instantly, so the signal's timing does
    /// not depend on how long WebKit animates.
    func testAnimatedReflowablePageTurnSettlesOnTheScrollQuietSignal() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await makeSmoothScrollsInstant(in: spreadView)
        let coordinator = spreadView.scrollAnimationCoordinator

        let turn = Task { @MainActor in
            await spreadView.go(to: .right, options: NavigatorGoOptions(animated: true))
        }
        try await waitUntil { coordinator.hasPendingRequest }
        XCTAssertFalse(spreadView.readiness.isCommandReady, "The turn waited without holding readiness")
        let outcome = await turn.value

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(coordinator.lastSettlementForTesting, .finished, "The fallback timer ended the wait")
    }

    func testReflowablePageTurnAtBoundaryReturnsBoundaryAndRemainsReady() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)

        let outcome = await spreadView.go(
            to: .left,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .boundary)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testReflowablePageTurnScriptFailureInvalidatesReadiness() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        _ = try await spreadView.webView.callAsyncJavaScript(
            "window.scrollBy = () => { throw new Error('page turn failed'); }; return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        // The position writer advances readiness exactly once before it runs the
        // page-turn script, which fails synchronously without an observation hook.
        let expectedFailureGeneration = spreadView.readiness.generation &+ 1

        let outcome = await spreadView.go(
            to: .right,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .failed)
        assertCommandCapabilityRevoked(
            in: spreadView,
            expectedGeneration: expectedFailureGeneration,
            "Failed page turn republished command readiness"
        )
    }

    func testCancellingReflowablePageTurnReturnsCancelledAndInvalidatesReadiness() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)

        let turn = Task { @MainActor in
            await spreadView.go(
                to: .right,
                options: NavigatorGoOptions(animated: true)
            )
        }
        try await waitUntil {
            if case .initializing(_, activeWriterLeases: 1) = spreadView.readiness.state {
                return true
            }
            return false
        }
        let expectedFailureGeneration = spreadView.readiness.generation
        turn.cancel()

        let outcome = await turn.value
        XCTAssertEqual(outcome, .cancelled)
        assertCommandCapabilityRevoked(
            in: spreadView,
            expectedGeneration: expectedFailureGeneration,
            "Cancelled page turn retained frame capability"
        )
    }

    func testPaginationCallerCancellationInvalidatesActualReflowableCommand() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)

        let delegate = ReflowablePaginationDelegate(spreadView: spreadView)
        let pagination = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        pagination.delegate = delegate
        pagination.reloadAtIndex(
            0,
            location: .start,
            pageCount: 1,
            readingProgression: .ltr
        )
        try await waitUntil { delegate.updateCount == 1 }
        try await blockAnimationFrames(in: spreadView)

        let navigation = Task { @MainActor in
            await pagination.goToIndex(
                0,
                location: .end,
                options: NavigatorGoOptions(animated: false)
            )
        }
        try await waitUntil {
            if case .initializing(_, activeWriterLeases: 1) = spreadView.readiness.state {
                return true
            }
            return false
        }
        let expectedFailureGeneration = spreadView.readiness.generation
        let offsetAtCancellation = spreadView.scrollView.contentOffset

        navigation.cancel()
        try await releaseAnimationFrames(in: spreadView)

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(spreadView.scrollView.contentOffset, offsetAtCancellation)
        assertCommandCapabilityRevoked(
            in: spreadView,
            expectedGeneration: expectedFailureGeneration,
            "Pagination caller cancellation retained reflow capability"
        )
    }

    func testRapidReflowablePageTurnsSupersedeAndSerializePositionWriters() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await blockAnimationFrames(in: spreadView)

        let first = Task { @MainActor in
            await spreadView.go(
                to: .right,
                options: NavigatorGoOptions(animated: false)
            )
        }
        try await waitUntil {
            spreadView.scrollView.contentOffset.x > 0
                && spreadView.readiness.state == .initializing(
                    generation: spreadView.readiness.generation,
                    activeWriterLeases: 1
                )
        }
        let latest = Task { @MainActor in
            await spreadView.go(
                to: .left,
                options: NavigatorGoOptions(animated: false)
            )
        }
        await Task.yield()

        if case let .initializing(_, activeWriterLeases) = spreadView.readiness.state {
            XCTAssertEqual(activeWriterLeases, 1)
        }
        try await releaseAnimationFrames(in: spreadView)
        let firstOutcome = await first.value
        let latestOutcome = await latest.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(latestOutcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
        XCTAssertEqual(spreadView.scrollView.contentOffset.x, 0, accuracy: 1)
    }

    /// A turn superseded mid-settlement leaves nothing of its own, and the
    /// hand-off between the two reads nothing: the superseding turn's
    /// settlement measures its landing, and that is the one report.
    func testASupersedingTurnReportsOnlyWhereItLands() async throws {
        let (spreadView, delegate) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let reportsBefore = delegate.reportedRanges.count
        try await blockAnimationFrames(in: spreadView)

        let superseded = Task { @MainActor in
            await spreadView.go(to: .right, options: NavigatorGoOptions(animated: false))
        }
        try await waitUntil {
            spreadView.scrollView.contentOffset.x > 0 && !spreadView.readiness.isCommandReady
        }
        let secondPage = spreadView.scrollView.contentOffset.x
        let latest = Task { @MainActor in
            await spreadView.go(to: .right, options: NavigatorGoOptions(animated: false))
        }
        await Task.yield()
        try await releaseAnimationFrames(in: spreadView)
        let supersededOutcome = await superseded.value
        let latestOutcome = await latest.value
        XCTAssertEqual(supersededOutcome, .cancelled)
        XCTAssertEqual(latestOutcome, .succeeded)

        try await waitUntil {
            observation.currentObservation != nil && !observation.hasObligation && !observation.isReading
        }
        let scrollView = spreadView.scrollView
        XCTAssertGreaterThan(scrollView.contentOffset.x, secondPage, "Setup: the superseding turn did not move past the superseded one")
        let landing = scrollView.contentOffset.x / scrollView.contentSize.width
        let accepted = try XCTUnwrap(observation.currentObservation)
        XCTAssertEqual(accepted.sample.range.lowerBound, landing, accuracy: 0.001, "The accepted sample is not where the superseding turn landed")
        // The count is what tells a read accepted in the hand-off gap from the
        // landing's own report: both measure the landing.
        let reported = delegate.reportedRanges.dropFirst(reportsBefore)
        XCTAssertEqual(reported.count, 1, "The supersession reported something besides the landing")
        for range in reported {
            XCTAssertEqual(range.lowerBound, landing, accuracy: 0.001, "The supersession reported \(range), not the landing")
        }
    }

    func testRapidReflowableLocationsSupersedeAndSerializePositionWriters() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await blockAnimationFrames(in: spreadView)

        let first = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        try await waitUntil {
            if case .initializing(_, activeWriterLeases: 1) = spreadView.readiness.state {
                return true
            }
            return false
        }
        let latest = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(
            spreadView.readiness.state,
            .initializing(
                generation: spreadView.readiness.generation,
                activeWriterLeases: 1
            )
        )
        try await releaseAnimationFrames(in: spreadView)

        let firstOutcome = await first.value
        let latestOutcome = await latest.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(latestOutcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
        XCTAssertEqual(
            spreadView.scrollView.contentOffset.y,
            spreadView.scrollView.contentSize.height - spreadView.scrollView.bounds.height,
            accuracy: 1
        )
    }

    func testReflowablePageTurnWaitsForExistingLayoutWriter() async throws {
        let spreadView = makeReflowableSpreadView()
        let delegate = TestSpreadDelegate()
        spreadView.delegate = delegate
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await blockAnimationFrames(in: spreadView)

        delegate.contentInset = UIEdgeInsets(top: 24, left: 0, bottom: 32, right: 0)
        spreadView.safeAreaInsetsDidChange()
        try await waitUntil {
            spreadView.readiness.state == .initializing(
                generation: spreadView.readiness.generation,
                activeWriterLeases: 1
            )
        }

        var turnOutcome: EPUBSpreadView.PageTurnOutcome?
        let turn = Task { @MainActor in
            let outcome = await spreadView.go(
                to: .right,
                options: NavigatorGoOptions(animated: false)
            )
            turnOutcome = outcome
            return outcome
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        XCTAssertEqual(
            spreadView.readiness.state,
            .initializing(
                generation: spreadView.readiness.generation,
                activeWriterLeases: 1
            )
        )
        XCTAssertNil(turnOutcome)

        try await releaseAnimationFrames(in: spreadView)
        let outcome = await turn.value
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testReflowableRuntimeInsetFailureNeverRepublishesReady() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        let delegate = TestSpreadDelegate()
        spreadView.delegate = delegate
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await makeLayoutStabilityCheckFail(in: spreadView)

        delegate.contentInset = UIEdgeInsets(top: 24, left: 0, bottom: 32, right: 0)
        spreadView.safeAreaInsetsDidChange()
        let mutationGeneration = spreadView.readiness.generation
        let outcome = await spreadView.readiness.waitForCommandReadiness(
            for: mutationGeneration,
            until: ContinuousClock.now.advanced(by: .seconds(2))
        )

        // A layout-stability failure is a genuine, current-generation miss, so
        // the wait resolves `.failed` for that exact generation rather than the
        // lifecycle `.invalidated` a teardown or replacement would produce.
        XCTAssertEqual(outcome, .failed(generation: mutationGeneration))
        assertCommandCapabilityRevoked(
            in: spreadView,
            expectedGeneration: mutationGeneration,
            "Failed runtime inset mutation republished command readiness"
        )
    }

    func testCancelledReflowableMutationPreservesCapabilityForSuccessorLanding() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await blockAnimationFrames(in: spreadView)

        let superseded = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        try await waitUntil {
            if case .initializing = spreadView.readiness.state {
                return true
            }
            return false
        }
        spreadView.acknowledgeCommandSupersession()
        superseded.cancel()
        try await releaseAnimationFrames(in: spreadView)

        let supersededOutcome = await superseded.value
        let successorOutcome = await spreadView.go(to: .end, animated: false)

        XCTAssertEqual(supersededOutcome, .cancelled)
        XCTAssertEqual(successorOutcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
        XCTAssertEqual(
            spreadView.scrollView.contentOffset.y,
            spreadView.scrollView.contentSize.height - spreadView.scrollView.bounds.height,
            accuracy: 1
        )
    }

    func testUnacknowledgedReflowableCancellationInvalidatesCapability() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await blockAnimationFrames(in: spreadView)

        let cancelled = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        try await waitUntil {
            if case .initializing = spreadView.readiness.state {
                return true
            }
            return false
        }
        let expectedFailureGeneration = spreadView.readiness.generation
        cancelled.cancel()
        try await releaseAnimationFrames(in: spreadView)

        let outcome = await cancelled.value
        XCTAssertEqual(outcome, .cancelled)
        assertCommandCapabilityRevoked(
            in: spreadView,
            expectedGeneration: expectedFailureGeneration,
            "Unacknowledged cancellation retained frame capability"
        )
    }

    func testFixedInitializationStabilityLeaseGatesReadiness() async throws {
        let spreadView = makeFixedSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await waitForFixedResourceLoad(in: spreadView)
        try await blockAnimationFrames(in: spreadView)

        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
        ))
        let initialization = Task { @MainActor in
            await spreadView.initializeSpread()
        }
        try await waitUntil {
            spreadView.readiness.state == .initializing(
                generation: generation,
                activeWriterLeases: 2
            )
        }

        try await releaseAnimationFrames(in: spreadView)
        let initializationOutcome = await initialization.value
        spreadView.readiness.finishInitialization(
            rootLease,
            outcome: initializationOutcome
        )
        try await waitUntil { spreadView.readiness.isCommandReady }

        XCTAssertEqual(initializationOutcome, .succeeded)
    }

    func testReflowableInitializationWaitsForLateExternalStylesheet() async throws {
        let spreadView = makeReflowableSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        try await installDelayedStylesheet(in: spreadView, documentExpression: "document")
        let hostWindow = hostView(spreadView)
        defer { hostWindow.isHidden = true }

        let outcome = try await initializeLoadedReflowableSpread(spreadView)
        let stylesheetReady = try await spreadView.webView.callAsyncJavaScript(
            "return document.querySelector('link[href$=\"late.css\"]')?.sheet !== null;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool

        XCTAssertEqual(stylesheetReady, true)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testFixedInitializationWaitsForLateExternalStylesheet() async throws {
        let spreadView = makeFixedSpreadView()
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await waitForFixedResourceLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        try await installDelayedStylesheet(
            in: spreadView,
            documentExpression: "document.querySelector('iframe').contentDocument"
        )
        let hostWindow = hostView(spreadView)
        defer { hostWindow.isHidden = true }

        let outcome = try await initializeLoadedFixedSpread(spreadView)
        let stylesheetReady = try await spreadView.webView.callAsyncJavaScript(
            "return document.querySelector('iframe').contentDocument.querySelector('link[href$=\"late.css\"]')?.sheet !== null;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool

        XCTAssertEqual(stylesheetReady, true)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testUnavailableStylesheetUsesOneBudgetAndDoesNotPoisonReplacement() async throws {
        // Short for the allowance this test watches get SPENT — an unavailable
        // stylesheet never resolves, so the first initialization runs it out on
        // purpose and pays for it in wall time. Generous for the replacement,
        // which must genuinely succeed: a short allowance there expires before
        // a starved host can settle a real WKWebView, and asserting `.succeeded`
        // against it is exactly the machine-speed bet #1693 was about.
        let mintLog = StabilityBudgetMintLog()
        let spreadView = makeReflowableSpreadView(
            stabilityBudget: mintLog.budget(firstSharedAllowance: 1000, then: 60000)
        )
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        _ = try await spreadView.webView.callAsyncJavaScript(
            "const link = document.createElement('link'); link.rel = 'stylesheet'; document.head.append(link); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        // Brackets `initializeSpread()` alone, WITHOUT `applySettings()`: the
        // content-inset re-layout that `applySettings()` triggers arms its own
        // allowance from inside a detached Task, so it lands at an unpredictable
        // point and would make any count here race it.
        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
        ))
        let mintsBefore = mintLog.totalCount()
        let sharedMintsBefore = mintLog.count(.sharedInitialization)
        let outcome = await spreadView.initializeSpread()
        let mintsDuringInitialization = mintLog.totalCount() - mintsBefore
        let sharedMintsDuringInitialization = mintLog.count(.sharedInitialization) - sharedMintsBefore
        spreadView.readiness.finishInitialization(rootLease, outcome: outcome)

        XCTAssertEqual(outcome, .failed)
        // The claim is a budget COUNT: an unavailable stylesheet must consume
        // exactly ONE shared stability allowance, never re-arm a fresh one per
        // rung. It used to be inferred from elapsed wall time against a ±250 ms
        // window, which also measured how loaded the host was — and that is
        // what failed on a busy machine while the behaviour it guards was
        // correct (#1693).
        //
        // Exactly one: `initializeSpread()` returns `.failed` the moment the
        // stylesheet wait gives up, which is before the anchor-tracking rung
        // and its independent own cap are reached. Counting the TOTAL rather
        // than only `.sharedInitialization` is what makes this sensitive — a
        // rung that re-armed would fall back through the `.ownCap` path, and a
        // shared-only count would not see the very regression this guards.
        XCTAssertEqual(
            mintsDuringInitialization,
            1,
            "Initialization armed \(mintsDuringInitialization) allowances "
                + "(\(mintLog.describeCounts())) — expected exactly one, the "
                + "shared budget the stylesheet wait spends"
        )
        // The total alone cannot tell WHICH allowance that was, so a mint site
        // mislabelled `.ownCap` would keep the count at 1 while silently
        // inverting what the assertion above means.
        XCTAssertEqual(
            sharedMintsDuringInitialization,
            1,
            "the one allowance initialization armed was not the shared budget "
                + "(\(mintLog.describeCounts()))"
        )

        spreadView.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        spreadView.loadSpread()
        try await waitForDocumentLoad(in: spreadView)
        let replacementOutcome = try await initializeLoadedReflowableSpread(spreadView)

        XCTAssertEqual(replacementOutcome, .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady)
    }

    func testFixedMainFrameReloadBootstrapsExactlyOneNewGeneration() async throws {
        let spreadView = makeFixedSpreadView(scripts: [WKUserScript(
            source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )])
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        _ = try await initializeLoadedFixedSpread(spreadView)
        let firstGeneration = spreadView.readiness.generation
        let wrapperHTMLResult = try await spreadView.webView.callAsyncJavaScript(
            "return document.documentElement.outerHTML;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        let wrapperHTML = try XCTUnwrap(wrapperHTMLResult)
        let hostWindow = hostView(spreadView)
        defer { hostWindow.isHidden = true }

        spreadView.webView.loadHTMLString(
            wrapperHTML,
            baseURL: spreadView.viewModel.publicationBaseURL.url
        )

        try await waitUntil(timeout: .seconds(3)) {
            spreadView.readiness.isCommandReady
                && spreadView.readiness.generation > firstGeneration
        }
        XCTAssertEqual(spreadView.readiness.generation, firstGeneration + 1)
        try await waitForFixedResourceLoad(in: spreadView)
    }

    func testReflowableInitializationGatesReadinessAndAppliesLatestPendingLocation() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)

        let olderNavigation = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        await Task.yield()
        let latestNavigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()

        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
        ))
        spreadView.applySettings()
        XCTAssertEqual(
            spreadView.readiness.state,
            .initializing(generation: generation, activeWriterLeases: 2)
        )

        let initializationOutcome = await spreadView.initializeSpread()
        spreadView.readiness.finishInitialization(
            rootLease,
            outcome: initializationOutcome
        )
        try await waitUntil { spreadView.readiness.isCommandReady }

        let olderOutcome = await olderNavigation.value
        let latestOutcome = await latestNavigation.value
        XCTAssertEqual(initializationOutcome, .succeeded)
        XCTAssertEqual(olderOutcome, .succeeded)
        XCTAssertEqual(latestOutcome, .succeeded)
        XCTAssertGreaterThan(spreadView.scrollView.contentOffset.y, 0)
        XCTAssertEqual(
            spreadView.scrollView.contentOffset.y,
            spreadView.scrollView.contentSize.height - spreadView.scrollView.bounds.height,
            accuracy: 1
        )
    }

    /// An invalidation under an in-flight command is a lifecycle interruption —
    /// teardown, reload, or replacement — not a hard failure. It must surface as
    /// `.cancelled` so the caller's progression / cross-resource fallback never
    /// fights the incoming document, and must never surface as `.succeeded`.
    ///
    /// The pure mapping is pinned WebView-free by
    /// `EPUBNavigatorPageCommandOutcomeTests.testInvalidatedReadinessGateIsCancelledNotFailed`;
    /// this is the real-document end of the same contract.
    func testReflowableInvalidatedReadinessIsReportedAsCancelledNotFailed() async {
        let spreadView = makeReflowableSpreadView()
        spreadView.clear()
        _ = spreadView.readiness.beginLoading()

        let navigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()
        spreadView.readiness.invalidate()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testFixedInvalidatedReadinessIsReportedAsCancelledNotFailed() async {
        let spreadView = makeFixedSpreadView()
        spreadView.clear()
        _ = spreadView.readiness.beginLoading()

        let navigation = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        await Task.yield()
        spreadView.readiness.invalidate()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testReflowableCancelledReadinessIsNotReportedAsFailure() async {
        let spreadView = makeReflowableSpreadView()
        spreadView.clear()
        _ = spreadView.readiness.beginLoading()

        let navigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()
        navigation.cancel()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
    }

    // MARK: - Location observation

    // These spreads stay out of a view hierarchy and are initialized by hand,
    // so the bridge holds a capability only once a test hands one over. The
    // page still posts its own hints when it scrolls or resizes; no test below
    // relies on their absence.

    /// A spread ready before its frame registers keeps the obligation, and the
    /// hand-off reports it: the freed transport slot or the registration,
    /// whichever finds the frame selectable first, starts the read.
    func testARegistrationAfterReadinessReportsTheMeasuredViewport() async throws {
        let (spreadView, delegate) = try await loadObservedReflowableSpread()
        let capability = EPUBSpreadFrameCapability()
        let outcome = try await initializeLoadedReflowableSpread(spreadView, frameCapability: capability)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        XCTAssertTrue(observation.hasObligation, "A read refused for an unregistered frame dropped its obligation")
        XCTAssertFalse(observation.isReading)

        spreadView.locatorCommandBridge.setFrameCapability(capability)

        try await waitUntil { delegate.pageChanges > 0 }
        try assertReportsTheMeasuredStart(of: spreadView, under: capability)
    }

    /// A frame that registers while initialization still holds readiness is
    /// not read, even once the hand-off frees the transport, until the spread
    /// becomes ready.
    func testARegistrationBeforeReadinessReportsOnceTheSpreadIsReady() async throws {
        let (spreadView, delegate) = try await loadObservedReflowableSpread()
        let registrations = RegistrationRecorder(spreadView.locatorCommandBridge)
        let freedSlots = FreedSlotRecorder(spreadView.locatorCommandBridge)
        let capability = EPUBSpreadFrameCapability()
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: spreadView.readiness.generation,
            frameCapability: capability
        ))
        spreadView.locatorCommandBridge.setFrameCapability(capability)
        try await waitUntil { registrations.capabilities == [capability] && freedSlots.count > 0 }
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        XCTAssertTrue(observation.hasObligation, "The registration asked for no measurement")
        XCTAssertFalse(observation.isReading, "A read started while initialization held readiness")
        XCTAssertNil(observation.currentObservation, "A read was accepted while initialization held readiness")
        XCTAssertEqual(delegate.pageChanges, 0)

        spreadView.applySettings()
        let outcome = await spreadView.initializeSpread()
        spreadView.readiness.finishInitialization(rootLease, outcome: outcome)
        XCTAssertEqual(outcome, .succeeded)

        try await waitUntil { delegate.pageChanges > 0 }
        try assertReportsTheMeasuredStart(of: spreadView, under: capability)
    }

    /// A command that leaves the viewport where it was moves nothing a hint
    /// could report, yet its settlement alone measures the viewport again.
    func testACommandThatDoesNotMoveStillReportsItsSettledViewport() async throws {
        let (spreadView, delegate) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let before = try XCTUnwrap(observation.currentObservation)
        let reports = delegate.pageChanges

        let outcome = await spreadView.go(to: .start, animated: false)

        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { observation.currentObservation != nil }
        XCTAssertEqual(observation.currentObservation, before, "The command moved the viewport")
        XCTAssertGreaterThan(delegate.pageChanges, reports)
    }

    /// Admission revokes the accepted sample at once, before the command's
    /// writer moves readiness.
    func testACommandRevokesTheAcceptedSampleOnAdmission() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Stopping a command between admission and its writer needs Task.immediate")
        }
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)

        // Runs the command here up to its first suspension, so the writer task
        // it admitted has not started; a yield left that order to the executor.
        let command = Task.immediate { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }

        XCTAssertTrue(spreadView.readiness.isCommandReady, "The command's writer had already moved readiness")
        XCTAssertNil(observation.currentObservation, "Admission kept the accepted sample")
        // Readiness is still ready, but the command has not taken its writer.
        observation.request()
        XCTAssertFalse(observation.isReading, "A read started while a command was pending")
        _ = await command.value
    }

    /// Only a registration ends a hand-off that failed twice; its re-issue
    /// alone does not.
    func testARegistrationEndsAMissingHandshake() async throws {
        let (spreadView, delegate) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let capability = try XCTUnwrap(spreadView.readiness.currentFrameCapability)
        let report = try XCTUnwrap(spreadView.locatorCommandBridge.onLocationTransportEvent)
        report(.handshakeFailed(capability, .registrationMissing))
        report(.handshakeFailed(capability, .registrationMissing))
        XCTAssertTrue(observation.isRegistrationMissing)
        observation.invalidate()
        observation.request()
        XCTAssertFalse(observation.isReading, "A read started while the hand-off was missing")
        let pageChanges = delegate.pageChanges

        spreadView.locatorCommandBridge.setFrameCapability(capability)

        // The hand-off's freed slot cannot read while it is missing, so only
        // the registration can bring this report.
        try await waitUntil { delegate.pageChanges > pageChanges }
        XCTAssertFalse(observation.isRegistrationMissing)
        try assertReportsTheMeasuredStart(of: spreadView, under: capability)
    }

    /// A new document's hand-off gets a re-issue of its own, whatever the
    /// previous document spent.
    func testANewDocumentStartsWithItsOwnHandshakeReissue() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let report = try XCTUnwrap(spreadView.locatorCommandBridge.onLocationTransportEvent)
        let first = try XCTUnwrap(spreadView.readiness.currentFrameCapability)
        report(.handshakeFailed(first, .registrationMissing))

        let generation = spreadView.readiness.beginLoading()
        let next = EPUBSpreadFrameCapability()
        _ = try XCTUnwrap(spreadView.readiness.beginInitialization(for: generation, frameCapability: next))
        report(.handshakeFailed(next, .registrationMissing))

        XCTAssertFalse(observation.isRegistrationMissing, "The previous document's re-issue was counted")
    }

    /// A same-document mutation revokes the sample while it runs, and the
    /// spread measures again once it is ready.
    func testAReadinessMutationRevokesTheSampleAndMeasuresOnceReady() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)

        let lease = try XCTUnwrap(spreadView.readiness.beginMutation())
        XCTAssertNil(observation.currentObservation, "A mutation kept the accepted sample")
        spreadView.readiness.finishMutation(lease, outcome: .succeeded)

        XCTAssertTrue(observation.isReading || observation.hasObligation, "Readiness asked for no measurement")
        try await waitUntil { observation.currentObservation != nil }
    }

    /// A hand-off that fails twice waits for a grant, and the grant re-issues
    /// it to the page.
    func testAHandshakeThatFailsTwiceWaitsForAGrantThatReissuesIt() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let capability = try XCTUnwrap(spreadView.readiness.currentFrameCapability)
        let registrations = RegistrationRecorder(spreadView.locatorCommandBridge)
        let report = try XCTUnwrap(spreadView.locatorCommandBridge.onLocationTransportEvent)

        report(.handshakeFailed(capability, .registrationMissing))
        report(.handshakeFailed(capability, .registrationMissing))
        XCTAssertTrue(observation.isRegistrationMissing)

        report(.lateCompletion)
        XCTAssertFalse(observation.isRegistrationMissing, "The grant left the hand-off missing")
        try await waitUntil { registrations.capabilities.contains(capability) }
    }

    /// A read refused because another call holds the transport runs as soon as
    /// that call completes and frees it.
    func testAReadRefusedForAnOccupiedTransportRunsWhenTheSlotFrees() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let bridge = spreadView.locatorCommandBridge
        let holder = bridge.readProgression(
            targetHREF: spreadView.viewModel.url(to: spreadView.spread.first.link),
            deadline: EPUBLocatorOperationDeadline(startingAt: bridge.deadlineScheduler.now(), budget: .seconds(5)),
            completion: { _ in }
        )
        XCTAssertEqual(holder, .started)

        observation.invalidate()
        observation.request()
        XCTAssertFalse(observation.isReading, "A read started beside the outstanding call")
        XCTAssertTrue(observation.hasObligation)

        try await waitUntil { observation.currentObservation != nil }
    }

    /// Native motion revokes the sample at once, whoever moved the content.
    func testANativeScrollRevokesTheAcceptedSample() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let scrollView = spreadView.scrollView
        XCTAssertGreaterThan(scrollView.contentSize.width, scrollView.bounds.width * 2, "Setup: one page only")

        scrollView.contentOffset = CGPoint(x: scrollView.bounds.width, y: 0)

        XCTAssertNil(observation.currentObservation, "A scroll kept the accepted sample")
    }

    /// Native motion settles when a drag ends without deceleration, when the
    /// deceleration ends, or when a scrolling animation ends; a drag that will
    /// still decelerate has not settled.
    func testScrollEndCallbacksAskForAMeasurement() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let scrollView = spreadView.scrollView

        observation.invalidate()
        spreadView.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        XCTAssertFalse(observation.isReading || observation.hasObligation, "A decelerating drag asked before it settled")
        spreadView.scrollViewDidEndDecelerating(scrollView)
        XCTAssertTrue(observation.isReading || observation.hasObligation, "The deceleration's end asked for nothing")
        try await waitUntil { observation.currentObservation != nil && !observation.isReading }

        observation.invalidate()
        spreadView.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        XCTAssertTrue(observation.isReading || observation.hasObligation, "A drag's end asked for nothing")
        try await waitUntil { observation.currentObservation != nil && !observation.isReading }

        observation.invalidate()
        spreadView.scrollViewDidEndScrollingAnimation(scrollView)
        XCTAssertTrue(observation.isReading || observation.hasObligation, "An animation's end asked for nothing")
    }

    // MARK: - Publication input

    /// A reflowable spread publishes exactly its accepted observation, and
    /// nothing once that observation is revoked.
    func testPublicationInputIsTheAcceptedObservation() async throws {
        let (spreadView, _) = try await openObservedReflowableSpread()
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        let accepted = try XCTUnwrap(observation.currentObservation)

        XCTAssertEqual(spreadView.publicationInput(), EPUBSpreadPublicationInput(
            capability: accepted.sample.capability,
            stamp: accepted.stamp,
            progressions: [spreadView.spread.first.index: accepted.sample.range]
        ))

        observation.invalidate()
        XCTAssertNil(spreadView.publicationInput(), "A revoked observation stayed publishable")
    }

    /// Readiness alone is not publishable for a reflowable spread: its
    /// fallback range was never measured.
    func testAReadyReflowableSpreadWithoutAnAcceptedObservationPublishesNothing() async throws {
        let (spreadView, _) = try await loadObservedReflowableSpread()
        let outcome = try await initializeLoadedReflowableSpread(spreadView)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }

        XCTAssertNil(spreadView.publicationInput())
    }

    /// A fixed spread publishes its full resources once ready, and tells its
    /// delegate so, since nothing else would.
    func testAFixedSpreadReportsItsPagesOnceReady() async throws {
        let spreadView = makeFixedSpreadView()
        let delegate = TestSpreadDelegate()
        spreadView.delegate = delegate
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await waitForFixedResourceLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        XCTAssertNil(spreadView.publicationInput(), "A loading fixed spread was publishable")
        XCTAssertEqual(delegate.pageChanges, 0)

        let outcome = try await initializeLoadedFixedSpread(spreadView)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }

        XCTAssertEqual(delegate.pageChanges, 1, "Readiness did not tell the delegate the pages changed")
        let capability = try XCTUnwrap(spreadView.readiness.currentFrameCapability)
        XCTAssertEqual(spreadView.publicationInput(), EPUBSpreadPublicationInput(
            capability: capability,
            stamp: nil,
            progressions: [spreadView.spread.first.index: 0 ... 1]
        ))
    }

    /// A ready double spread publishes each of its resources, not only the
    /// leading one.
    func testAReadyDoubleFixedSpreadPublishesBothResources() async throws {
        let fixture = makeFixture(layout: .fixed, double: true)
        let spreadView = EPUBFixedSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: [],
            animatedLoad: false,
            stabilityBudget: Self.generousStabilityBudget
        )
        spreadView.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        let capability = EPUBSpreadFrameCapability()
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: spreadView.readiness.generation,
            frameCapability: capability
        ))
        spreadView.readiness.finishInitialization(rootLease, outcome: .succeeded)
        XCTAssertTrue(spreadView.readiness.isCommandReady, "Setup: the spread is not ready")

        XCTAssertEqual(spreadView.publicationInput(), EPUBSpreadPublicationInput(
            capability: capability,
            stamp: nil,
            progressions: [0: 0 ... 1, 1: 0 ... 1]
        ))
    }

    /// The stability allowance these tests build spread views with.
    ///
    /// Deliberately far wider than production's 5 s. The budget is a product
    /// decision about how long a reader waits for a page to settle; what these
    /// tests assert is the MECHANISM around it, and every one of them reaches
    /// that mechanism through a real WKWebView whose settle time is the host's
    /// to decide. Running them against the production allowance made the
    /// assertions bets on machine speed, and a loaded host lost those bets
    /// while the behaviour under test was correct (#1693). A test that wants to
    /// observe an allowance being SPENT asks for a short one explicitly.
    private nonisolated static let generousStabilityBudget = EPUBInitializationStabilityBudget(
        milliseconds: 60000,
        clock: .continuous
    )

    /// Counts stability allowances as they are minted, per purpose.
    ///
    /// Lets a test assert how many budgets a generation armed — the property
    /// "one budget, never re-armed per rung" actually claims — instead of
    /// inferring it from elapsed wall time, which measures host load as much as
    /// it measures re-arming.
    private final class StabilityBudgetMintLog: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [EPUBInitializationStabilityBudget.Purpose: Int] = [:]

        func record(_ purpose: EPUBInitializationStabilityBudget.Purpose) {
            lock.lock()
            defer { lock.unlock() }
            counts[purpose, default: 0] += 1
        }

        func count(_ purpose: EPUBInitializationStabilityBudget.Purpose) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[purpose, default: 0]
        }

        /// Every allowance armed, whatever its purpose.
        ///
        /// The total is what "an initialization never re-arms per rung" has to
        /// be asserted against: a rung that re-armed would fall back through
        /// the `?? resolveInitializationStabilityDeadline(for: .ownCap)` path,
        /// so counting `.sharedInitialization` alone would miss precisely the
        /// regression this is here to catch.
        func totalCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }

        func describeCounts() -> String {
            lock.lock()
            defer { lock.unlock() }
            return counts
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
        }

        /// A budget of `milliseconds` that tallies every mint that passes
        /// through it.
        func budget(milliseconds: Int) -> EPUBInitializationStabilityBudget {
            budget(firstSharedAllowance: milliseconds, then: milliseconds)
        }

        /// A budget that hands the FIRST shared-initialization allowance
        /// `firstSharedAllowance` ms and every later one `then` ms.
        ///
        /// The two numbers answer two different needs that one number cannot.
        /// A test that wants to watch an allowance be SPENT — an unavailable
        /// stylesheet never resolves — pays that allowance in wall time, so it
        /// wants a short one. The initialization that follows must genuinely
        /// SUCCEED, and on a starved host a short allowance expires before a
        /// real WKWebView can settle, which is the machine-speed bet #1693 was
        /// about. Own caps are unaffected: they bound a hang, never a settle.
        func budget(
            firstSharedAllowance: Int,
            then laterAllowance: Int
        ) -> EPUBInitializationStabilityBudget {
            let clock = EPUBMonotonicClock.continuous
            return EPUBInitializationStabilityBudget(
                milliseconds: laterAllowance,
                clock: clock
            ) { [self] purpose in
                let isFirstShared = purpose == .sharedInitialization
                    && count(.sharedInitialization) == 0
                record(purpose)
                let milliseconds = isFirstShared ? firstSharedAllowance : laterAllowance
                return clock.now().advanced(by: .milliseconds(milliseconds))
            }
        }
    }

    private func makeReflowableSpreadView(
        scroll: Bool = false,
        scripts: [WKUserScript] = [],
        stabilityBudget: EPUBInitializationStabilityBudget = EPUBSpreadViewCommandOutcomeTests.generousStabilityBudget
    ) -> EPUBReflowableSpreadView {
        let fixture = makeFixture(layout: .reflowable, scroll: scroll)
        return EPUBReflowableSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: scripts,
            animatedLoad: false,
            stabilityBudget: stabilityBudget
        )
    }

    private func makeFixedSpreadView(
        scripts: [WKUserScript] = [],
        stabilityBudget: EPUBInitializationStabilityBudget = EPUBSpreadViewCommandOutcomeTests.generousStabilityBudget
    ) -> EPUBFixedSpreadView {
        let fixture = makeFixture(layout: .fixed)
        return EPUBFixedSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: scripts,
            animatedLoad: false,
            stabilityBudget: stabilityBudget
        )
    }

    private func makePagination(
        spreadView: EPUBSpreadView
    ) -> (PaginationView, SpreadPaginationDelegate) {
        let delegate = SpreadPaginationDelegate(spreadView: spreadView)
        let pagination = PaginationView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 800),
            preloadPreviousPositionCount: 0,
            preloadNextPositionCount: 0,
            isScrollEnabled: true
        )
        pagination.delegate = delegate
        pagination.reloadAtIndex(
            0,
            location: .start,
            pageCount: 1,
            readingProgression: .ltr
        )
        return (pagination, delegate)
    }

    private func hostView(_ view: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let viewController = UIViewController()
        window.rootViewController = viewController
        view.frame = viewController.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(view)
        window.makeKeyAndVisible()
        viewController.view.layoutIfNeeded()
        return window
    }

    private func makeFixture(
        layout: ReadiumShared.Layout,
        scroll: Bool = false,
        double: Bool = false
    ) -> (
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread
    ) {
        let href = RelativeURL(path: "chapter.html")!
        let secondHREF = RelativeURL(path: "facing.html")!
        let stylesheetHREF = RelativeURL(path: "late.css")!
        let link = Link(href: href.string, mediaType: .html)
        let secondLink = Link(href: secondHREF.string, mediaType: .html)
        let readingOrder = double ? [link, secondLink] : [link]
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Spread command outcome", layout: layout),
                readingOrder: readingOrder,
                resources: [Link(href: stylesheetHREF.string, mediaType: .css)]
            ),
            container: CompositeContainer(
                SingleResourceContainer(
                    resource: DataResource(string: "<!doctype html><html><head><style>body{height:10000px}</style></head><body>Chapter</body></html>"),
                    at: href.anyURL
                ),
                SingleResourceContainer(
                    resource: DataResource(string: "<!doctype html><html><body>Facing</body></html>"),
                    at: secondHREF.anyURL
                ),
                SingleResourceContainer(
                    resource: DataResource(string: "body { letter-spacing: 0; }"),
                    at: stylesheetHREF.anyURL
                )
            )
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder,
            config: .init(preferences: EPUBPreferences(scroll: scroll))
        )
        let first = EPUBSpreadResource(index: 0, link: link)
        let spread: EPUBSpread = double
            ? .double(EPUBDoubleSpread(first: first, second: EPUBSpreadResource(index: 1, link: secondLink)))
            : .single(EPUBSingleSpread(resource: first))
        return (viewModel, spread)
    }

    /// Waits for the spread's document to finish loading.
    ///
    /// This is SETUP, never the property under test: every assertion in this
    /// class is about what happens to an already-loaded document. So a wait
    /// that expires here means the host failed to deliver a precondition, and
    /// the honest verdict is a skip rather than a failure attributed to the
    /// navigator.
    ///
    /// The environmental cause is identified (#1693): under CPU starvation the
    /// simulator's WebContent process becomes unresponsive — WebKit logs
    /// `WebProcessProxy::didBecomeUnresponsive` and stops making progress with
    /// the main resource already served, so the load hangs at
    /// `estimatedProgress == 0.1` forever. WebKit exposes no delegate for that
    /// state; `webViewWebContentProcessDidTerminate` fires only on termination,
    /// which is why nothing here can convert it into a navigator-visible
    /// failure. A longer ceiling cannot help a process that is not running.
    ///
    /// Deliberately narrow: only this wait skips. An initialization that
    /// completes and reports `.failed` still fails the test, because a spent
    /// stability budget and a broken contract are indistinguishable from the
    /// outcome alone — and the budget these tests run with is wide enough that
    /// starvation is no longer the likely explanation.
    private func waitForDocumentLoad(in spreadView: EPUBSpreadView) async throws {
        do {
            try await waitUntil(reportingFailure: false) {
                guard case .loading = spreadView.readiness.state else {
                    return false
                }
                return !spreadView.webView.isLoading
            }
        } catch {
            let diagnosis = """
            state=\(spreadView.readiness.state), \
            isLoading=\(spreadView.webView.isLoading), \
            progress=\(spreadView.webView.estimatedProgress), \
            committedURL=\(spreadView.webView.url?.lastPathComponent ?? "nil")
            """

            // A skip has to be EARNED by the environmental signature, not
            // granted to every expired wait. Narrowness of site is not
            // narrowness of cause: this wait also expires when readiness never
            // enters `.loading`, when it lands in `.failed` or `.unavailable`,
            // or when the fixture stops resolving — every one of them a genuine
            // navigator defect that must stay red.
            //
            // The unresponsive-process signature is specifically: still
            // `.loading`, and WebKit still believes it is loading. That is the
            // state a WebContent process that stopped answering leaves behind,
            // because nothing can move it on.
            guard
                case .loading = spreadView.readiness.state,
                spreadView.webView.isLoading
            else {
                XCTFail("Document did not load, and not for a reason the host explains: \(diagnosis)")
                throw error
            }

            throw XCTSkip(
                """
                Environment did not deliver a loaded document — WebContent \
                process is not making progress (see #1693). \(diagnosis)
                """
            )
        }
    }

    private func enableAnimationFrames(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Page turns ask for a smooth scroll; this makes the page perform it at
    /// once, keeping the request itself.
    private func makeSmoothScrollsInstant(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            """
            const scrollBy = window.scrollBy.bind(window);
            window.scrollBy = options => scrollBy({ ...options, behavior: 'instant' });
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    private func activeAnimationFramesUserScript() -> WKUserScript {
        WKUserScript(
            source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private func installDelayedStylesheet(
        in spreadView: EPUBSpreadView,
        documentExpression: String
    ) async throws {
        let result = try await spreadView.webView.callAsyncJavaScript(
            """
            const targetDocument = \(documentExpression);
            const link = targetDocument.createElement('link');
            link.rel = 'stylesheet';
            targetDocument.head.append(link);
            let remainingFrames = 30;
            const attachStylesheet = () => {
                remainingFrames -= 1;
                if (remainingFrames === 0) {
                    link.href = 'late.css';
                } else {
                    requestAnimationFrame(attachStylesheet);
                }
            };
            requestAnimationFrame(attachStylesheet);
            return link.sheet === null;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(result, true)
    }

    private func makeLayoutStabilityCheckFail(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            "window.requestAnimationFrame = () => { throw new Error('test layout stability failure'); }; return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    private func blockAnimationFrames(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            "window.__testAnimationFrames = []; window.requestAnimationFrame = callback => { window.__testAnimationFrames.push(callback); return window.__testAnimationFrames.length; }; return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    private func releaseAnimationFrames(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            "const callbacks = window.__testAnimationFrames ?? []; window.__testAnimationFrames = []; window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0); callbacks.forEach(callback => window.requestAnimationFrame(callback)); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Liveness backstop, not a performance bound — see `waitUntil`. Setup, so
    /// an expiry is an environmental skip for the reasons `waitForDocumentLoad`
    /// documents.
    private func waitForFixedResourceLoad(in spreadView: EPUBFixedSpreadView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let loaded = try await spreadView.webView.callAsyncJavaScript(
                "const frame = document.querySelector('iframe'); return frame?.contentDocument?.URL.includes('chapter.html') === true && frame.contentDocument.readyState === 'complete';",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? Bool
            if loaded == true {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let diagnosis = """
        state=\(spreadView.readiness.state), \
        isLoading=\(spreadView.webView.isLoading), \
        progress=\(spreadView.webView.estimatedProgress)
        """

        // Same earned-skip rule as `waitForDocumentLoad`, and deliberately the
        // same shape: these two are the only skip sites, so they must not drift
        // into disagreeing about what counts as the host's fault. Here the
        // wrapper document is already loaded and it is the iframe that has not
        // arrived, so the signature is a readiness that has not failed —
        // a `.failed` or `.unavailable` spread is a navigator defect.
        switch spreadView.readiness.state {
        case .failed, .unavailable:
            XCTFail("Fixed resource did not load, and not for a reason the host explains: \(diagnosis)")
            throw TestTimeout()
        case .loading, .initializing, .ready:
            throw XCTSkip(
                """
                Environment did not deliver the fixed-layout iframe resource — \
                WebContent process is not making progress (see #1693). \(diagnosis)
                """
            )
        }
    }

    private func initializeReflowableSpread(
        _ spreadView: EPUBReflowableSpreadView
    ) async throws {
        try await waitForDocumentLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        let outcome = try await initializeLoadedReflowableSpread(spreadView)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }
    }

    /// A reflowable spread whose document has loaded, reporting to a delegate
    /// that counts its page changes.
    private func loadObservedReflowableSpread() async throws -> (EPUBReflowableSpreadView, TestSpreadDelegate) {
        let spreadView = makeReflowableSpreadView()
        let delegate = TestSpreadDelegate()
        spreadView.delegate = delegate
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await waitForDocumentLoad(in: spreadView)
        try await enableAnimationFrames(in: spreadView)
        return (spreadView, delegate)
    }

    /// A ready, registered spread whose observation has accepted a sample and
    /// has no read or obligation left.
    private func openObservedReflowableSpread() async throws -> (EPUBReflowableSpreadView, TestSpreadDelegate) {
        let (spreadView, delegate) = try await loadObservedReflowableSpread()
        let capability = EPUBSpreadFrameCapability()
        let outcome = try await initializeLoadedReflowableSpread(spreadView, frameCapability: capability)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }
        spreadView.locatorCommandBridge.setFrameCapability(capability)
        let observation = try XCTUnwrap(spreadView.builtLocationObservation)
        try await waitUntil {
            observation.currentObservation != nil && !observation.hasObligation && !observation.isReading
        }
        return (spreadView, delegate)
    }

    /// The fixture opens at its start, on the first of several pages.
    private func assertReportsTheMeasuredStart(
        of spreadView: EPUBReflowableSpreadView,
        under capability: EPUBSpreadFrameCapability,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let accepted = try XCTUnwrap(spreadView.builtLocationObservation?.currentObservation, file: file, line: line)
        XCTAssertEqual(accepted.sample.capability, capability, file: file, line: line)
        let reported = spreadView.progression(in: spreadView.spread.first.index)
        XCTAssertEqual(reported, accepted.sample.range, "The spread reports something it did not measure", file: file, line: line)
        XCTAssertEqual(reported.lowerBound, 0, file: file, line: line)
        XCTAssertGreaterThan(reported.upperBound, 0, file: file, line: line)
        XCTAssertLessThan(reported.upperBound, 1, file: file, line: line)
    }

    private func initializeLoadedReflowableSpread(
        _ spreadView: EPUBReflowableSpreadView,
        frameCapability: EPUBSpreadFrameCapability = EPUBSpreadFrameCapability()
    ) async throws -> EPUBSpreadReadiness.InitializationOutcome {
        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: frameCapability
        ))
        spreadView.applySettings()
        let outcome = await spreadView.initializeSpread()
        spreadView.readiness.finishInitialization(rootLease, outcome: outcome)
        return outcome
    }

    private func initializeLoadedFixedSpread(
        _ spreadView: EPUBFixedSpreadView
    ) async throws -> EPUBSpreadReadiness.InitializationOutcome {
        try await waitForDocumentLoad(in: spreadView)
        try await waitForFixedResourceLoad(in: spreadView)
        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
        ))
        let outcome = await spreadView.initializeSpread()
        spreadView.readiness.finishInitialization(rootLease, outcome: outcome)
        return outcome
    }

    /// Asserts the terminal disposition a genuinely failed — or unacknowledged
    /// cancelled — command must land in: the spread is no longer command-ready
    /// AND its frame-document capability is revoked, so no late frame can still
    /// be selected as the command target.
    ///
    /// The state case is `.failed`, not `.unavailable`: a current-generation
    /// failure is held distinctly from a teardown so callers can tell a genuine
    /// miss from an interruption. Both revoke identically — `.failed` admits no
    /// lease, mutation, or initialization, so readiness cannot be republished
    /// without a fresh load. Asserting the case is what pins that distinction:
    /// it goes red if a failure path reverts to invalidating the generation.
    ///
    /// Neither projection can fail independently today: `isCommandReady` and
    /// `currentFrameCapability` are both switches over the same `state`, and
    /// both return the negative for `.failed`. Letting a failed generation keep
    /// its capability would take two coordinated edits — that property's
    /// `.failed` arm AND `fail(ifCurrent:)`, which already clears the field. So
    /// they are defense in depth and a legible failure message, not independent
    /// catches; do not cite them as proof the capability is separately checked.
    ///
    /// The expected generation is pinned by the caller. Four sites read it from
    /// readiness before the failure lands; the synchronous page-turn script
    /// failure has no such window, so that site derives it from the single
    /// advance `beginMutation()` makes. Matching it here prevents an
    /// invalidate-then-fail regression from passing merely because it still
    /// lands in `.failed` with a newer identity.
    private func assertCommandCapabilityRevoked(
        in spreadView: EPUBSpreadView,
        expectedGeneration: EPUBSpreadReadiness.Generation,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            spreadView.readiness.isCommandReady,
            message,
            file: file,
            line: line
        )
        XCTAssertNil(
            spreadView.readiness.currentFrameCapability,
            message,
            file: file,
            line: line
        )
        guard case let .failed(actualGeneration) = spreadView.readiness.state else {
            return XCTFail(
                "\(message) — state=\(spreadView.readiness.state)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            actualGeneration,
            expectedGeneration,
            "\(message) — failed generation changed",
            file: file,
            line: line
        )
    }

    /// Polls a precondition until it holds.
    ///
    /// The timeout is a liveness backstop, NOT a performance bound. Every caller
    /// here waits for a real WKWebView document to reach a state that the test's
    /// own assertions then examine; none asserts "within N seconds". A predicate
    /// that is wrong stays wrong, so a generous ceiling only delays a real
    /// failure while removing the false one a loaded host produces — a 5 s
    /// ceiling was a bet on machine speed, and a saturated simulator lost it
    /// while the behaviour under test was correct.
    /// - Parameter reportingFailure: whether an expiry is itself a test failure.
    ///   Setup waits pass `false` and translate the throw into an environmental
    ///   skip; assertion waits keep the default and go red.
    private func waitUntil(
        timeout: Duration = .seconds(30),
        reportingFailure: Bool = true,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        if reportingFailure {
            XCTFail("Condition did not become true before timeout")
        }
        throw TestTimeout()
    }
}

private struct TestTimeout: Error {}

@MainActor
private final class ReflowablePaginationDelegate: PaginationViewDelegate {
    let spreadView: EPUBReflowableSpreadView
    private(set) var updateCount = 0

    init(spreadView: EPUBReflowableSpreadView) {
        self.spreadView = spreadView
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        index == 0 ? spreadView : nil
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        updateCount += 1
    }

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        1
    }
}

@MainActor
private final class SpreadPaginationDelegate: PaginationViewDelegate {
    let spreadView: EPUBSpreadView

    init(spreadView: EPUBSpreadView) {
        self.spreadView = spreadView
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        index == 0 ? spreadView : nil
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {}

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        1
    }
}

@MainActor
private final class TestSpreadDelegate: @preconcurrency EPUBSpreadViewDelegate {
    var navigationInputs = 0
    func spreadViewWillBeginUserNavigation(_ spreadView: EPUBSpreadView) {
        navigationInputs += 1
    }

    var contentInset: UIEdgeInsets = .zero

    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        contentInset
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {}
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {}
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {}
    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {}
    func spreadView(_ spreadView: EPUBSpreadView, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?) {}
    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect, domRange: DOMRange?) {}
    var pageChanges = 0
    /// The first resource's range at each page change, in order.
    private(set) var reportedRanges: [ClosedRange<Double>] = []
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        pageChanges += 1
        reportedRanges.append(spreadView.progression(in: spreadView.spread.first.index))
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {}
    func spreadViewDidTerminate() {}
}

/// Counts the freed-slot wake-ups a bridge reports, then hands every transport
/// event to the hook the spread installed, so the spread still hears them.
@MainActor
private final class FreedSlotRecorder {
    private(set) var count = 0

    init(_ bridge: EPUBLocatorCommandBridge) {
        let installed = bridge.onLocationTransportEvent
        bridge.onLocationTransportEvent = { [weak self] event in
            if event == .slotAvailable {
                self?.count += 1
            }
            installed?(event)
        }
    }
}

/// Records the capabilities a bridge reports registered, then hands each to
/// the hook the spread installed, so the spread still hears them.
@MainActor
private final class RegistrationRecorder {
    private(set) var capabilities: [EPUBSpreadFrameCapability] = []

    init(_ bridge: EPUBLocatorCommandBridge) {
        let installed = bridge.onFrameRegistered
        bridge.onFrameRegistered = { [weak self] capability in
            self?.capabilities.append(capability)
            installed?(capability)
        }
    }
}

@MainActor
private final class NavigationInputDelegate: EPUBNavigatorDelegate {
    var inputs = 0
    func navigatorWillBeginUserNavigation(_ navigator: EPUBNavigatorViewController) {
        inputs += 1
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
}
