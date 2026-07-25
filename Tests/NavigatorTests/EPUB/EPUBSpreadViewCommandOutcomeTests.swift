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

        let outcome = await spreadView.go(
            to: .right,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .failed)
        assertCommandCapabilityRevoked(
            in: spreadView,
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
        turn.cancel()

        let outcome = await turn.value
        XCTAssertEqual(outcome, .cancelled)
        assertCommandCapabilityRevoked(
            in: spreadView,
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
        let offsetAtCancellation = spreadView.scrollView.contentOffset

        navigation.cancel()
        try await releaseAnimationFrames(in: spreadView)

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(spreadView.scrollView.contentOffset, offsetAtCancellation)
        assertCommandCapabilityRevoked(
            in: spreadView,
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
        cancelled.cancel()
        try await releaseAnimationFrames(in: spreadView)

        let outcome = await cancelled.value
        XCTAssertEqual(outcome, .cancelled)
        assertCommandCapabilityRevoked(
            in: spreadView,
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
        let spreadView = makeReflowableSpreadView()
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

        let clock = ContinuousClock()
        let startedAt = clock.now
        let outcome = try await initializeLoadedReflowableSpread(spreadView)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(outcome, .failed)
        // The claim is a budget COUNT, not a machine speed: an unavailable
        // stylesheet must consume exactly one stability budget, never re-arm a
        // fresh one per rung. So the window discriminates one budget from two
        // and nothing finer — a tighter upper bound measures how loaded the host
        // is, which is why this assertion used to fail on a busy machine while
        // the behaviour it guards was correct. Both bounds carry the same 250 ms
        // tolerance: at least one full budget elapsed, and strictly fewer than
        // two did.
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(EPUBSpreadReadiness.initializationStabilityBudgetMilliseconds - 250)
        )
        XCTAssertLessThan(
            elapsed,
            .milliseconds(2 * EPUBSpreadReadiness.initializationStabilityBudgetMilliseconds - 250)
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

    private func makeReflowableSpreadView(
        scroll: Bool = false,
        scripts: [WKUserScript] = []
    ) -> EPUBReflowableSpreadView {
        let fixture = makeFixture(layout: .reflowable, scroll: scroll)
        return EPUBReflowableSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: scripts,
            animatedLoad: false
        )
    }

    private func makeFixedSpreadView(
        scripts: [WKUserScript] = []
    ) -> EPUBFixedSpreadView {
        let fixture = makeFixture(layout: .fixed)
        return EPUBFixedSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: scripts,
            animatedLoad: false
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
        scroll: Bool = false
    ) -> (
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread
    ) {
        let href = RelativeURL(path: "chapter.html")!
        let stylesheetHREF = RelativeURL(path: "late.css")!
        let link = Link(href: href.string, mediaType: .html)
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Spread command outcome", layout: layout),
                readingOrder: [link],
                resources: [Link(href: stylesheetHREF.string, mediaType: .css)]
            ),
            container: CompositeContainer(
                SingleResourceContainer(
                    resource: DataResource(string: "<!doctype html><html><head><style>body{height:10000px}</style></head><body>Chapter</body></html>"),
                    at: href.anyURL
                ),
                SingleResourceContainer(
                    resource: DataResource(string: "body { letter-spacing: 0; }"),
                    at: stylesheetHREF.anyURL
                )
            )
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: [link],
            config: .init(preferences: EPUBPreferences(scroll: scroll))
        )
        let spread = EPUBSpread.single(EPUBSingleSpread(
            resource: EPUBSpreadResource(index: 0, link: link)
        ))
        return (viewModel, spread)
    }

    private func waitForDocumentLoad(in spreadView: EPUBSpreadView) async throws {
        do {
            try await waitUntil {
                guard case .loading = spreadView.readiness.state else {
                    return false
                }
                return !spreadView.webView.isLoading
            }
        } catch {
            XCTFail("Document did not load: state=\(spreadView.readiness.state), isLoading=\(spreadView.webView.isLoading)")
            throw error
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

    /// Liveness backstop, not a performance bound — see `waitUntil`.
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
        XCTFail("Fixed resource did not become available before timeout")
        throw TestTimeout()
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

    private func initializeLoadedReflowableSpread(
        _ spreadView: EPUBReflowableSpreadView
    ) async throws -> EPUBSpreadReadiness.InitializationOutcome {
        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
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
    /// Known weaker than the contract: matching `.failed` without its
    /// generation lets a regression that invalidated-then-failed (landing
    /// `.failed(generation + 1)`) pass, while `fail(ifCurrent:)` promises the
    /// identity is unchanged. Pinning the expected generation here is tracked in
    /// issue #1708 rather than done, because four of the five call sites must
    /// first capture the generation before the act that fails.
    private func assertCommandCapabilityRevoked(
        in spreadView: EPUBSpreadView,
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
        guard case .failed = spreadView.readiness.state else {
            return XCTFail(
                "\(message) — state=\(spreadView.readiness.state)",
                file: file,
                line: line
            )
        }
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
    private func waitUntil(
        timeout: Duration = .seconds(30),
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
        XCTFail("Condition did not become true before timeout")
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
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {}
    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {}
    func spreadViewDidTerminate() {}
}
