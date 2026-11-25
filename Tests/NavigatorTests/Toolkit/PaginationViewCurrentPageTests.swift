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
    func testNativePaginationDragAdmitsBeforeChangingPages() throws {
        let pagination = makePaginationView()
        let delegate = TestPaginationDelegate(pages: [:])
        pagination.delegate = delegate
        let scrollView = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        XCTAssertEqual(delegate.navigationInputs, 1)
        XCTAssertEqual(pagination.currentIndex, 0)
    }

    func testCurrentPageIdentityResolvesBeforeItsGoAndNeighborPreloading() async {
        let current = TestPageView(blocksGo: true)
        let commandStarted = expectation(description: "Current page has suspended its command")
        current.didSuspendGo = commandStarted
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
        await fulfillment(of: [commandStarted], timeout: 5)
        XCTAssertEqual(delegate.requestedIndices, [1])
        XCTAssertNil(pagination.loadedViews[0])
        XCTAssertNil(pagination.loadedViews[2])

        current.finishGo()
    }

    func testReplacementLoaderWaitsForCancelledPredecessorAcknowledgement() async {
        let first = TestPageView(blocksGo: true)
        let commandStarted = expectation(description: "Predecessor has suspended its command")
        let commandCancelled = expectation(description: "Predecessor has observed cancellation")
        first.didSuspendGo = commandStarted
        first.didObserveCancellation = commandCancelled
        let second = TestPageView()
        let delegate = TestPaginationDelegate(pages: [0: first, 1: second])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        _ = await pagination.waitForCurrentPage(at: 0)
        await fulfillment(of: [commandStarted], timeout: 5)

        pagination.reloadAtIndex(1, location: .start, pageCount: 2, readingProgression: .ltr)
        await fulfillment(of: [commandCancelled], timeout: 5)

        XCTAssertEqual(delegate.requestedIndices, [0])

        first.finishGo()
        let installed = await pagination.waitForCurrentPage(at: 1)

        XCTAssertTrue(installed === second)
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
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
        defer { neighbor.releaseAllGo() }
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
        defer {
            initial.releaseAllGo()
            replacement.releaseAllGo()
        }
        let delegate = TestPaginationDelegate(pages: [0: initial, 2: replacement])
        let pagination = makePaginationView(preloadPositionCount: 1)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        var staged = false
        delegate.onPositionCount = { _, index in
            if index == 2 {
                staged = true
            }
        }

        // The target is queued behind the predecessor's blocked command.
        let finished = expectation(description: "The superseded command waiter exits")
        var outcome: PageCommandOutcome?
        let navigation = Task { @MainActor in
            outcome = await pagination.goToIndex(
                1,
                location: .start,
                options: NavigatorGoOptions(animated: false)
            )
            finished.fulfill()
        }
        defer { navigation.cancel() }
        await waitUntil { staged }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertNil(pagination.loadedViews[1])

        // Reload must settle the queued command's waiter without cancelling its caller.
        pagination.reloadAtIndex(2, location: .start, pageCount: 3, readingProgression: .ltr)
        initial.finishGo()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(outcome, .cancelled)
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

    /// A user drag can cancel the spread command without replacing the queue's generation.
    func testCancelledCurrentPageCommandStillPreloadsNeighbor() async {
        let cancelled = TestPageView(commandOutcome: .cancelled)
        let neighbor = TestPageView()
        let delegate = TestPaginationDelegate(pages: [0: cancelled, 1: neighbor])
        let pagination = makePaginationView(preloadPositionCount: 1)
        pagination.delegate = delegate

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)

        await waitUntil { neighbor.goCallCount == 1 }
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
        XCTAssertEqual(cancelled.goCallCount, 1)
    }

    /// The `.failed` twin of `testSupersededTargetReportsCancellationRatherThanFailure`:
    /// classifying supersession as `.cancelled` must not swallow a genuinely
    /// broken resource, whose `.failed` is what drives the consumer's `.miss`
    /// fallback ladder.
    func testMissingPageFactorySurfacesAsFailureThroughTheCommandStage() async {
        let initial = TestPageView()
        let delegate = TestPaginationDelegate(pages: [0: initial])
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
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
    }

    /// `currentPageCommandEntryOutcome` classifies an out-of-bounds index as
    /// supersession *because* callers bounds-validate first. Pin that premise
    /// at its source, so relaxing this guard cannot silently turn a genuinely
    /// invalid request into a silent `.cancelled`.
    func testOutOfBoundsNavigationRequestIsAFailureNotSupersession() async {
        let initial = TestPageView()
        let delegate = TestPaginationDelegate(pages: [0: initial])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 1, readingProgression: .ltr)
        await waitUntil { initial.goCallCount == 1 }

        let outcome = await pagination.goToIndex(
            1,
            location: .start,
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testCurrentPageCommandEntryOutcomeProceedsForTheCurrentInBoundsPage() {
        XCTAssertNil(PaginationView.currentPageCommandEntryOutcome(
            index: 1,
            attemptIndex: 1,
            pageCount: 3
        ))
    }

    func testCurrentPageCommandEntryOutcomeCancelsAStaleIndex() {
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: 1,
                attemptIndex: 2,
                pageCount: 3
            ),
            .cancelled
        )
    }

    func testCurrentPageCommandEntryOutcomeCancelsAnIndexAReloadPushedOutOfBounds() {
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: 3,
                attemptIndex: 3,
                pageCount: 3
            ),
            .cancelled
        )
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: -1,
                attemptIndex: -1,
                pageCount: 3
            ),
            .cancelled
        )
        // The pre-`reloadAtIndex` state, and the only input where the two
        // clauses disagree: the index IS current, and only the bounds clause
        // forces supersession.
        XCTAssertEqual(
            PaginationView.currentPageCommandEntryOutcome(
                index: 0,
                attemptIndex: 0,
                pageCount: 0
            ),
            .cancelled
        )
    }

    func testSchedulingReentryDoesNotStartASecondLoader() async {
        let current = TestPageView(blocksGo: true)
        let neighbor = TestPageView(blocksGo: true)
        defer {
            current.releaseAllGo()
            neighbor.releaseAllGo()
        }

        let delegate = TestPaginationDelegate(pages: [2: current, 3: neighbor])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        delegate.onPositionCount = { [weak delegate] pagination, _ in
            delegate?.onPositionCount = nil
            pagination.reloadAtIndex(2, location: .start, pageCount: 4, readingProgression: .ltr)
        }
        var currentWasActive = false
        neighbor.onGo = { currentWasActive = current.activeGoCount > 0 }

        pagination.reloadAtIndex(0, location: .start, pageCount: 4, readingProgression: .ltr)
        await waitUntil { current.activeGoCount == 1 }
        for _ in 0 ..< 20 where neighbor.goCallCount == 0 {
            await Task.yield()
        }
        current.finishGo()
        await waitUntil { neighbor.activeGoCount == 1 }

        XCTAssertFalse(currentWasActive, "A neighbor started while the current command was active")
        XCTAssertEqual(delegate.requestedIndices, [2, 3])
    }

    func testSchedulingReentryAwaitsCancelledPredecessor() async {
        await assertReplacementWaitsForPredecessor(detach: false)
    }

    func testReloadAfterDetachAwaitsCancelledPredecessor() async {
        await assertReplacementWaitsForPredecessor(detach: true)
    }

    private func assertReplacementWaitsForPredecessor(detach: Bool) async {
        let old = TestPageView(blocksGo: true)
        let replacement = TestPageView(blocksGo: true)
        let neighbor = TestPageView()
        defer {
            old.releaseAllGo()
            replacement.releaseAllGo()
        }

        let delegate = TestPaginationDelegate(pages: [0: old, 3: replacement, 4: neighbor])
        let pagination = makePaginationView()
        let container = UIView()
        container.addSubview(pagination)
        pagination.delegate = delegate

        var predecessorWasActive = false
        replacement.onGo = { predecessorWasActive = old.activeGoCount > 0 }
        pagination.reloadAtIndex(0, location: .start, pageCount: 5, readingProgression: .ltr)
        await waitUntil { old.activeGoCount == 1 }

        if detach {
            pagination.removeFromSuperview()
            container.addSubview(pagination)
            pagination.reloadAtIndex(3, location: .start, pageCount: 5, readingProgression: .ltr)
        } else {
            delegate.onPositionCount = { [weak delegate] pagination, index in
                guard index == 2 else { return }
                delegate?.onPositionCount = nil
                pagination.reloadAtIndex(3, location: .start, pageCount: 5, readingProgression: .ltr)
            }
            pagination.reloadAtIndex(1, location: .start, pageCount: 5, readingProgression: .ltr)
        }

        await waitUntil { old.cancellationObserved }
        old.finishGo()
        await waitUntil { replacement.activeGoCount == 1 }
        XCTAssertFalse(predecessorWasActive, "The replacement started before the cancelled predecessor exited")
        XCTAssertEqual(Array(delegate.requestedIndices.prefix(2)), [0, 3])
    }

    func testSupersededSchedulingCannotChangeReplacementQueue() async {
        var commandOrder: [Int] = []
        let pages = Dictionary(uniqueKeysWithValues: (1 ... 5).map { index in
            let page = TestPageView()
            page.onGo = { commandOrder.append(index) }
            return (index, page)
        })
        let delegate = TestPaginationDelegate(pages: pages)
        let pagination = makePaginationView(preloadPositionCount: 2)
        pagination.delegate = delegate
        delegate.onPositionCount = { [weak delegate] pagination, index in
            guard index == 1 else { return }
            delegate?.onPositionCount = nil
            pagination.reloadAtIndex(3, location: .start, pageCount: 6, readingProgression: .ltr)
        }

        pagination.reloadAtIndex(0, location: .start, pageCount: 6, readingProgression: .ltr)
        await drain(pagination)
        XCTAssertEqual(delegate.requestedIndices, [3, 4, 5, 2, 1])
        XCTAssertEqual(commandOrder, [3, 4, 5, 2, 1])
    }

    func testFailedNonadjacentMoveKeepsSourcePositionAndViewport() async throws {
        let source = TestPageView()
        let target = TestPageView(commandOutcome: .failed)
        let next = TestPageView(blocksGo: true)
        defer { next.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [0: source, 1: TestPageView(), 2: target, 3: next])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        let scrollView = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
        pagination.reloadAtIndex(0, location: .start, pageCount: 4, readingProgression: .ltr)
        await waitUntil { pagination.loadedViews[1] != nil }

        let outcome = await pagination.goToIndex(2, location: .end, options: NavigatorGoOptions(animated: false))
        XCTAssertEqual(outcome, .failed)
        await waitUntil { next.activeGoCount == 1 }
        pagination.setNeedsLayout()
        pagination.layoutIfNeeded()
        XCTAssertEqual(pagination.currentIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
        XCTAssertTrue(pagination.currentView === source)
        XCTAssertEqual(source.goCallCount, 1)
    }

    func testFailedMovePreservesTheSourceNeighborAndItsEntryPosition() async {
        for destination in [2, 4] {
            let source = TestPageView()
            let neighbor = TestPageView()
            let target = TestPageView(commandOutcome: .failed)
            let pages = [0: source, 1: neighbor, 2: TestPageView(), 3: TestPageView(), 4: TestPageView(), 5: TestPageView()]
                .merging([destination: target]) { _, target in target }
            let delegate = TestPaginationDelegate(pages: pages)
            let pagination = makePaginationView()
            pagination.delegate = delegate
            pagination.reloadAtIndex(0, location: .start, pageCount: 6, readingProgression: .ltr)
            await drain(pagination)

            let finished = expectation(description: "The failed move settles")
            var outcome: PageCommandOutcome?
            let navigation = Task { @MainActor in
                outcome = await pagination.goToIndex(destination, location: .end, options: NavigatorGoOptions(animated: false))
                finished.fulfill()
            }
            defer { navigation.cancel() }
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(outcome, .failed)
            await drain(pagination)

            XCTAssertTrue(pagination.loadedViews[1] === neighbor, "A failed move evicted the source neighbor")
            XCTAssertEqual(neighbor.lastLocation, .start, "A failed move changed the source neighbor's entry position")
        }
    }

    func testSharedNeighborChangesEntryEdgeAfterTheDestinationCommits() async {
        let source = TestPageView()
        let neighbor = TestPageView()
        let target = TestPageView(blocksGo: true)
        defer { target.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [0: source, 1: neighbor, 2: target])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await drain(pagination)

        var selectedIndexAtPreload: Int?
        neighbor.onGo = { [weak pagination] in selectedIndexAtPreload = pagination?.currentIndex }
        let finished = expectation(description: "The destination is committed")
        var outcome: PageCommandOutcome?
        let navigation = Task { @MainActor in
            outcome = await pagination.goToIndex(2, location: .start, options: NavigatorGoOptions(animated: true))
            finished.fulfill()
        }
        defer { navigation.cancel() }
        await waitUntil { target.activeGoCount == 1 }
        target.finishGo()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(outcome, .succeeded)
        await drain(pagination)
        XCTAssertEqual(selectedIndexAtPreload, 2, "The shared neighbor changed its edge before the destination committed")
        XCTAssertEqual(neighbor.lastLocation, .end)
    }

    func testFailedAdjacentMoveDoesNotRepositionItsSource() async {
        let source = TestPageView()
        let target = TestPageView(commandOutcome: .failed)
        let next = TestPageView(blocksGo: true)
        defer { next.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [0: source, 1: target, 2: next])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .end, pageCount: 3, readingProgression: .ltr)
        await waitUntil { target.goCallCount == 1 }

        let outcome = await pagination.goToIndex(1, location: .end, options: NavigatorGoOptions(animated: false))
        XCTAssertEqual(outcome, .failed)
        await waitUntil { next.activeGoCount == 1 }
        next.finishGo()
        await drain(pagination)
        XCTAssertEqual(source.goCallCount, 1, "The source acquired a second position command")
        XCTAssertTrue(pagination.currentView === source)
    }

    func testSupersededStagedMoveLeavesReplacementViewportIntact() async throws {
        for replacementIndex in [1, 2] {
            let source = TestPageView()
            let target = TestPageView()
            let replacement = TestPageView(blocksGo: true)
            defer { replacement.releaseAllGo() }
            let delegate = TestPaginationDelegate(pages: [0: source, 1: target])
            let pagination = makePaginationView(preloadPositionCount: 0)
            pagination.delegate = delegate
            let scrollView = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
            pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
            await waitUntil { source.goCallCount == 1 }

            delegate.onCreate = { [weak delegate] pagination, index in
                guard index == 1, let delegate else { return }
                delegate.onCreate = nil
                delegate.pages[replacementIndex] = replacement
                pagination.reloadAtIndex(replacementIndex, location: .start, pageCount: 3, readingProgression: .ltr)
            }
            var result: PageCommandOutcome?
            let navigation = Task { @MainActor in
                result = await pagination.goToIndex(1, location: .end, options: NavigatorGoOptions(animated: false))
            }
            defer { navigation.cancel() }

            await waitUntil { replacement.activeGoCount == 1 }
            await waitUntil { result != nil }
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(pagination.currentIndex, replacementIndex)
            XCTAssertEqual(scrollView.contentOffset.x, CGFloat(replacementIndex) * scrollView.bounds.width, accuracy: 0.5)
        }
    }

    func testSupersededMoveCannotAbortReplacementMove() async {
        let source = TestPageView()
        let original = TestPageView(blocksGo: true)
        let replacement = TestPageView(blocksGo: true)
        defer {
            original.releaseAllGo()
            replacement.releaseAllGo()
        }
        let delegate = TestPaginationDelegate(pages: [0: source])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await drain(pagination)
        delegate.pages[1] = original
        delegate.pages[2] = replacement

        var originalOutcome: PageCommandOutcome?
        let oldNavigation = Task { @MainActor in
            originalOutcome = await pagination.goToIndex(1, location: .start, options: NavigatorGoOptions(animated: false))
        }
        defer { oldNavigation.cancel() }
        await waitUntil { original.activeGoCount == 1 }

        var replacementOutcome: PageCommandOutcome?
        let newNavigation = Task { @MainActor in
            replacementOutcome = await pagination.goToIndex(2, location: .start, options: NavigatorGoOptions(animated: false))
        }
        defer { newNavigation.cancel() }
        await waitUntil { originalOutcome != nil }
        XCTAssertEqual(originalOutcome, .cancelled)
        original.finishGo()

        await waitUntil { replacement.activeGoCount == 1 }
        replacement.finishGo()
        await waitUntil { replacementOutcome != nil }
        XCTAssertEqual(replacementOutcome, .succeeded, "The obsolete abort must leave replacement settlement owned")
        XCTAssertTrue(pagination.currentView === replacement)
    }

    func testCancellationAfterTargetAttemptBeforeOffsetCommitKeepsSource() async throws {
        let source = TestPageView()
        let target = TestPageView(blocksGo: true)
        let next = TestPageView(blocksGo: true)
        defer {
            target.releaseAllGo()
            next.releaseAllGo()
        }
        let delegate = TestPaginationDelegate(pages: [0: source])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        let scrollView = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { delegate.requestedIndices == [0, 1] }

        delegate.pages[1] = target
        delegate.pages[2] = next
        var result: PageCommandOutcome?
        let navigation = Task { @MainActor in
            result = await pagination.goToIndex(1, location: .end, options: NavigatorGoOptions(animated: false))
        }
        defer { navigation.cancel() }
        await waitUntil { target.activeGoCount == 1 }
        delegate.onUpdate = { _ in navigation.cancel() }
        target.finishGo()

        await waitUntil { next.activeGoCount == 1 }
        await waitUntil { result != nil }
        XCTAssertEqual(target.landingCount, 1)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(pagination.currentIndex, 0)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)
    }

    func testMissingCurrentFactoryStillPreloadsNeighbor() async {
        let neighbor = TestPageView(blocksGo: true)
        defer { neighbor.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [1: neighbor])
        let pagination = makePaginationView()
        pagination.delegate = delegate

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)

        await waitUntil { neighbor.goCallCount > 0 }
        XCTAssertEqual(delegate.requestedIndices, [0, 1])
        XCTAssertNil(pagination.loadedViews[0])
    }

    func testMissingMiddleFactoryPreservesRemainingQueuePriority() async {
        let last = TestPageView(blocksGo: true)
        defer { last.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [
            0: last, 1: TestPageView(), 2: TestPageView(), 4: TestPageView(),
        ])
        let pagination = makePaginationView(preloadPositionCount: 2)
        pagination.delegate = delegate

        pagination.reloadAtIndex(2, location: .start, pageCount: 5, readingProgression: .ltr)

        await waitUntil { last.goCallCount > 0 }
        XCTAssertEqual(delegate.requestedIndices, [2, 3, 4, 1, 0])
        XCTAssertNil(pagination.loadedViews[3])
        XCTAssertNotNil(pagination.loadedViews[4])
        XCTAssertNotNil(pagination.loadedViews[1])
    }

    func testCurrentAttemptNotifiesBeforeNeighborsForEveryOutcome() async {
        for outcome in [PageCommandOutcome.succeeded, .failed, .cancelled] {
            let current = TestPageView(blocksGo: true, commandOutcome: outcome)
            let firstNeighbor = TestPageView(blocksGo: true)
            let secondNeighbor = TestPageView(blocksGo: true)
            defer {
                current.releaseAllGo()
                firstNeighbor.releaseAllGo()
                secondNeighbor.releaseAllGo()
            }
            let delegate = TestPaginationDelegate(pages: [
                0: current, 1: firstNeighbor, 2: secondNeighbor,
            ])
            let pagination = makePaginationView(preloadPositionCount: 2)
            pagination.delegate = delegate
            pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)

            await waitUntil { current.goCallCount > 0 }
            XCTAssertEqual(delegate.updateCount, 0, "Installation is not terminal completion")
            current.finishGo()
            await waitUntil { firstNeighbor.goCallCount > 0 }
            XCTAssertEqual(delegate.updateCount, 1, "Current outcome: \(outcome)")
            firstNeighbor.finishGo()
            await waitUntil { secondNeighbor.goCallCount > 0 }
            XCTAssertEqual(delegate.updateCount, 1, "Neighbors must not repeat the callback")
            secondNeighbor.finishGo()
            await drain(pagination)
            XCTAssertEqual(delegate.updateCount, 1, "Queue exit must not repeat the callback")
        }
    }

    func testMissingCurrentAttemptNotifiesBeforeNeighborFinishes() async {
        let neighbor = TestPageView(blocksGo: true)
        defer { neighbor.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [1: neighbor])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)

        await waitUntil { neighbor.goCallCount > 0 }
        XCTAssertNil(pagination.currentView)
        XCTAssertEqual(delegate.updateCount, 1)
        neighbor.finishGo()
        await drain(pagination)
        XCTAssertEqual(delegate.updateCount, 1, "Queue exit must not repeat the callback")
    }

    func testSupersededAttemptDoesNotNotify() async {
        let old = TestPageView(blocksGo: true)
        let replacement = TestPageView(blocksGo: true)
        let neighbor = TestPageView(blocksGo: true)
        defer {
            old.releaseAllGo()
            replacement.releaseAllGo()
            neighbor.releaseAllGo()
        }
        let delegate = TestPaginationDelegate(pages: [0: old, 1: replacement, 2: neighbor])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { old.goCallCount > 0 }

        delegate.pages[0] = TestPageView()
        pagination.reloadAtIndex(1, location: .start, pageCount: 3, readingProgression: .ltr)
        await waitUntil { old.cancellationObserved }
        old.finishGo()
        await waitUntil { replacement.goCallCount > 0 }
        XCTAssertEqual(delegate.updateCount, 0)
        replacement.finishGo()
        await waitUntil { neighbor.goCallCount > 0 }
        XCTAssertEqual(delegate.updateCount, 1)
    }

    func testCurrentNotificationReloadStopsOldNeighborQueue() async {
        let current = TestPageView(blocksGo: true)
        let replacement = TestPageView(blocksGo: true)
        let replacementNeighbor = TestPageView(blocksGo: true)
        defer {
            current.releaseAllGo()
            replacement.releaseAllGo()
            replacementNeighbor.releaseAllGo()
        }
        let delegate = TestPaginationDelegate(pages: [
            0: current, 1: TestPageView(), 2: replacement, 3: replacementNeighbor,
        ])
        let pagination = makePaginationView()
        pagination.delegate = delegate
        delegate.onUpdate = { pagination in
            if pagination.currentIndex == 0 {
                pagination.reloadAtIndex(2, location: .start, pageCount: 4, readingProgression: .ltr)
            }
        }
        pagination.reloadAtIndex(0, location: .start, pageCount: 4, readingProgression: .ltr)
        await waitUntil { current.goCallCount > 0 }
        current.finishGo()

        await waitUntil { replacement.goCallCount > 0 }
        XCTAssertEqual(delegate.requestedIndices, [0, 2])
        XCTAssertEqual(delegate.updateCount, 1)
        replacement.finishGo()
        await waitUntil { replacementNeighbor.goCallCount > 0 }
        XCTAssertEqual(delegate.updateCount, 2)
    }

    func testCommittedSlideKeepsTargetAfterCancellationAndResize() async throws {
        let source = TestPageView()
        let target = TestPageView(blocksGo: true)
        defer { target.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [0: source, 1: target])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        let scroll = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await drain(pagination)

        let finished = expectation(description: "The slide settles")
        var result: PageCommandOutcome?
        let navigation = Task { @MainActor in
            result = await pagination.goToIndex(1, location: .end, options: NavigatorGoOptions(animated: true))
            finished.fulfill()
        }
        defer { navigation.cancel() }
        await waitUntil { target.activeGoCount == 1 }
        XCTAssertEqual(pagination.currentIndex, 0, "Staging must not change the visible index")
        XCTAssertTrue(pagination.currentView === source, "Staging must not expose an offscreen view")
        XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 0.5)

        target.finishGo()
        await waitUntil { scroll.contentOffset.x > 0 }
        XCTAssertNil(result, "Resize and cancellation must occur during the committed transition")
        pagination.frame.size.width += 80
        pagination.setNeedsLayout()
        pagination.layoutIfNeeded()
        navigation.cancel()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(pagination.currentIndex, 1)
        XCTAssertEqual(scroll.contentOffset.x, scroll.bounds.width, accuracy: 0.5, "The committed page must align at the new width")
    }

    func testReplacementOnCommittedPageRealignsAfterResize() async throws {
        let target = TestPageView(blocksGo: true)
        defer { target.releaseAllGo() }
        let delegate = TestPaginationDelegate(pages: [0: TestPageView(), 1: target])
        let pagination = makePaginationView(preloadPositionCount: 0)
        pagination.delegate = delegate
        let scroll = try XCTUnwrap(pagination.subviews.compactMap { $0 as? UIScrollView }.first)
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await drain(pagination)

        let firstFinished = expectation(description: "The superseded slide finishes")
        var firstOutcome: PageCommandOutcome?
        let first = Task { @MainActor in
            firstOutcome = await pagination.goToIndex(1, location: .end, options: NavigatorGoOptions(animated: true))
            firstFinished.fulfill()
        }
        defer { first.cancel() }
        await waitUntil { target.activeGoCount == 1 }
        target.finishGo()
        await waitUntil { pagination.currentIndex == 1 }
        XCTAssertNil(firstOutcome, "The replacement must arrive before the slide finishes")

        pagination.frame.size.width += 80
        pagination.setNeedsLayout()
        pagination.layoutIfNeeded()

        let replacementFinished = expectation(description: "The same-page replacement finishes")
        var replacementOutcome: PageCommandOutcome?
        let replacement = Task { @MainActor in
            replacementOutcome = await pagination.goToIndex(1, location: .start, options: NavigatorGoOptions(animated: false))
            replacementFinished.fulfill()
        }
        defer { replacement.cancel() }
        await waitUntil { target.goCallCount == 2 }
        target.finishGo()

        await fulfillment(of: [replacementFinished, firstFinished], timeout: 5)
        XCTAssertEqual(replacementOutcome, .succeeded)
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(scroll.contentOffset.x, scroll.bounds.width, accuracy: 0.5, "The replacement must align the committed page")
    }

    func testReentrantAttachmentCannotLeaveAnOrphanPage() async {
        let stale = TestPageView()
        let replacement = TestPageView()
        let pagination = makePaginationView(preloadPositionCount: 0)
        let delegate = TestPaginationDelegate(pages: [0: stale, 1: replacement])
        pagination.delegate = delegate
        stale.onSuperviewChange = { [weak pagination] newSuperview in
            if newSuperview != nil {
                pagination?.reloadAtIndex(1, location: .start, pageCount: 2, readingProgression: .ltr)
            }
        }

        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await waitUntil { replacement.goCallCount == 1 }
        XCTAssertNil(stale.superview, "The obsolete attachment must be removed from the hierarchy")
        XCTAssertEqual(stale.goCallCount, 0)
        XCTAssertTrue(pagination.currentView === replacement)
    }

    func testSourceEvictionReloadSupersedesCommittedNavigation() async {
        let source = TestPageView()
        let target = TestPageView()
        let replacement = TestPageView()
        let pagination = makePaginationView(preloadPositionCount: 0)
        let delegate = TestPaginationDelegate(pages: [0: source, 2: target, 3: replacement])
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 4, readingProgression: .ltr)
        await drain(pagination)
        source.onSuperviewChange = { [weak pagination, weak source] newSuperview in
            guard newSuperview == nil else { return }
            source?.onSuperviewChange = nil
            pagination?.reloadAtIndex(3, location: .start, pageCount: 4, readingProgression: .ltr)
        }

        let outcome = await pagination.goToIndex(2, location: .start, options: NavigatorGoOptions(animated: false))

        XCTAssertEqual(outcome, .cancelled, "The source eviction reentered and replaced the landing")
        await waitUntil { replacement.goCallCount == 1 }
        XCTAssertTrue(pagination.currentView === replacement)
    }

    func testSameIndexNotificationReloadSupersedesNavigation() async {
        let source = TestPageView()
        let replacement = TestPageView()
        let pagination = makePaginationView(preloadPositionCount: 0)
        let delegate = TestPaginationDelegate(pages: [0: source, 1: replacement])
        pagination.delegate = delegate
        pagination.reloadAtIndex(0, location: .start, pageCount: 2, readingProgression: .ltr)
        await drain(pagination)
        delegate.onUpdate = { [weak delegate] pagination in
            delegate?.onUpdate = nil
            pagination.reloadAtIndex(1, location: .start, pageCount: 2, readingProgression: .ltr)
        }

        let outcome = await pagination.goToIndex(0, location: .end, options: NavigatorGoOptions(animated: false))

        XCTAssertEqual(outcome, .cancelled, "The terminal callback already replaced the generation")
        await waitUntil { replacement.goCallCount == 1 }
        XCTAssertTrue(pagination.currentView === replacement)
    }

    private func drain(_ pagination: PaginationView) async {
        guard let loader = pagination.loadPagesTaskForTesting else {
            return XCTFail("No pagination loader to join")
        }
        let drained = expectation(description: "Pagination loader exited")
        Task { @MainActor in
            await loader.value
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 5)
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
    var onPositionCount: ((PaginationView, Int) -> Void)?
    var onUpdate: ((PaginationView) -> Void)?
    var navigationInputs = 0
    func paginationViewWillBeginUserNavigation(_ paginationView: PaginationView) {
        navigationInputs += 1
    }

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
        onUpdate?(paginationView)
    }

    func paginationView(
        _ paginationView: PaginationView,
        positionCountAtIndex index: Int
    ) -> Int {
        onPositionCount?(paginationView, index)
        return 1
    }
}

@MainActor
private final class TestPageView: UIView, PageView {
    var onGo: (() -> Void)?
    var onSuperviewChange: ((UIView?) -> Void)?

    private let blocksGo: Bool
    private var releasesFutureGo = false
    private let commandOutcome: PageCommandOutcome
    private var goContinuations: [CheckedContinuation<PageCommandOutcome, Never>] = []

    private(set) var goCallCount = 0
    private(set) var activeGoCount = 0
    private(set) var maximumConcurrentGoCount = 0
    private(set) var cancellationObserved = false
    private(set) var commandSupersessionAcknowledgementCount = 0
    private(set) var landingCount = 0
    private(set) var lastLocation: PageLocation?

    var didSuspendGo: XCTestExpectation?
    var didObserveCancellation: XCTestExpectation?

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

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        onSuperviewChange?(newSuperview)
    }

    func go(to location: PageLocation, animated: Bool) async -> PageCommandOutcome {
        goCallCount += 1
        lastLocation = location
        activeGoCount += 1
        maximumConcurrentGoCount = max(maximumConcurrentGoCount, activeGoCount)
        defer { activeGoCount -= 1 }
        onGo?()
        guard !Task.isCancelled else { return .cancelled }
        guard blocksGo, !releasesFutureGo else {
            if commandOutcome == .succeeded {
                landingCount += 1
            }
            return commandOutcome
        }

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                goContinuations.append(continuation)
                didSuspendGo?.fulfill()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationObserved = true
                self?.didObserveCancellation?.fulfill()
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

    func releaseAllGo() {
        releasesFutureGo = true
        let continuations = goContinuations
        goContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: commandOutcome)
        }
    }

    func finishGo() {
        guard !goContinuations.isEmpty else { return }
        goContinuations.removeFirst().resume(returning: commandOutcome)
    }
}
