//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class PaginationViewCurrentPageTests: XCTestCase {
    func testCurrentPageIdentityResolvesBeforeItsGoAndNeighborPreloading() async throws {
        let current = TestPageView(blocksGo: true)
        let previous = TestPageView()
        let next = TestPageView()
        let delegate = TestPaginationDelegate(pages: [
            0: previous,
            1: current,
            2: next,
        ])
        let pagination = makePaginationView()
        pagination.delegate = delegate

        pagination.reloadAtIndex(1, location: .start, pageCount: 3, readingProgression: .ltr)

        let installed = await pagination.waitForCurrentPage(at: 1)
        XCTAssertTrue(installed === current)
        XCTAssertTrue(current.goStarted)
        XCTAssertEqual(delegate.requestedIndices, [1])
        XCTAssertNil(pagination.loadedViews[0])
        XCTAssertNil(pagination.loadedViews[2])

        current.finishGo()
    }

    func testReplacementLoaderWaitsForCancelledPredecessorAcknowledgement() async {
        let first = TestPageView(blocksGo: true)
        let second = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: first, 1: second])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        _ = await pagination.waitForCurrentPage(at: 0)
        XCTAssertTrue(first.goStarted)

        pagination.reloadAtIndex(1, location: .start, pageCount: 2, readingProgression: .ltr)
        await Task.yield()

        XCTAssertTrue(first.cancellationObserved)
        XCTAssertEqual(delegate.requestedIndices, [0])

        first.finishGo()
        let installed = await pagination.waitForCurrentPage(at: 1)

        XCTAssertTrue(installed === second)
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
        second.finishGo()
    }

    func testDelegateResultFromSupersededGenerationIsRejected() async {
        let stale = TestPageView()
        let current = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: stale, 1: current])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        delegate.onCreate = { pagination, index in
            guard index == 0 else { return }
            delegate.onCreate = nil
            pagination.reloadAtIndex(
                1,
                location: .start,
                pageCount: 2,
                readingProgression: .ltr
            )
        }

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await waitUntil { pagination.currentIndex == 1 }
        let installed = await pagination.waitForCurrentPage(at: 1)

        XCTAssertTrue(installed === current)
        XCTAssertNil(pagination.loadedViews[0])
        XCTAssertNil(stale.superview)
        current.finishGo()
    }

    func testReloadDrainsStaleCurrentPageWaiter() async {
        let pagination = makePaginationView(preloadPositionCount: 0)
        let delegate = TestPaginationDelegate(pages: [:])
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        let waiter = Task { @MainActor in
            await pagination.waitForCurrentPage(at: 0)
        }
        await Task.yield()

        pagination.reloadAtIndex(1, location: .start, pageCount: 2, readingProgression: .ltr)

        let outcome = await waiter.value
        XCTAssertNil(outcome)
    }

    func testRemovalDrainsCurrentPageWaiterAndRemovesLoadedViews() async {
        let blocking = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: blocking])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        let container = UIView()
        container.addSubview(pagination)
        pagination.reloadAtIndex(0, location: .start, pageCount: 1, readingProgression: .ltr)
        _ = await pagination.waitForCurrentPage(at: 0)
        pagination.removeFromSuperview()

        XCTAssertTrue(pagination.loadedViews.isEmpty)
        XCTAssertNil(blocking.superview)
        blocking.finishGo()

        let missingPagination = makePaginationView(preloadPositionCount: 0)
        let missingDelegate = TestPaginationDelegate(pages: [:])
        missingPagination.delegate = missingDelegate
        container.addSubview(missingPagination)
        missingPagination.reloadAtIndex(
            0,
            location: .start,
            pageCount: 1,
            readingProgression: .ltr
        )
        let waiter = Task { @MainActor in
            await missingPagination.waitForCurrentPage(at: 0)
        }
        await Task.yield()
        missingPagination.removeFromSuperview()

        let outcome = await waiter.value
        XCTAssertNil(outcome)
    }

    func testCrossResourceGoWaitsForTargetCommandButNotNeighborPreloading() async {
        let initial = TestPageView()
        let target = TestPageView(blocksGo: true)
        let neighbor = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: initial])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)

        await waitUntil { initial.goCallCount == 1 }
        await waitUntil { delegate.requestedIndices.contains(1) }
        delegate.pages[1] = target
        delegate.pages[2] = neighbor

        var result: Bool?
        let navigation = Task { @MainActor in
            let success = await pagination.goToIndex(
                1,
                location: .start,
                options: NavigatorGoOptions(animated: false)
            )
            result = success
            return success
        }

        await waitUntil { target.goCallCount == 1 }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertNil(result)

        target.finishGo()
        await waitUntil { neighbor.goCallCount == 1 }
        await waitUntil { result != nil }

        XCTAssertEqual(result, true)
        neighbor.finishGo()
        let success = await navigation.value
        XCTAssertTrue(success)
    }

    func testSameIndexGoCancelsAndAcknowledgesInitialCommandBeforeReplacingIt() async {
        let page = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: page])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 1, readingProgression: .ltr)
        await waitUntil { page.goCallCount == 1 }

        var result: Bool?
        let replacement = Task { @MainActor in
            let success = await pagination.goToIndex(
                0,
                location: .end,
                options: NavigatorGoOptions(animated: false)
            )
            result = success
            return success
        }
        await waitUntil { page.cancellationObserved }

        XCTAssertTrue(page.cancellationObserved)
        XCTAssertEqual(page.goCallCount, 1)
        XCTAssertEqual(page.maximumConcurrentGoCount, 1)
        XCTAssertNil(result)

        page.finishGo()
        await waitUntil { page.goCallCount == 2 }
        XCTAssertEqual(page.maximumConcurrentGoCount, 1)
        XCTAssertNil(result)

        page.finishGo()
        let success = await replacement.value
        XCTAssertTrue(success)
        XCTAssertEqual(result, true)
    }

    func testMissingPageFactoryIsTerminalForExactCurrentPageWaiter() async {
        let delegate = TestPaginationDelegate(pages: [:])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 1, readingProgression: .ltr)

        var waiterFinished = false
        var outcome: (UIView & PageView)?
        let waiter = Task { @MainActor in
            let page = await pagination.waitForCurrentPage(at: 0)
            waiterFinished = true
            outcome = page
            return page
        }
        await waitUntil { delegate.requestedIndices == [0] }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertTrue(waiterFinished)
        XCTAssertNil(outcome)
        waiter.cancel()
        _ = await waiter.value
    }

    private func makePaginationView(preloadPositionCount: Int = 1) -> PaginationView {
        PaginationView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            preloadPreviousPositionCount: preloadPositionCount,
            preloadNextPositionCount: preloadPositionCount,
            isScrollEnabled: true
        )
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        iterations: Int = 100
    ) async {
        for _ in 0 ..< iterations {
            if predicate() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

@MainActor
private final class TestPaginationDelegate: PaginationViewDelegate {
    var onCreate: ((PaginationView, Int) -> Void)?
    private(set) var requestedIndices: [Int] = []
    private(set) var updateCount = 0

    var pages: [Int: TestPageView]

    init(pages: [Int: TestPageView]) {
        self.pages = pages
    }

    func paginationView(
        _ paginationView: PaginationView,
        pageViewAtIndex index: Int
    ) -> (UIView & PageView)? {
        requestedIndices.append(index)
        onCreate?(paginationView, index)
        return pages[index]
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        updateCount += 1
    }

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        1
    }
}

@MainActor
private final class TestPageView: UIView, PageView {
    private let blocksGo: Bool
    private var goContinuations: [CheckedContinuation<Void, Never>] = []

    private(set) var goCallCount = 0
    private(set) var activeGoCount = 0
    private(set) var maximumConcurrentGoCount = 0
    private(set) var cancellationObserved = false

    var goStarted: Bool {
        goCallCount > 0
    }

    init(blocksGo: Bool = false) {
        self.blocksGo = blocksGo
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func go(to location: PageLocation, animated: Bool) async {
        goCallCount += 1
        activeGoCount += 1
        maximumConcurrentGoCount = max(maximumConcurrentGoCount, activeGoCount)
        defer { activeGoCount -= 1 }
        guard blocksGo else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                goContinuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationObserved = true
            }
        }
    }

    func finishGo() {
        guard !goContinuations.isEmpty else { return }
        goContinuations.removeFirst().resume()
    }
}
