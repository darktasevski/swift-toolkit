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
    func testCurrentPageIdentityResolvesBeforeItsGoAndNeighborPreloading() async {
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

        var result: PageCommandOutcome?
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

        XCTAssertEqual(result, .succeeded)
        neighbor.finishGo()
        let outcome = await navigation.value
        XCTAssertEqual(outcome, .succeeded)
    }

    func testSameIndexGoCancelsAndAcknowledgesInitialCommandBeforeReplacingIt() async {
        let page = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: page])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 1, readingProgression: .ltr)
        await waitUntil { page.goCallCount == 1 }

        var result: PageCommandOutcome?
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
        XCTAssertEqual(page.commandSupersessionAcknowledgementCount, 1)
        XCTAssertEqual(page.goCallCount, 1)
        XCTAssertEqual(page.maximumConcurrentGoCount, 1)
        XCTAssertNil(result)

        page.finishGo()
        await waitUntil { page.goCallCount == 2 }
        XCTAssertEqual(page.maximumConcurrentGoCount, 1)
        XCTAssertNil(result)

        page.finishGo()
        let outcome = await replacement.value
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertEqual(result, .succeeded)
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

    func testFailedPageCommandIsNotReportedAsSucceeded() async {
        let initial = TestPageView()
        let failed = TestPageView(commandOutcome: .failed)
        let delegate = TestPaginationDelegate(pages: [0: initial, 1: failed])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        let outcome = await pagination.goToIndex(
            1,
            location: .start,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testCancelledPageCommandIsNotReportedAsFailed() async {
        let initial = TestPageView()
        let cancelled = TestPageView(commandOutcome: .cancelled)
        let delegate = TestPaginationDelegate(pages: [0: initial, 1: cancelled])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        let outcome = await pagination.goToIndex(
            1,
            location: .start,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .cancelled)
    }

    func testCancellingNavigationCancelsExactTargetCommandAndPreventsLateLanding() async {
        let initial = TestPageView()
        let target = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: initial, 1: target])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        let navigation = Task { @MainActor in
            await pagination.goToIndex(
                1,
                location: .end,
                options: NavigatorGoOptions(animated: false)
            )
        }
        await waitUntil { target.goCallCount == 1 }

        navigation.cancel()
        await waitUntil { target.cancellationObserved }
        target.finishGo()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(target.landingCount, 0)
    }

    func testCancellingStaleNavigationDoesNotCancelNewGenerationCommand() async {
        let initial = TestPageView()
        let firstTarget = TestPageView(blocksGo: true)
        let latestTarget = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [
            0: initial,
            1: firstTarget,
            2: latestTarget,
        ])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        let staleNavigationID = UUID()
        let staleNavigation = Task { @MainActor in
            await pagination.goToIndex(
                1,
                location: .end,
                options: NavigatorGoOptions(animated: false),
                navigationID: staleNavigationID
            )
        }
        await waitUntil { firstTarget.goCallCount == 1 }

        let latestNavigation = Task { @MainActor in
            await pagination.goToIndex(
                2,
                location: .end,
                options: NavigatorGoOptions(animated: false)
            )
        }
        await waitUntil { firstTarget.cancellationObserved }
        firstTarget.finishGo()
        await waitUntil { latestTarget.goCallCount == 1 }

        _ = pagination.cancelNavigationRequest(staleNavigationID)
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertFalse(latestTarget.cancellationObserved)

        latestTarget.finishGo()
        _ = await staleNavigation.value
        let latestOutcome = await latestNavigation.value
        XCTAssertEqual(latestOutcome, .succeeded)
        XCTAssertEqual(latestTarget.landingCount, 1)
    }

    func testCancellingNavigationDuringTransitionDoesNotCancelNeighborPreload() async {
        let initial = TestPageView()
        let target = TestPageView()
        let neighbor = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: initial])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }
        await waitUntil { delegate.requestedIndices.contains(1) }
        delegate.pages[1] = target
        delegate.pages[2] = neighbor

        let navigation = Task { @MainActor in
            await pagination.goToIndex(
                1,
                location: .start,
                options: NavigatorGoOptions(animated: true)
            )
        }
        await waitUntil { neighbor.goCallCount == 1 }

        navigation.cancel()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertFalse(neighbor.cancellationObserved)

        neighbor.finishGo()
        await waitUntil { neighbor.landingCount == 1 }
        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(neighbor.landingCount, 1)
    }

    func testSupersededTargetReportsCancellationRatherThanFailure() async {
        let initial = TestPageView(blocksGo: true)
        let replacement = TestPageView(blocksGo: true)
        let delegate = TestPaginationDelegate(pages: [0: initial, 2: replacement])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        // The replacement loader cannot install page 1 until the blocked
        // predecessor acknowledges, so the navigation parks on the identity
        // stage rather than on its page command.
        let navigation = Task { @MainActor in
            await pagination.goToIndex(
                1,
                location: .start,
                options: NavigatorGoOptions(animated: false)
            )
        }
        await waitUntil { pagination.currentIndex == 1 }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertNil(pagination.loadedViews[1])

        // A reload to another index supersedes the in-flight navigation
        // without cancelling the caller's task: the identity waiter drains and
        // the current index moves on before the caller reaches its command
        // wait.
        pagination.reloadAtIndex(2, location: .start, pageCount: 3, readingProgression: .ltr)
        initial.finishGo()

        let outcome = await navigation.value
        XCTAssertEqual(outcome, .cancelled)
        replacement.finishGo()
    }

    func testNonSucceedingCurrentPageCommandStillPreloadsNeighbor() async {
        let failing = TestPageView(commandOutcome: .failed)
        let neighbor = TestPageView()
        let delegate = TestPaginationDelegate(pages: [0: failing, 1: neighbor])
        let pagination = makePaginationView(preloadPositionCount: 1)
        pagination.delegate = delegate

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)

        await waitUntil { neighbor.goCallCount == 1 }
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
        XCTAssertEqual(failing.goCallCount, 1)
    }

    func testCurrentPageCommandEntryOutcomeProceedsForTheCurrentInBoundsPage() {
        XCTAssertNil(PaginationView.currentPageCommandEntryOutcome(
            index: 1,
            currentIndex: 1,
            pageCount: 3
        ))
    }

    func testCurrentPageCommandEntryOutcomeCancelsAStaleIndex() {
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: 1,
                currentIndex: 2,
                pageCount: 3
            ),
            .cancelled
        )
    }

    func testCurrentPageCommandEntryOutcomeCancelsAnIndexAReloadPushedOutOfBounds() {
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: 3,
                currentIndex: 3,
                pageCount: 3
            ),
            .cancelled
        )
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: -1,
                currentIndex: -1,
                pageCount: 3
            ),
            .cancelled
        )
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
    private let commandOutcome: PageCommandOutcome
    private var goContinuations: [CheckedContinuation<PageCommandOutcome, Never>] = []

    private(set) var goCallCount = 0
    private(set) var activeGoCount = 0
    private(set) var maximumConcurrentGoCount = 0
    private(set) var cancellationObserved = false
    private(set) var commandSupersessionAcknowledgementCount = 0
    private(set) var landingCount = 0

    var goStarted: Bool {
        goCallCount > 0
    }

    init(
        blocksGo: Bool = false,
        commandOutcome: PageCommandOutcome = .succeeded
    ) {
        self.blocksGo = blocksGo
        self.commandOutcome = commandOutcome
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func go(to location: PageLocation, animated: Bool) async -> PageCommandOutcome {
        goCallCount += 1
        activeGoCount += 1
        maximumConcurrentGoCount = max(maximumConcurrentGoCount, activeGoCount)
        defer { activeGoCount -= 1 }
        guard blocksGo else {
            if commandOutcome == .succeeded {
                landingCount += 1
            }
            return commandOutcome
        }

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                goContinuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationObserved = true
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        if outcome == .succeeded {
            landingCount += 1
        }
        return outcome
    }

    func acknowledgeCommandSupersession() {
        commandSupersessionAcknowledgementCount += 1
    }

    func finishGo() {
        guard !goContinuations.isEmpty else { return }
        goContinuations.removeFirst().resume(returning: commandOutcome)
    }
}
