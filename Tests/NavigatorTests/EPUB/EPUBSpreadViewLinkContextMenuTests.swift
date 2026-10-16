//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import WebKit
import XCTest

/// A long-press on a link that leaves the publication offers one item on the tap path and never a
/// preview; a link inside the publication offers nothing.
@MainActor
final class EPUBSpreadViewLinkContextMenuTests: XCTestCase {
    /// Built the way `WebViewServer.serve(at:handler:)` builds a publication base.
    private let base = AnyURL(string: "readium://publication/")!.absoluteURL!

    func testALinkInsideThePublicationHasNoMenu() throws {
        let url = try XCTUnwrap(URL(string: "readium://publication/chapter2.xhtml#note1"))
        XCTAssertNil(EPUBSpreadView.outboundLinkURL(for: url, publicationBaseURL: base))
    }

    func testALinkLeavingThePublicationOpensThroughTheTapPath() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        XCTAssertEqual(EPUBSpreadView.outboundLinkURL(for: url, publicationBaseURL: base), url)
    }

    /// The app refuses a `mailto:` on the tap path and says so; the menu does not pre-judge it.
    func testAMailtoLinkAlsoTakesTheTapPath() throws {
        let url = try XCTUnwrap(URL(string: "mailto:someone@example.com"))
        XCTAssertEqual(EPUBSpreadView.outboundLinkURL(for: url, publicationBaseURL: base), url)
    }

    func testAnElementWithoutALinkHasNoMenu() {
        XCTAssertNil(EPUBSpreadView.outboundLinkURL(for: nil, publicationBaseURL: base))
    }

    /// Before the publication base exists, a link is treated as leaving, so the app's confirmation
    /// sees it rather than WebKit's menu.
    func testWithNoPublicationBaseALinkIsTreatedAsLeaving() throws {
        let url = try XCTUnwrap(URL(string: "readium://publication/chapter2.xhtml"))
        XCTAssertEqual(EPUBSpreadView.outboundLinkURL(for: url, publicationBaseURL: nil), url)
    }

    func testTheOutboundMenuHasExactlyTheOneSuppliedItem() {
        let menu = EPUBSpreadView.outboundLinkMenu(title: "Open Link…") {}
        XCTAssertEqual(menu.children.count, 1)
        XCTAssertEqual((menu.children.first as? UIAction)?.title, "Open Link…")
    }

    /// WebKit asks `respondsToSelector:` before it consults the delegate. A hook whose signature
    /// drifted off the protocol requirement (or that was deleted) would compile, never run, and
    /// leave WebKit's own menu in place.
    func testTheSpreadViewAnswersWebKitsContextMenuSelector() {
        XCTAssertTrue(makeSpreadView().responds(
            to: #selector(WKUIDelegate.webView(_:contextMenuConfigurationForElement:completionHandler:))
        ))
    }

    /// A `nil` here would hand an `http(s)` link back to WebKit's own menu and its preview.
    func testTheHookOffersAConfigurationForAnOutboundLink() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        XCTAssertNotNil(makeSpreadView().linkContextMenuConfiguration(forLinkURL: url))
    }

    func testTheHookOffersNoConfigurationForAnInternalLink() throws {
        let spreadView = makeSpreadView()
        let base = try XCTUnwrap(spreadView.viewModel.publicationBaseURL)
        XCTAssertNil(spreadView.linkContextMenuConfiguration(forLinkURL: base.url.appendingPathComponent("chapter.html")))
    }

    func testTheHookOffersNoConfigurationWithoutALink() {
        XCTAssertNil(makeSpreadView().linkContextMenuConfiguration(forLinkURL: nil))
    }

    /// The default an app sees when it does not override the key in its main bundle.
    func testTheMenuTitleDefaultsToTheNavigatorString() {
        XCTAssertEqual(EPUBSpreadView.outboundLinkMenuTitle, "Open Link…")
    }

    private func makeSpreadView() -> EPUBReflowableSpreadView {
        EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: "<!doctype html><html><body>Chapter</body></html>")
    }
}
