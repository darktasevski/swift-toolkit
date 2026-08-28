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

    func testNativeEditingActionsRequireSuperclassSupport() throws {
        let editingActions = try makeEditingActions(actions: [
            .lookup,
            .translate,
        ])
        let webView = WebView(editingActions: editingActions)

        for selector in [Selector(("_lookup:")), Selector(("translate:"))] {
            XCTAssertFalse(
                webView.canPerformAction(selector, withSender: nil),
                "Native EPUB editing action \(selector) must not be authorized solely by EditingActionsController when WKWebView's superclass cannot perform it."
            )
        }
    }

    func testCopyRoutesSelectedTextThroughEditingActions() async throws {
        let copied = expectation(description: "selected text copied")
        var copiedText: String?
        let editingActions = try makeEditingActions(
            actions: [.copy],
            copySelection: { text in
                copiedText = text
                copied.fulfill()
            }
        )
        let webView = WebView(editingActions: editingActions)

        webView.copy(nil)

        await fulfillment(of: [copied], timeout: 1)
        XCTAssertEqual(copiedText, "Selected text")
    }

    private func makeEditingActions(customSelector selector: Selector) throws -> EditingActionsController {
        try makeEditingActions(actions: [
            EditingAction(title: "Highlight", action: selector),
        ])
    }

    private func makeEditingActions(
        actions: [EditingAction],
        copySelection: (@MainActor @Sendable (String) -> Void)? = nil
    ) throws -> EditingActionsController {
        let href = try XCTUnwrap(RelativeURL(string: "chapter.xhtml"))
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Test"),
                readingOrder: []
            )
        )
        let editingActions = EditingActionsController(
            actions: actions,
            publication: publication,
            copySelection: copySelection
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
