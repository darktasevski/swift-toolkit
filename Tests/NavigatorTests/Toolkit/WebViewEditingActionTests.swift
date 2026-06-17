//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

@MainActor
final class WebViewEditingActionTests: XCTestCase {
    func testCustomEditingActionCanPerformWithoutSuperclassSupport() throws {
        let selector = #selector(HighlightResponderView.highlightSelection)
        let editingActions = try makeEditingActions(customSelector: selector)
        let webView = WebView(editingActions: editingActions)

        XCTAssertTrue(
            webView.canPerformAction(selector, withSender: nil),
            "Custom EPUB editing actions must be authorized by EditingActionsController even when WKWebView's superclass does not implement the selector."
        )
    }

    func testCustomEditingActionTargetsResponderChain() throws {
        let selector = #selector(HighlightResponderView.highlightSelection)
        let editingActions = try makeEditingActions(customSelector: selector)
        let webView = WebView(editingActions: editingActions)
        let responderView = HighlightResponderView()
        responderView.addSubview(webView)

        let target = webView.target(forAction: selector, withSender: nil)

        XCTAssertTrue(
            target as AnyObject === responderView,
            "Custom EPUB editing actions must be routed to the responder that implements the selector."
        )
    }

    private func makeEditingActions(customSelector selector: Selector) throws -> EditingActionsController {
        let href = try XCTUnwrap(RelativeURL(string: "chapter.xhtml"))
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test"),
                readingOrder: []
            )
        )
        let editingActions = EditingActionsController(
            actions: [EditingAction(title: "Highlight", action: selector)],
            publication: publication
        )
        editingActions.selection = Selection(
            locator: Locator(
                href: href,
                mediaType: .xhtml,
                text: Locator.Text(highlight: "Selected text")
            ),
            frame: .zero
        )
        return editingActions
    }
}

private final class HighlightResponderView: UIView {
    @objc func highlightSelection() {}
}
