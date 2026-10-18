//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import PDFKit
@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// Hosts treat `shouldGoTo` as a user link activation (it reaches
/// `navigator(_:shouldNavigateToLink:)`), so the navigator's own page moves must never consult it.
@MainActor
final class PDFDocumentViewProgrammaticNavigationTests: XCTestCase {
    func testProgrammaticPageMovesDoNotConsultLinkActivation() throws {
        let document = PDFDocument()
        for index in 0 ..< 5 {
            document.insert(PDFPage(), at: index)
        }
        let delegate = CountingPDFDocumentViewDelegate()
        let documentView = PDFDocumentView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            editingActions: EditingActionsController(
                actions: [],
                publication: Publication(manifest: Manifest(metadata: Metadata(title: "Test"), readingOrder: []))
            ),
            documentViewDelegate: delegate
        )
        documentView.document = document
        documentView.layoutIfNeeded()

        let target = try XCTUnwrap(document.page(at: 3))
        let moves: [(String, () -> Void)] = [
            ("go(to: page)", { documentView.go(to: target) }),
            ("go(to: rect, on:)", { documentView.go(to: target.bounds(for: documentView.displayBox), on: target) }),
            ("goToNextPage", { documentView.goToNextPage(nil) }),
            ("goToPreviousPage", { documentView.goToPreviousPage(nil) }),
            ("goToFirstPage", { documentView.goToFirstPage(nil) }),
            ("goToLastPage", { documentView.goToLastPage(nil) }),
        ]
        for (name, move) in moves {
            let before = delegate.shouldGoToCount
            move()
            XCTAssertEqual(delegate.shouldGoToCount, before, "\(name) consulted link activation")
        }

        XCTAssertEqual(documentView.currentPage, document.page(at: 4), "premise: the moves ran")
    }

    func testDestinationNavigationConsultsLinkActivation() throws {
        let document = PDFDocument()
        for index in 0 ..< 3 {
            document.insert(PDFPage(), at: index)
        }
        let delegate = CountingPDFDocumentViewDelegate()
        let documentView = PDFDocumentView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            editingActions: EditingActionsController(
                actions: [],
                publication: Publication(manifest: Manifest(metadata: Metadata(title: "Test"), readingOrder: []))
            ),
            documentViewDelegate: delegate
        )
        documentView.document = document

        let target = try XCTUnwrap(document.page(at: 2))
        documentView.go(to: PDFDestination(page: target, at: .zero))

        XCTAssertEqual(delegate.shouldGoToCount, 1, "positive control: a destination jump is a link activation")
    }
}

@MainActor
private final class CountingPDFDocumentViewDelegate: PDFDocumentViewDelegate {
    var shouldGoToCount = 0

    func pdfDocumentViewContentInset(_ pdfDocumentView: PDFDocumentView) -> UIEdgeInsets? {
        nil
    }

    func pdfDocumentView(_ pdfDocumentView: PDFDocumentView, shouldGoTo destination: PDFDestination) -> Bool {
        shouldGoToCount += 1
        return true
    }

    func pdfDocumentView(_ pdfDocumentView: PDFDocumentView, didGoTo destination: PDFDestination) {}
}
