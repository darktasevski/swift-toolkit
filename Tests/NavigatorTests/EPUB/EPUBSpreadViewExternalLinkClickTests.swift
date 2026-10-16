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
/// one `spreadView(_:didTapOnExternalURL:)`; any other click is left to WebKit. A click that is not
/// cancelled lets WebKit connect to the link's host before the navigation delegate can refuse it, so
/// the cancellation is the property, and only a loaded page with the real script bundle shows it.
@MainActor
final class EPUBSpreadViewExternalLinkClickTests: XCTestCase {
    /// The head script stands for a publication that stops every click on `#blocked` in its own
    /// window capture listener, registered while the document parses. The `srcdoc` frame has no URL
    /// of its own: it came from the chapter.
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
    <p><a id="https" href="https://example.com/a?t=1">https</a></p>
    <p><a href="https://example.com/nested"><span id="nested">nested</span></a></p>
    <p><a id="mailto" href="mailto:someone@example.com">mailto</a></p>
    <p><a id="internal" href="chapter2.html#n1">internal</a></p>
    <p><a id="fragment" href="#n1">fragment</a></p>
    <p><a id="script" href="javascript:void(0)">script</a></p>
    <p><a id="no-href">no href</a></p>
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="40">
    <a href="https://example.com/svg"><text id="svg" x="0" y="15">svg</text></a>
    <a xlink:href="https://example.com/xlink"><text id="xlink" x="0" y="35">xlink</text></a>
    </svg>
    <map name="map"><area id="area" shape="rect" coords="0,0,10,10" href="https://example.com/area"></map>
    <p><a id="middle" href="https://example.com/middle">middle</a></p>
    <p><a id="right" href="https://example.com/right">right</a></p>
    <p><a id="blocked" href="https://example.com/blocked">blocked</a></p>
    <p><a id="based" href="based">based</a></p>
    <div id="shadow-host"></div>
    <script>
    document.getElementById("shadow-host").attachShadow({ mode: "open" }).innerHTML =
      '<a id="inner" href="https://example.com/shadow">shadow</a>';
    </script>
    <iframe id="srcdoc" srcdoc='<a id="external" href="https://example.com/srcdoc">e</a><a id="internal" href="chapter2.html">i</a>'></iframe>
    <p><a id="barrier" href="https://example.com/barrier">barrier</a></p>
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
        /// The URL the navigator is handed, or `nil` when the click is left to WebKit.
        let leaves: String?
        /// Whether the click is already cancelled when it reaches the link: what keeps WebKit from
        /// connecting. `nil` when it never reaches the link.
        let cancelledAtLink: Bool?

        static func leaving(_ name: String, _ target: String, _ url: String) -> Click {
            Click(name: name, target: target, leaves: url, cancelledAtLink: true)
        }

        static func left(_ name: String, _ target: String) -> Click {
            Click(name: name, target: target, leaves: nil, cancelledAtLink: false)
        }
    }

    private static let barrier = Click.leaving("the barrier", #"doc.getElementById("barrier")"#, "https://example.com/barrier")

    func testAReflowableClickOnALinkLeavingThePublicationIsCancelledAndHandedOver() async throws {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer { window.isHidden = true }

        let clicks: [Click] = [
            .leaving("an https link", #"doc.getElementById("https")"#, "https://example.com/a?t=1"),
            .leaving("an element inside a link", #"doc.getElementById("nested")"#, "https://example.com/nested"),
            .leaving("a mailto link", #"doc.getElementById("mailto")"#, "mailto:someone@example.com"),
            .left("a link to another resource", #"doc.getElementById("internal")"#),
            .left("a link to a fragment", #"doc.getElementById("fragment")"#),
            .left("a javascript link", #"doc.getElementById("script")"#),
            .left("an anchor without an href", #"doc.getElementById("no-href")"#),
            .leaving("an SVG link", #"doc.getElementById("svg")"#, "https://example.com/svg"),
            .leaving("an SVG 1.1 xlink:href link", #"doc.getElementById("xlink")"#, "https://example.com/xlink"),
            .leaving("an image-map area", #"doc.getElementById("area")"#, "https://example.com/area"),
            .leaving(
                "a link in an open shadow root",
                #"doc.getElementById("shadow-host").shadowRoot.getElementById("inner")"#,
                "https://example.com/shadow"
            ),
            .leaving(
                "a link leaving from a srcdoc frame",
                #"doc.getElementById("srcdoc").contentDocument.getElementById("external")"#,
                "https://example.com/srcdoc"
            ),
            .left(
                "a link to another resource from a srcdoc frame",
                #"doc.getElementById("srcdoc").contentDocument.getElementById("internal")"#
            ),
            Click(name: "a middle-button click", target: #"doc.getElementById("middle")"#, type: "auxclick", button: 1, leaves: "https://example.com/middle", cancelledAtLink: true),
            Click(name: "a right-button auxclick", target: #"doc.getElementById("right")"#, type: "auxclick", button: 2, leaves: nil, cancelledAtLink: false),
            Click(
                name: "a link the publication's own capture listener stops",
                target: #"doc.getElementById("blocked")"#,
                leaves: "https://example.com/blocked",
                cancelledAtLink: nil
            ),
            Click(
                name: "a link resolved against a <base href> on the link's host",
                target: #"doc.getElementById("based")"#,
                setUp: #"""
                const base = doc.createElement("base");
                base.href = "https://example.com/";
                doc.head.appendChild(base);
                """#,
                tearDown: "base.remove();",
                leaves: "https://example.com/based",
                cancelledAtLink: true
            ),
        ]

        try await assertClicks(clicks, in: spreadView, document: "document", delegate: delegate)
    }

    /// A fixed-layout resource is loaded in the wrapper page's iframe, which runs its own copy of
    /// the script bundle.
    func testAFixedLayoutClickOnALinkLeavingThePublicationIsCancelledAndHandedOver() async throws {
        let spreadView = EPUBSpreadViewHosting.makeFixedSpreadView(chapter: Self.chapter)
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate
        // Hosted first: off a window, the wrapper page stalled at 10% progress on four runs of five.
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer { window.isHidden = true }
        try await EPUBSpreadViewHosting.waitForDocumentLoad(in: spreadView)
        try await EPUBSpreadViewHosting.waitForFixedResourceLoad(in: spreadView)

        let clicks: [Click] = [
            .leaving("an https link", #"doc.getElementById("https")"#, "https://example.com/a?t=1"),
            .left("a link to another resource", #"doc.getElementById("internal")"#),
        ]

        try await assertClicks(
            clicks,
            in: spreadView,
            document: #"document.querySelector("iframe").contentDocument"#,
            delegate: delegate
        )
    }

    /// Dispatches each click, then a last one to a known URL. Messages from the page arrive in the
    /// order they were posted, so once that URL has arrived, any URL a click should not have handed
    /// over would have arrived too.
    private func assertClicks(
        _ clicks: [Click],
        in spreadView: EPUBSpreadView,
        document: String,
        delegate: RecordingSpreadDelegate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for click in clicks + [Self.barrier] {
            let cancelledAtLink = try await dispatch(click, in: spreadView.webView, document: document)
            XCTAssertEqual(cancelledAtLink, click.cancelledAtLink, "cancelled at the link: \(click.name)", file: file, line: line)
        }

        let barrier = try XCTUnwrap(URL(string: try XCTUnwrap(Self.barrier.leaves)))
        try await EPUBSpreadViewHosting.waitUntil { delegate.externalURLs.contains(barrier) }

        XCTAssertEqual(
            delegate.externalURLs.map(\.absoluteString),
            clicks.compactMap(\.leaves) + [barrier.absoluteString],
            "the URLs handed to the navigator",
            file: file,
            line: line
        )
        XCTAssertEqual(delegate.internalLinks, [], "no click reached the navigation delegate", file: file, line: line)
    }

    /// Dispatches `click` on its target and reports whether it was already cancelled when it got
    /// there. A listener on the target records that, then cancels the click and stops it, so no
    /// click navigates and nothing after the link sees it.
    private func dispatch(_ click: Click, in webView: WKWebView, document: String) async throws -> Bool? {
        let body = """
        const doc = \(document);
        \(click.setUp)
        const target = \(click.target);
        let cancelledAtLink = null;
        const probe = (event) => {
          cancelledAtLink = event.defaultPrevented;
          event.preventDefault();
          event.stopPropagation();
        };
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
