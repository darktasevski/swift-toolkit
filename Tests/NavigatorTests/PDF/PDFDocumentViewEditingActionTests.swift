//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import PDFKit
@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class PDFDocumentViewEditingActionTests: XCTestCase {
    func testCopyRoutesSelectedTextThroughEditingActions() async throws {
        let copied = expectation(description: "selected text copied")
        var copiedText: String?
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Test"), links: [], readingOrder: [])
        )
        let editingActions = EditingActionsController(
            actions: [.copy],
            publication: publication,
            copySelection: { text in
                copiedText = text
                copied.fulfill()
            }
        )
        editingActions.selection = try Selection(
            locator: Locator(
                href: XCTUnwrap(RelativeURL(string: "document.pdf")),
                mediaType: .pdf,
                text: Locator.Text(highlight: "Selected text")
            ),
            frame: .zero
        )
        let documentView = PDFDocumentView(
            frame: .zero,
            editingActions: editingActions,
            documentViewDelegate: NoOpPDFDocumentViewDelegate()
        )

        documentView.copy(nil)

        await fulfillment(of: [copied], timeout: 1)
        XCTAssertEqual(copiedText, "Selected text")
    }
}

@MainActor
private final class NoOpPDFDocumentViewDelegate: PDFDocumentViewDelegate {
    func pdfDocumentViewContentInset(_ pdfDocumentView: PDFDocumentView) -> UIEdgeInsets? {
        nil
    }

    func pdfDocumentView(_ pdfDocumentView: PDFDocumentView, shouldGoTo destination: PDFDestination) -> Bool {
        true
    }

    func pdfDocumentView(_ pdfDocumentView: PDFDocumentView, didGoTo destination: PDFDestination) {}
}
