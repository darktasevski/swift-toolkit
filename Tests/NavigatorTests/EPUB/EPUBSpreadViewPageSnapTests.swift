//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// A body resize in a paginated resource re-snaps the scroll offset to the start of its page. The
/// page is the scrollport's width, measured when the snap runs: `window.innerWidth`, the visual
/// viewport, reads 0 for a moment after a resource transition while the layout is already sized, and
/// a width of 0 snapped every offset to `NaN`, which WebKit writes to `scrollLeft` as 0 (#1677).
@MainActor
final class EPUBSpreadViewPageSnapTests: XCTestCase {
    /// Paginated by its own columns, so the test does not depend on how ReadiumCSS lays out a page.
    private static let chapter: String = {
        let paragraph = "<p>" + String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40) + "</p>"
        return """
        <!doctype html>
        <html><head><style>
        :root {
          margin: 0 !important; padding: 0 !important; height: 100vh !important;
          column-width: 100vw !important; column-gap: 0 !important; column-fill: auto !important;
        }
        body { margin: 0 !important; padding: 0 !important; }
        </style></head><body>
        \(String(repeating: paragraph, count: 30))
        </body></html>
        """
    }()

    /// Off a page boundary, so a snap that ran is visible as a move to the page start.
    private static let offPage = 37.0

    /// What the page's own snap left behind once a body resize has run it.
    private struct Snap {
        let page: Double
        let before: Double
        let after: Double
    }

    func testAResizeWhileTheVisualViewportReadsZeroSnapsToThePageStart() async throws {
        let snap = try await snapAfterResize(zeroing: #"Object.defineProperty(window, "innerWidth", { configurable: true, get: () => 0 });"#)

        XCTAssertEqual(snap.before, 2 * snap.page + Self.offPage, "The setup scroll did not hold")
        XCTAssertEqual(snap.after, 2 * snap.page, "The snap measured the visual viewport instead of the scrollport")
    }

    func testAResizeWithNoMeasurablePageLeavesTheOffsetAlone() async throws {
        let snap = try await snapAfterResize(zeroing: """
        Object.defineProperty(window, "innerWidth", { configurable: true, get: () => 0 });
        Object.defineProperty(document.scrollingElement, "clientWidth", { configurable: true, get: () => 0 });
        """)

        XCTAssertEqual(snap.before, 2 * snap.page + Self.offPage, "The setup scroll did not hold")
        XCTAssertEqual(snap.after, snap.before, "A snap with no page width moved the offset")
    }

    /// Scrolls the third page off its boundary, runs `zeroing`, resizes the body, and reads the offset
    /// in a frame after the page's own resize handling. Its observer was registered at `load`, before
    /// this one, so its frame callback has already run.
    private func snapAfterResize(zeroing: String) async throws -> Snap {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        // Hosted before it loads: a spread hosted after its load does not turn ready, and one that
        // turns ready goes to its opening location, which would move the offset under the test.
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }
        try await waitForReady(spreadView)

        let setup = """
        const root = document.scrollingElement;
        const page = root.clientWidth;
        if (!(page > 0 && root.scrollWidth >= 4 * page)) {
          return { error: `not paginated: page ${page}, scrollWidth ${root.scrollWidth}` };
        }
        root.scrollLeft = 2 * page + offPage;
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const before = window.scrollX;
        \(zeroing)
        window.__snapProbe = null;
        let resized = false;
        const observer = new ResizeObserver(() => {
          // The observation's first callback reports the size the body already has.
          if (!resized) {
            return;
          }
          observer.disconnect();
          requestAnimationFrame(() => {
            window.__snapProbe = { page, before, after: window.scrollX };
          });
        });
        observer.observe(document.body);
        resized = true;
        document.body.append(document.createElement("p"), "A paragraph that grows the body.");
        return { ok: true };
        """
        let started = try await spreadView.webView.callAsyncJavaScript(
            setup,
            arguments: ["offPage": Self.offPage],
            in: nil,
            contentWorld: .page
        ) as? [String: Any]
        if let error = started?["error"] as? String {
            XCTFail("Fixture: \(error)")
            throw EPUBSpreadViewHosting.Timeout()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            let probe = try await spreadView.webView.callAsyncJavaScript(
                "return window.__snapProbe;",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? [String: Any]
            if let probe {
                return try Snap(
                    page: XCTUnwrap(probe["page"] as? Double),
                    before: XCTUnwrap(probe["before"] as? Double),
                    after: XCTUnwrap(probe["after"] as? Double)
                )
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("The body resize never reached a frame")
        throw EPUBSpreadViewHosting.Timeout()
    }

    /// Setup, so only the #1693 signature skips: a load WebKit still reports in progress.
    private func waitForReady(_ spreadView: EPUBSpreadView) async throws {
        do {
            try await EPUBSpreadViewHosting.waitUntil(reportingFailure: false) {
                if case .ready = spreadView.readiness.state {
                    return true
                }
                return false
            }
        } catch {
            let diagnosis = "state=\(spreadView.readiness.state), isLoading=\(spreadView.webView.isLoading)"
            guard case .loading = spreadView.readiness.state, spreadView.webView.isLoading else {
                XCTFail("The spread did not turn ready: \(diagnosis)")
                throw error
            }
            throw XCTSkip("WebContent process is not making progress (see #1693). \(diagnosis)")
        }
    }
}
