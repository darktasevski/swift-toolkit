//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

/// Builds, hosts and waits for real spread views, for tests that drive a loaded WKWebView.
@MainActor
enum EPUBSpreadViewHosting {
    struct Timeout: Error {}

    /// The resource both factories serve the chapter at.
    static let chapterHREF = "chapter.html"

    /// A reflowable spread over a one-chapter publication whose `chapter.html` is `html`, framed as
    /// the suites that wait for a load off a window frame theirs: a web view with no size may not load.
    static func makeReflowableSpreadView(chapter html: String) -> EPUBReflowableSpreadView {
        let (viewModel, spread) = makeFixture(layout: .reflowable, chapter: html)
        let spreadView = EPUBReflowableSpreadView(viewModel: viewModel, spread: spread, scripts: [], animatedLoad: false)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        return spreadView
    }

    /// A fixed-layout spread over a one-chapter publication whose `chapter.html` is `html`, which
    /// the wrapper page loads in an iframe. Framed like `makeReflowableSpreadView(chapter:)`.
    static func makeFixedSpreadView(chapter html: String) -> EPUBFixedSpreadView {
        let (viewModel, spread) = makeFixture(layout: .fixed, chapter: html)
        let spreadView = EPUBFixedSpreadView(viewModel: viewModel, spread: spread, scripts: [], animatedLoad: false)
        spreadView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        return spreadView
    }

    private static func makeFixture(
        layout: ReadiumShared.Layout,
        chapter html: String
    ) -> (EPUBNavigatorViewModel, EPUBSpread) {
        let link = Link(href: chapterHREF, mediaType: .html)
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Hosted spread", layout: layout), readingOrder: [link]),
            container: SingleResourceContainer(
                resource: DataResource(string: html),
                at: RelativeURL(path: chapterHREF)!.anyURL
            )
        )
        let viewModel = EPUBNavigatorViewModel(publication: publication, readingOrder: [link], config: .init())
        return (viewModel, .single(EPUBSingleSpread(resource: EPUBSpreadResource(index: 0, link: link))))
    }

    /// Puts `view` in a visible window. A spread view adds its JS message handlers once it has a
    /// superview, so a test that needs a message from the page hosts it first.
    static func host(_ view: UIView) -> UIWindow {
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

    /// Waits for the spread's document to finish loading.
    ///
    /// This is SETUP, never the property under test: every assertion that uses
    /// it is about what happens to an already-loaded document. So a wait that
    /// expires here means the host failed to deliver a precondition, and the
    /// honest verdict is a skip rather than a failure attributed to the
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
    static func waitForDocumentLoad(in spreadView: EPUBSpreadView) async throws {
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

    /// Liveness backstop, not a performance bound — see `waitUntil`. Setup, so
    /// an expiry is an environmental skip for the reasons `waitForDocumentLoad`
    /// documents.
    /// - Parameter resourceHREF: the resource the iframe is expected to hold.
    static func waitForFixedResourceLoad(
        in spreadView: EPUBFixedSpreadView,
        resourceHREF: String = chapterHREF
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let loaded = try await spreadView.webView.callAsyncJavaScript(
                "const frame = document.querySelector('iframe'); return frame?.contentDocument?.URL.includes(resourceHREF) === true && frame.contentDocument.readyState === 'complete';",
                arguments: ["resourceHREF": resourceHREF],
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
            throw Timeout()
        case .loading, .initializing, .ready:
            throw XCTSkip(
                """
                Environment did not deliver the fixed-layout iframe resource — \
                WebContent process is not making progress (see #1693). \(diagnosis)
                """
            )
        }
    }

    /// Polls a precondition until it holds.
    ///
    /// The timeout is a liveness backstop, NOT a performance bound. Every caller
    /// waits for a real WKWebView document to reach a state that the test's own
    /// assertions then examine; none asserts "within N seconds". A predicate
    /// that is wrong stays wrong, so a generous ceiling only delays a real
    /// failure while removing the false one a loaded host produces — a 5 s
    /// ceiling was a bet on machine speed, and a saturated simulator lost it
    /// while the behaviour under test was correct.
    /// - Parameter reportingFailure: whether an expiry is itself a test failure.
    ///   Setup waits pass `false` and translate the throw into an environmental
    ///   skip; assertion waits keep the default and go red.
    static func waitUntil(
        timeout: Duration = .seconds(30),
        reportingFailure: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line,
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
            XCTFail("Condition did not become true before timeout", file: file, line: line)
        }
        throw Timeout()
    }
}

/// Records the link reports a spread view hands its delegate; everything else is ignored.
@MainActor
final class RecordingSpreadDelegate: @preconcurrency EPUBSpreadViewDelegate {
    private(set) var externalURLs: [URL] = []
    private(set) var internalLinks: [String] = []

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        externalURLs.append(url)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        internalLinks.append(href)
    }

    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        .zero
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {}
    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {}
    func spreadView(_ spreadView: EPUBSpreadView, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?) {}
    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect, domRange: DOMRange?) {}
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {}
    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {}
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {}
    func spreadViewDidTerminate() {}
}
