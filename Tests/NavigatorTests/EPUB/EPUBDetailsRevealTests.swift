//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// A closed disclosure's content is not laid out across pages: measured, a target several pages
/// into one overflows the foot of an earlier page. Every navigation to an element opens the
/// closed disclosures around it before it measures, so it lands on the page holding the target.
@MainActor
final class EPUBDetailsRevealTests: XCTestCase {
    /// Paginated by its own columns, as `EPUBSpreadViewPageSnapTests` is. The target sits pages
    /// into a closed disclosure, as a heading the converter lists does in a disclosure holding a
    /// chapter, with text around it on both sides.
    private static let chapter: String = {
        let text = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40)
        let outside = String(repeating: "<p>\(text)</p>", count: 3)
        let inside = String(repeating: "<p>\(text)</p>", count: 6)
        return """
        <!doctype html>
        <html><head><style>
        :root {
          margin: 0 !important; padding: 0 !important; height: 100vh !important;
          column-width: 100vw !important; column-gap: 0 !important; column-fill: auto !important;
        }
        body { margin: 0 !important; padding: 0 !important; }
        </style></head><body>
        \(outside)
        <details><summary>Notes</summary>\(inside)<p id="inner">\(text)</p>\(inside)</details>
        \(outside)
        </body></html>
        """
    }()

    func testAJumpToAnIdOpensItsDisclosureAndLandsOnIt() async throws {
        let spreadView = try await hostedSpread()

        let scrolled = try await spreadView.webView.callAsyncJavaScript(
            #"return readium.scrollToId("inner", false);"#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        XCTAssertEqual(scrolled as? Bool, true, "The jump reported no move")
        try await assertLandedOnTheTarget(in: spreadView)
    }

    func testAJumpToALocatorInThePageOpensItsDisclosureAndLandsOnIt() async throws {
        let spreadView = try await hostedSpread()

        let scrolled = try await spreadView.webView.callAsyncJavaScript(
            #"return readium.scrollToLocator({ href: "chapter.html", locations: { fragments: ["inner"] } }, false);"#,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )

        XCTAssertEqual(scrolled as? Bool, true, "The jump reported no move")
        try await assertLandedOnTheTarget(in: spreadView)
    }

    /// The navigator's own path to an anchored location, a table of contents entry's. The command
    /// checks where it landed and scrolls again when the target is not showing (`landAndVerify`),
    /// so a measure before the disclosure opens still ends on the target, but spends one of its
    /// two corrections, and a correction never animates: what shows the order is the disclosure's
    /// state at each of its measures.
    func testANavigationToAFragmentOpensItsDisclosureBeforeItMeasuresAndLandsOnIt() async throws {
        let spreadView = try await hostedSpread()
        _ = try await spreadView.webView.callAsyncJavaScript(
            """
            globalThis.__measuredOpen = [];
            const measure = Range.prototype.getBoundingClientRect;
            Range.prototype.getBoundingClientRect = function () {
              globalThis.__measuredOpen.push(document.querySelector("details").open);
              return measure.call(this);
            };
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        let locator = Locator(
            href: RelativeURL(path: EPUBSpreadViewHosting.chapterHREF)!.anyURL,
            mediaType: .html,
            locations: Locator.Locations(fragments: ["inner"])
        )

        let outcome = await spreadView.go(to: .locator(locator), animated: false)

        XCTAssertEqual(outcome, .succeeded)
        try await assertLandedOnTheTarget(in: spreadView)
        let measured = try await spreadView.webView.callAsyncJavaScript(
            "return globalThis.__measuredOpen;",
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? [Bool]
        let opened = try XCTUnwrap(measured, "The command's measures were not read")
        XCTAssertFalse(opened.isEmpty, "Fixture: the command measured no range")
        XCTAssertFalse(opened.contains(false), "The command measured the target before opening its disclosure: \(opened)")
    }

    /// Hosted before it loads: a spread that turns ready goes to its opening location, which
    /// would move the offset under the test.
    private func hostedSpread() async throws -> EPUBReflowableSpreadView {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: Self.chapter)
        let window = EPUBSpreadViewHosting.host(spreadView)
        addTeardownBlock { @MainActor in
            spreadView.removeFromSuperview()
            window.isHidden = true
        }
        try await EPUBSpreadViewHosting.waitForReady(in: spreadView)

        let fixture = try await spreadView.webView.callAsyncJavaScript(
            """
            const root = document.scrollingElement;
            return {
              paginated: root.clientWidth > 0 && root.scrollWidth >= 3 * root.clientWidth,
              closed: !document.querySelector("details").open,
              atStart: window.scrollX === 0,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any]
        XCTAssertEqual(fixture?["paginated"] as? Bool, true, "Fixture: not paginated: \(String(describing: fixture))")
        XCTAssertEqual(fixture?["closed"] as? Bool, true, "Fixture: the disclosure starts open")
        XCTAssertEqual(fixture?["atStart"] as? Bool, true, "Fixture: the spread did not open at its start")
        return spreadView
    }

    /// Two frames after the navigation returns, the disclosure is open, and the target starts on
    /// the showing page. Its page, wherever the navigation landed, is not the first.
    private func assertLandedOnTheTarget(
        in spreadView: EPUBSpreadView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let landing = try await spreadView.webView.callAsyncJavaScript(
            """
            await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return {
              open: document.querySelector("details").open,
              page: document.scrollingElement.clientWidth,
              left: document.getElementById("inner").getBoundingClientRect().left,
              scrollX: window.scrollX,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any]
        let probe = try XCTUnwrap(landing, "No landing was read", file: file, line: line)
        XCTAssertEqual(probe["open"] as? Bool, true, "The navigation left the disclosure closed", file: file, line: line)
        let page = try XCTUnwrap(probe["page"] as? Double, "\(probe)", file: file, line: line)
        let left = try XCTUnwrap(probe["left"] as? Double, "\(probe)", file: file, line: line)
        let scrollX = try XCTUnwrap(probe["scrollX"] as? Double, "\(probe)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(left + scrollX, page, "Fixture: the target is on the first page", file: file, line: line)
        XCTAssertTrue(
            left >= 0 && left < page,
            "The navigation measured the target before opening its disclosure: \(probe)",
            file: file,
            line: line
        )
    }
}
