//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// A paginated resource measures its page as the scrollport's width when it uses it. The visual
/// viewport (`window.innerWidth`, `visualViewport.width`) reads 0 for a moment after a resource
/// transition while the layout is already sized, and a page width of 0 snapped every offset to
/// `NaN`, which WebKit writes to `scrollLeft` as 0 (#1677).
@MainActor
final class EPUBSpreadViewPageSnapTests: XCTestCase {
    /// Paginated by its own columns, so the test does not depend on how ReadiumCSS lays out a page.
    private static let chapter: String = {
        let text = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40)
        let paragraphs = (0 ..< 30).map { index in
            index == 20 ? "<p id=\"later\">\(text)</p>" : "<p>\(text)</p>"
        }
        return """
        <!doctype html>
        <html><head><style>
        :root {
          margin: 0 !important; padding: 0 !important; height: 100vh !important;
          column-width: 100vw !important; column-gap: 0 !important; column-fill: auto !important;
        }
        body { margin: 0 !important; padding: 0 !important; }
        </style></head><body>
        \(paragraphs.joined())
        </body></html>
        """
    }()

    /// Off a page boundary, so a snap that ran is visible as a move to the page start.
    private static let offPage = 37.0

    private static let zeroVisualViewport = """
    Object.defineProperty(window, "innerWidth", { configurable: true, get: () => 0 });
    Object.defineProperty(window.visualViewport, "width", { configurable: true, get: () => 0 });
    """

    /// Also zeroes the scrollport, counting the reads that see it in `window.__widthReads`.
    private static let zeroEveryWidth = zeroVisualViewport + """
    window.__widthReads = 0;
    Object.defineProperty(document.scrollingElement, "clientWidth", {
      configurable: true,
      get: () => { window.__widthReads += 1; return 0; },
    });
    """

    /// Shared by every script: `frames(n)` waits n frames, and `afterResize(record)` stores what
    /// `record` returns as the probe, in a frame after the page's own handling of the next body
    /// resize. The page registered its observer at `load`, before this one, and its frame
    /// callback was requested first, so it has run by then.
    private static let prelude = """
    const root = document.scrollingElement;
    const page = root.clientWidth;
    if (!(page > 0 && root.scrollWidth >= 4 * page)) {
      return { error: `not paginated: page ${page}, scrollWidth ${root.scrollWidth}` };
    }
    const frames = (count) => new Promise((resolve) => {
      const step = (left) => (left === 0 ? resolve() : requestAnimationFrame(() => step(left - 1)));
      step(count);
    });
    const afterResize = (record) => {
      const observer = new ResizeObserver(() => {
        observer.disconnect();
        requestAnimationFrame(() => { window.__snapProbe = record(); });
      });
      observer.observe(document.body);
    };
    window.__snapProbe = null;
    root.scrollLeft = 2 * page + offPage;
    await frames(2);
    const before = window.scrollX;

    """

    private static let growBody = #"document.body.append(document.createElement("p"), "A paragraph that grows the body.");"#

    func testAResizeWhileTheVisualViewportReadsZeroSnapsToThePageStart() async throws {
        let probe = try await runInHostedSpread("""
        \(Self.zeroVisualViewport)
        afterResize(() => ({ page, before, after: window.scrollX }));
        \(Self.growBody)
        """)

        let page = try number(probe, "page")
        XCTAssertEqual(try number(probe, "before"), 2 * page + Self.offPage, "The setup scroll did not hold")
        XCTAssertEqual(try number(probe, "after"), 2 * page, "The snap measured the visual viewport instead of the scrollport")
    }

    func testAResizeWithNoMeasurablePageLeavesTheOffsetAlone() async throws {
        let probe = try await runInHostedSpread("""
        \(Self.zeroEveryWidth)
        afterResize(() => ({ page, before, after: window.scrollX, reads: window.__widthReads }));
        \(Self.growBody)
        """)

        let before = try number(probe, "before")
        XCTAssertEqual(before, try 2 * number(probe, "page") + Self.offPage, "The setup scroll did not hold")
        XCTAssertGreaterThan(try number(probe, "reads"), 0, "The page's resize handling never measured the page")
        XCTAssertEqual(try number(probe, "after"), before, "A snap with no page width moved the offset")
    }

    func testAJumpWithNoMeasurablePageLeavesTheOffsetAlone() async throws {
        let probe = try await runInHostedSpread("""
        \(Self.zeroEveryWidth)
        readium.scrollToPosition(0.5, "ltr", false);
        const positionReads = window.__widthReads;
        const scrolledToId = readium.scrollToId("later", false);
        await frames(2);
        window.__snapProbe = { page, before, after: window.scrollX, positionReads, scrolledToId };
        """)

        XCTAssertEqual(try number(probe, "before"), try 2 * number(probe, "page") + Self.offPage, "The setup scroll did not hold")
        XCTAssertGreaterThan(try number(probe, "positionReads"), 0, "The progression jump never measured the page")
        XCTAssertEqual(probe["scrolledToId"] as? Bool, false, "A jump to an element with no page width reported success")
        XCTAssertEqual(try number(probe, "after"), try number(probe, "before"), "A jump with no page width moved the offset")
    }

    /// Two columns per screen with an odd column count is what the page's virtual column exists
    /// to even out; a resize while the visual viewport reads 0 must still do it.
    func testAResizeWhileTheVisualViewportReadsZeroEvensOutTwoColumns() async throws {
        let probe = try await runInHostedSpread("""
        const isOdd = () => (Math.round((root.scrollWidth / root.clientWidth) * 2) / 2) % 1 > 0.1;
        document.documentElement.style.setProperty("column-width", "auto", "important");
        document.documentElement.style.setProperty("column-count", "2", "important");
        await frames(4);
        const columns = getComputedStyle(document.documentElement).columnCount;
        if (columns !== "2" || isOdd()) {
          return { error: `two columns did not settle even: column-count ${columns}, odd ${isOdd()}` };
        }
        \(Self.zeroVisualViewport)
        let oddBefore;
        afterResize(() => ({ oddBefore, oddAfter: isOdd() }));
        const column = document.createElement("div");
        column.style.breakBefore = "column";
        column.textContent = "A column.";
        document.body.append(column);
        oddBefore = isOdd();
        """)

        XCTAssertEqual(probe["oddBefore"] as? Bool, true, "Setup: the added column did not make the count odd")
        XCTAssertEqual(probe["oddAfter"] as? Bool, false, "The resize left two columns per screen with an odd column count")
    }

    /// Hosts the chapter, waits for it to turn ready, and runs `script` after `prelude` in the
    /// page; the script's probe is `window.__snapProbe`, which this polls for.
    private func runInHostedSpread(_ script: String) async throws -> [String: Any] {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        // Hosted before it loads: a spread that turns ready goes to its opening location, which
        // would move the offset under the script.
        let window = EPUBSpreadViewHosting.host(spreadView)
        defer {
            spreadView.removeFromSuperview()
            window.isHidden = true
        }
        try await EPUBSpreadViewHosting.waitForReady(in: spreadView)

        let started = try await spreadView.webView.callAsyncJavaScript(
            Self.prelude + script + "\nreturn { ok: true };",
            arguments: ["offPage": Self.offPage],
            in: nil,
            contentWorld: .page
        )
        let start = started as? [String: Any]
        guard start?["ok"] as? Bool == true else {
            XCTFail("Fixture: \(start?["error"] as? String ?? String(describing: started))")
            throw EPUBSpreadViewHosting.Timeout()
        }

        // A liveness backstop like `EPUBSpreadViewHosting.waitUntil`'s, not a performance bound.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let probe = try await spreadView.webView.callAsyncJavaScript(
                "return window.__snapProbe;",
                arguments: [:],
                in: nil,
                contentWorld: .page
            ) as? [String: Any]
            if let probe {
                return probe
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("The script's probe never arrived")
        throw EPUBSpreadViewHosting.Timeout()
    }

    private func number(_ probe: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(probe[key] as? Double, "Probe has no number \(key): \(probe)")
    }
}
