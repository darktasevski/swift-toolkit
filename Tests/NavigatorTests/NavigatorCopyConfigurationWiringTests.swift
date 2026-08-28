//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import XCTest

final class NavigatorCopyConfigurationWiringTests: XCTestCase {
    func testEPUBConfigurationForwardsCopySelectionToEditingActions() throws {
        let source = try navigatorSource("EPUB/EPUBNavigatorViewModel.swift")
        let initializer = try editingActionsInitializer(in: source)

        XCTAssertTrue(
            initializer.contains("copySelection: config.copySelection"),
            "EPUB must forward the configured copy destination to EditingActionsController"
        )
    }

    func testPDFConfigurationForwardsCopySelectionToEditingActions() throws {
        let source = try navigatorSource("PDF/PDFNavigatorViewController.swift")
        let initializer = try editingActionsInitializer(in: source)

        XCTAssertTrue(
            initializer.contains("copySelection: config.copySelection"),
            "PDF must forward the configured copy destination to EditingActionsController"
        )
    }

    private func navigatorSource(_ relativePath: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/Navigator/\(relativePath)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func editingActionsInitializer(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "editingActions = EditingActionsController("))
        let suffix = source[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "\n        )"))
        return suffix[..<end.upperBound]
    }
}
