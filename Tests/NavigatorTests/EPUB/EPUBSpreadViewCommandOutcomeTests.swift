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
    func testReflowableRuntimeInsetFailureNeverRepublishesReady() async throws {
        let spreadView = makeReflowableSpreadView(scroll: true)
        let delegate = TestSpreadDelegate()
        spreadView.delegate = delegate
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        spreadView.layoutIfNeeded()
        try await initializeReflowableSpread(spreadView)
        try await makeLayoutUnstable(in: spreadView)

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

    private func makeLayoutUnstable(in spreadView: EPUBSpreadView) async throws {
        _ = try await spreadView.webView.callAsyncJavaScript(
            "let tall = false; window.requestAnimationFrame = callback => setTimeout(() => { tall = !tall; document.body.style.height = tall ? '10000px' : '12000px'; callback(performance.now()); }, 0); return true;",
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
