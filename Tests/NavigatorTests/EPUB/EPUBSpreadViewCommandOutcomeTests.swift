//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class EPUBSpreadViewCommandOutcomeTests: XCTestCase {
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
        XCTAssertFalse(spreadView.readiness.isCommandReady)
        guard case .unavailable = spreadView.readiness.state else {
            return XCTFail("Failed page turn republished command readiness")
        }
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
        XCTAssertFalse(spreadView.readiness.isCommandReady)
        guard case .unavailable = spreadView.readiness.state else {
            return XCTFail("Cancelled page turn retained frame capability")
        }
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
        XCTAssertFalse(spreadView.readiness.isCommandReady)
        guard case .unavailable = spreadView.readiness.state else {
            return XCTFail("Pagination caller cancellation retained reflow capability")
        }
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

        XCTAssertEqual(outcome, .invalidated)
        XCTAssertFalse(spreadView.readiness.isCommandReady)
        guard case .unavailable = spreadView.readiness.state else {
            return XCTFail("Failed runtime inset mutation republished command readiness")
        }
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
        XCTAssertFalse(spreadView.readiness.isCommandReady)
        guard case .unavailable = spreadView.readiness.state else {
            return XCTFail("Unacknowledged cancellation retained frame capability")
        }
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

    func testReflowableFailedReadinessIsNotReportedAsSuccess() async {
        let spreadView = makeReflowableSpreadView()
        spreadView.clear()
        _ = spreadView.readiness.beginLoading()

        let navigation = Task { @MainActor in
            await spreadView.go(to: .end, animated: false)
        }
        await Task.yield()
        spreadView.readiness.invalidate()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .failed)
    }

    func testFixedFailedReadinessIsNotReportedAsSuccess() async {
        let spreadView = makeFixedSpreadView()
        spreadView.clear()
        _ = spreadView.readiness.beginLoading()

        let navigation = Task { @MainActor in
            await spreadView.go(to: .start, animated: false)
        }
        await Task.yield()
        spreadView.readiness.invalidate()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .failed)
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

    private func makeReflowableSpreadView(scroll: Bool = false) -> EPUBReflowableSpreadView {
        let fixture = makeFixture(layout: .reflowable, scroll: scroll)
        return EPUBReflowableSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: [],
            animatedLoad: false
        )
    }

    private func makeFixedSpreadView() -> EPUBFixedSpreadView {
        let fixture = makeFixture(layout: .fixed)
        return EPUBFixedSpreadView(
            viewModel: fixture.viewModel,
            spread: fixture.spread,
            scripts: [],
            animatedLoad: false
        )
    }

    private func makeFixture(
        layout: ReadiumShared.Layout,
        scroll: Bool = false
    ) -> (
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread
    ) {
        let href = RelativeURL(path: "chapter.html")!
        let link = Link(href: href.string, mediaType: .html)
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Spread command outcome", layout: layout),
                readingOrder: [link]
            ),
            container: SingleResourceContainer(
                resource: DataResource(string: "<!doctype html><html><head><style>body{height:10000px}</style></head><body>Chapter</body></html>"),
                at: href.anyURL
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

    private func waitForFixedResourceLoad(in spreadView: EPUBFixedSpreadView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
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
        let generation = spreadView.readiness.generation
        let rootLease = try XCTUnwrap(spreadView.readiness.beginInitialization(
            for: generation,
            frameCapability: EPUBSpreadFrameCapability()
        ))
        spreadView.applySettings()
        let outcome = await spreadView.initializeSpread()
        spreadView.readiness.finishInitialization(rootLease, outcome: outcome)
        XCTAssertEqual(outcome, .succeeded)
        try await waitUntil { spreadView.readiness.isCommandReady }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
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
