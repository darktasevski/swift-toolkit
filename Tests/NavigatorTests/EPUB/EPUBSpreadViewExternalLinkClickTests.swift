//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// A click on a link leaving the publication is cancelled before it reaches the link and arrives as
/// one `spreadView(_:didTapOnExternalURL:)`; any other click is left to WebKit, whose navigation
/// policy routes a link inside the book to `spreadView(_:didTapOnInternalLink:clickEvent:)`. A click
/// that is not cancelled lets WebKit connect to the link's host before the policy can refuse it, so
/// the cancellation is the property, and only a loaded page with the real script shows it. Outbound
/// links point at `.invalid` hosts, so a click that does slip through reaches no network.
@MainActor
final class EPUBSpreadViewExternalLinkClickTests: XCTestCase {
    /// The head script stands for a publication that stops every click on `#blocked` in its own
    /// window capture listener, registered while the document parses. The body script builds what
    /// markup cannot: an `a` with no `href` nested in an outbound one, and an HTML `a` with only an
    /// `xlink:href`. The `srcdoc` frame has no URL of its own: it came from the chapter.
    private static let chapter = """
    <!doctype html>
    <html><head>
    <script>
    window.addEventListener("click", function (event) {
      if (event.target.id === "blocked") {
        event.stopImmediatePropagation();
        event.preventDefault();
      }
    }, true);
    </script>
    </head><body>
    <p><a id="https" href="https://example.invalid/a?t=1">https</a></p>
    <p><a href="https://example.invalid/nested"><span id="nested">nested</span></a></p>
    <p id="nested-anchor-host"></p>
    <p><a id="mailto" href="mailto:someone@example.invalid">mailto</a></p>
    <p><a id="internal" href="chapter2.html#n1">internal</a></p>
    <p><a id="fragment" href="#n1">fragment</a></p>
    <p><a id="script" href="javascript:void(0)">script</a></p>
    <p><a id="no-href">no href</a></p>
    <p id="html-xlink-host"></p>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="40">
    <a href="https://example.invalid/svg"><text id="svg" x="0" y="15">svg</text></a>
    <a xlink:href="https://example.invalid/xlink"><text id="xlink" x="0" y="35">xlink</text></a>
    </svg>
    <math><mi id="mathml" href="https://example.invalid/mathml">x</mi><mi id="mathml-internal" href="chapter2.html#m">y</mi></math>
    <map name="map"><area id="area" shape="rect" coords="0,0,10,10" href="https://example.invalid/area"></map>
    <p><a id="middle" href="https://example.invalid/middle">middle</a></p>
    <p><a id="right" href="https://example.invalid/right">right</a></p>
    <p><a id="blocked" href="https://example.invalid/blocked">blocked</a></p>
    <p><a id="based" href="based">based</a></p>
    <div id="shadow-host"></div>
    <script>
    document.getElementById("shadow-host").attachShadow({ mode: "open" }).innerHTML =
      '<a id="inner" href="https://example.invalid/shadow">shadow</a>';
    const outer = document.createElement("a");
    outer.href = "https://example.invalid/outer";
    const anchor = document.createElement("a");
    anchor.id = "nested-anchor";
    anchor.textContent = "cite";
    outer.append(anchor);
    document.getElementById("nested-anchor-host").append(outer);
    const xlinkOnly = document.createElement("a");
    xlinkOnly.id = "html-xlink";
    xlinkOnly.textContent = "xlink only";
    xlinkOnly.setAttributeNS("http://www.w3.org/1999/xlink", "xlink:href", "https://example.invalid/html-xlink");
    document.getElementById("html-xlink-host").append(xlinkOnly);
    </script>
    <iframe id="srcdoc" srcdoc='<a id="external" href="https://example.invalid/srcdoc">e</a><a id="internal" href="chapter2.html">i</a>'></iframe>
    <p><a id="barrier" href="https://example.invalid/barrier">barrier</a></p>
    <p><a id="internal-barrier" href="chapter2.html#barrier">internal barrier</a></p>
    <p id="n1">note</p>
    </body></html>
    """

    private struct Click {
        let name: String
        /// A JS expression for the element the click is dispatched on, given the document `doc`.
        let target: String
        var type = "click"
        var button = 0
        var setUp = ""
        var tearDown = ""
        /// The URL the script hands the navigator, or `nil` when the click is left to WebKit.
        var leaves: String?
        /// The href WebKit's navigation policy hands the navigator for a link inside the book.
        var opensInside: String?
        /// Whether the click is already cancelled when it reaches the link: what keeps WebKit from
        /// connecting. `nil` when it never reaches the link.
        let cancelledAtLink: Bool?

        static func leaving(_ name: String, _ target: String, _ url: String) -> Click {
            Click(name: name, target: target, leaves: url, cancelledAtLink: true)
        }

        static func left(_ name: String, _ target: String, opensInside href: String? = nil) -> Click {
            Click(name: name, target: target, opensInside: href, cancelledAtLink: false)
        }
    }

    private static let barriers: [Click] = [
        .leaving("the barrier", #"doc.getElementById("barrier")"#, "https://example.invalid/barrier"),
        .left("the internal barrier", #"doc.getElementById("internal-barrier")"#, opensInside: "chapter2.html#barrier"),
    ]

    func testAReflowableClickOnALinkLeavingThePublicationIsCancelledAndHandedOver() async throws {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }

        let clicks: [Click] = [
            .leaving("an https link", #"doc.getElementById("https")"#, "https://example.invalid/a?t=1"),
            .leaving("an element inside a link", #"doc.getElementById("nested")"#, "https://example.invalid/nested"),
            .leaving(
                "an anchor without an href inside an outbound link",
                #"doc.getElementById("nested-anchor")"#,
                "https://example.invalid/outer"
            ),
            .leaving("a mailto link", #"doc.getElementById("mailto")"#, "mailto:someone@example.invalid"),
            .left("a link to another resource", #"doc.getElementById("internal")"#, opensInside: "chapter2.html#n1"),
            .left("a link to a fragment", #"doc.getElementById("fragment")"#, opensInside: "chapter.html#n1"),
            .left("a javascript link", #"doc.getElementById("script")"#),
            .left("an anchor without an href", #"doc.getElementById("no-href")"#),
            .left("an HTML anchor with only an xlink:href", #"doc.getElementById("html-xlink")"#),
            .leaving("an SVG link", #"doc.getElementById("svg")"#, "https://example.invalid/svg"),
            .leaving("an SVG 1.1 xlink:href link", #"doc.getElementById("xlink")"#, "https://example.invalid/xlink"),
            .leaving("a MathML href", #"doc.getElementById("mathml")"#, "https://example.invalid/mathml"),
            .left(
                "a MathML href inside the book",
                #"doc.getElementById("mathml-internal")"#,
                opensInside: "chapter2.html#m"
            ),
            .leaving("an image-map area", #"doc.getElementById("area")"#, "https://example.invalid/area"),
            .leaving(
                "a link in an open shadow root",
                #"doc.getElementById("shadow-host").shadowRoot.getElementById("inner")"#,
                "https://example.invalid/shadow"
            ),
            .leaving(
                "a link leaving from a srcdoc frame",
                #"doc.getElementById("srcdoc").contentDocument.getElementById("external")"#,
                "https://example.invalid/srcdoc"
            ),
            .left(
                "a link to another resource from a srcdoc frame",
                #"doc.getElementById("srcdoc").contentDocument.getElementById("internal")"#,
                opensInside: "chapter2.html"
            ),
            Click(
                name: "a middle-button click",
                target: #"doc.getElementById("middle")"#,
                type: "auxclick",
                button: 1,
                leaves: "https://example.invalid/middle",
                cancelledAtLink: true
            ),
            Click(
                name: "a fourth-button auxclick, which WebKit also activates links with",
                target: #"doc.getElementById("middle")"#,
                type: "auxclick",
                button: 3,
                leaves: "https://example.invalid/middle",
                cancelledAtLink: true
            ),
            Click(
                name: "a right-button auxclick",
                target: #"doc.getElementById("right")"#,
                type: "auxclick",
                button: 2,
                cancelledAtLink: false
            ),
            Click(
                name: "a link the publication's own capture listener stops",
                target: #"doc.getElementById("blocked")"#,
                leaves: "https://example.invalid/blocked",
                cancelledAtLink: nil
            ),
            Click(
                name: "a link resolved against a <base href> on the link's host",
                target: #"doc.getElementById("based")"#,
                setUp: #"""
                const base = doc.createElement("base");
                base.href = "https://example.invalid/";
                doc.head.appendChild(base);
                """#,
                tearDown: "base.remove();",
                leaves: "https://example.invalid/based",
                cancelledAtLink: true
            ),
            Click(
                name: "a link clicked after the publication replaced URL and composedPath",
                target: #"doc.getElementById("https")"#,
                setUp: #"""
                const savedURL = doc.defaultView.URL;
                const savedComposedPath = doc.defaultView.Event.prototype.composedPath;
                doc.defaultView.URL = function () { throw new Error("replaced by the publication"); };
                doc.defaultView.Event.prototype.composedPath = function () { return []; };
                """#,
                tearDown: #"""
                doc.defaultView.URL = savedURL;
                doc.defaultView.Event.prototype.composedPath = savedComposedPath;
                """#,
                leaves: "https://example.invalid/a?t=1",
                cancelledAtLink: true
            ),
        ]

        try await assertClicks(clicks, in: spreadView, document: "document", delegate: delegate)
    }

    /// A fixed-layout resource is loaded in the wrapper page's iframe, which runs its own copy of
    /// the script.
    func testAFixedLayoutClickOnALinkLeavingThePublicationIsCancelledAndHandedOver() async throws {
        let spreadView = EPUBSpreadViewHosting.makeFixedSpreadView(chapter: Self.chapter)
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        try await EPUBSpreadViewHosting.waitForFixedResourceLoad(in: spreadView)
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }

        let clicks: [Click] = [
            .leaving("an https link", #"doc.getElementById("https")"#, "https://example.invalid/a?t=1"),
            .left("a link to another resource", #"doc.getElementById("internal")"#, opensInside: "chapter2.html#n1"),
        ]

        try await assertClicks(
            clicks,
            in: spreadView,
            document: #"document.querySelector("iframe").contentDocument"#,
            delegate: delegate
        )
    }

    /// The handler exists only in the script's own world, so a publication script cannot post the
    /// activation; the control asks the same question in that world.
    func testAPublicationScriptCannotPostTheActivation() async throws {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }
        let probe = "return typeof globalThis.webkit?.messageHandlers?.externalLinkActivated;"

        let inPage = try await spreadView.webView.callAsyncJavaScript(probe, arguments: [:], in: nil, contentWorld: .page)
        let inScriptWorld = try await spreadView.webView.callAsyncJavaScript(
            probe,
            arguments: [:],
            in: nil,
            contentWorld: EPUBExternalLinkActivationBridge.contentWorld
        )

        XCTAssertEqual(inPage as? String, "undefined")
        XCTAssertEqual(inScriptWorld as? String, "object")
    }

    /// With no handler to post to, the script leaves the click to WebKit, whose navigation policy
    /// still hands the link over, rather than cancelling a click it cannot report.
    func testAClickTheScriptCannotReportIsLeftToTheNavigationPolicy() async throws {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }
        spreadView.externalLinkActivationBridge.disableMessageHandler()

        let cancelledAtLink = try await dispatch(
            .left("an https link", #"doc.getElementById("https")"#),
            in: spreadView.webView,
            document: "document"
        )

        XCTAssertEqual(cancelledAtLink, false)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/a?t=1"))
        try await EPUBSpreadViewHosting.waitUntil { delegate.externalURLs == [url] }
    }

    /// Dispatches each click, then two barriers. Script messages arrive in the order they were
    /// posted and the main frame's navigations are decided in order, so once both barriers have
    /// arrived, anything a click should not have produced would have arrived too.
    private func assertClicks(
        _ clicks: [Click],
        in spreadView: EPUBSpreadView,
        document: String,
        delegate: RecordingSpreadDelegate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for click in clicks + Self.barriers {
            let cancelledAtLink = try await dispatch(click, in: spreadView.webView, document: document)
            XCTAssertEqual(cancelledAtLink, click.cancelledAtLink, "cancelled at the link: \(click.name)", file: file, line: line)
        }

        let barrierURL = try XCTUnwrap(try URL(string: XCTUnwrap(Self.barriers[0].leaves)))
        let internalBarrier = try XCTUnwrap(Self.barriers[1].opensInside)
        try await EPUBSpreadViewHosting.waitUntil(file: file, line: line) {
            delegate.externalURLs.contains(barrierURL) && delegate.internalLinks.contains(internalBarrier)
        }

        let all = clicks + Self.barriers
        XCTAssertEqual(
            delegate.externalURLs.map(\.absoluteString),
            all.compactMap(\.leaves),
            "the URLs handed over as leaving",
            file: file,
            line: line
        )
        XCTAssertEqual(
            delegate.internalLinks,
            all.compactMap(\.opensInside),
            "the links the navigation policy opened inside the book",
            file: file,
            line: line
        )
    }

    /// Dispatches `click` on its target and reports whether it was already cancelled when it got
    /// there. The listener that records it changes nothing, so a click the script leaves alone gets
    /// WebKit's own handling.
    private func dispatch(_ click: Click, in webView: WKWebView, document: String) async throws -> Bool? {
        let body = """
        const doc = \(document);
        \(click.setUp)
        const target = \(click.target);
        let cancelledAtLink = null;
        const probe = (event) => { cancelledAtLink = event.defaultPrevented; };
        target.addEventListener(type, probe);
        target.dispatchEvent(new target.ownerDocument.defaultView.MouseEvent(type, {
          bubbles: true, cancelable: true, composed: true, button: button,
        }));
        target.removeEventListener(type, probe);
        \(click.tearDown)
        return cancelledAtLink;
        """
        let result = try await webView.callAsyncJavaScript(
            body,
            arguments: ["type": click.type, "button": click.button],
            in: nil,
            contentWorld: .page
        )
        return result as? Bool
    }
}
