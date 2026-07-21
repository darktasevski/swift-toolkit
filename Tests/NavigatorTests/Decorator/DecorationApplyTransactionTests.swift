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
    @MainActor
    func testSupersededApplyRestoresAttemptedResourcesBeforeSuccessorStarts() async {
        let group: DecorationGroup = "epub-highlights"
        let resources = ["chapter-1", "chapter-2"]
        let firstMutationReached = AsyncGate()
        let releaseFirstMutation = AsyncGate()
        let queue = DecorationApplyTaskQueue()
        var committedValue = "A"
        var renderedValues = Dictionary(uniqueKeysWithValues: resources.map { ($0, committedValue) })
        var events: [String] = []

        queue.submit(in: group) { _ in
            let transaction = DecorationApplyResourceTransaction(resources: resources)
            let didCommit = await transaction.run(
                apply: { resource in
                    renderedValues[resource] = "B"
                    events.append("apply:\(resource)")
                    if resource == resources[0] {
                        await firstMutationReached.open()
                        await releaseFirstMutation.wait()
                    }
                    return true
                },
                rollback: { resource in
                    XCTAssertFalse(Task.isCancelled, "Rollback must not inherit predecessor cancellation")
                    renderedValues[resource] = committedValue
                    events.append("rollback:\(resource)")
                    return true
                }
            )
            if didCommit {
                committedValue = "B"
            }
        }

        await firstMutationReached.wait()
        queue.submit(in: group) { isSuperseding in
            XCTAssertTrue(isSuperseding)
            events.append("successor")
            for resource in resources {
                renderedValues[resource] = committedValue
            }
        }
        await releaseFirstMutation.open()
        await queue.waitForIdle(in: group)

        XCTAssertEqual(committedValue, "A")
        XCTAssertEqual(renderedValues, ["chapter-1": "A", "chapter-2": "A"])
        XCTAssertEqual(events, ["apply:chapter-1", "rollback:chapter-1", "successor"])
    }

    func testCancelledTransactionDoesNotHidePendingDecorationChangesFromRetry() throws {
        let group: DecorationGroup = "epub-highlights"
        let target = try [
            DiffableDecoration(decoration: makeDecoration(id: "annotation-1")),
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

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
