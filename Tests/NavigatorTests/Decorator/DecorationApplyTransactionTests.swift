//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

final class DecorationApplyTransactionTests: XCTestCase {
    func testCancelledTransactionDoesNotHidePendingDecorationChangesFromRetry() throws {
        let group: DecorationGroup = "epub-highlights"
        let target = [
            DiffableDecoration(decoration: try makeDecoration(id: "annotation-1")),
        ]
        var committedSnapshots: [DecorationGroup: [DiffableDecoration]] = [:]

        let cancelled = DecorationApplyTransaction(
            group: group,
            source: committedSnapshots[group] ?? [],
            target: target
        )

        assertSingleAdd(in: cancelled, id: "annotation-1")
        XCTAssertNil(committedSnapshots[group])

        let retry = DecorationApplyTransaction(
            group: group,
            source: committedSnapshots[group] ?? [],
            target: target
        )

        assertSingleAdd(in: retry, id: "annotation-1")
        retry.commit(to: &committedSnapshots)
        XCTAssertEqual(committedSnapshots[group], target)

        let redundant = DecorationApplyTransaction(
            group: group,
            source: committedSnapshots[group] ?? [],
            target: target
        )
        XCTAssertTrue(redundant.changesByHREF.isEmpty)
    }

    private func makeDecoration(id: Decoration.Id) throws -> Decoration {
        let href = try XCTUnwrap(AnyURL(string: "chapter.xhtml"))
        return Decoration(
            id: id,
            locator: Locator(
                href: href,
                mediaType: .xhtml,
                text: Locator.Text(highlight: "Selected text")
            ),
            style: .highlight(tint: .yellow)
        )
    }

    private func assertSingleAdd(
        in transaction: DecorationApplyTransaction,
        id: Decoration.Id,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let changes = Array(transaction.changesByHREF.values.joined())
        XCTAssertEqual(changes.count, 1, file: file, line: line)
        guard let change = changes.first else { return }
        guard case let .add(decoration) = change else {
            XCTFail("Expected add change, got \(change)", file: file, line: line)
            return
        }
        XCTAssertEqual(decoration.id, id, file: file, line: line)
    }
}
