//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

enum PageCommandOutcome: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

@MainActor
protocol PageView: AnyObject {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation, animated: Bool) async -> PageCommandOutcome

    /// Authorizes an in-flight command to preserve its same-document frame
    /// capability when cancellation hands off to a known replacement.
    func acknowledgeCommandSupersession()
}

extension PageView {
    func acknowledgeCommandSupersession() {}
}

@MainActor
protocol PaginationViewDelegate: AnyObject {
    /// Called before a recognized native drag changes the spine position.
    func paginationViewWillBeginUserNavigation(_ paginationView: PaginationView)

    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the current-page attempt terminates, before neighbor preloading.
    /// A terminal attempt does not imply a successful landing.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView {
    private struct LoadGeneration: Equatable, Hashable {
        let id = UUID()
    }

    private struct PageLoadKey: Equatable, Hashable {
        let generation: LoadGeneration
        let index: Int
    }

    private struct PageLoadRequest {
        let key: PageLoadKey
        let location: PageLocation
        let animated: Bool
        let navigationID: UUID?
    }

    private struct ActivePageCommand {
        let id: UUID
        let key: PageLoadKey
        let navigationID: UUID?
        let view: UIView & PageView
        let task: Task<PageCommandOutcome, Never>
    }

    private struct PageMove: Equatable {
        let key: PageLoadKey
        let sourceIndex: Int
    }

    private enum ViewportTransition: Equatable {
        case positioning(PageMove)
        case presenting(PageLoadKey)

        var sourceIndex: Int? {
            guard case let .positioning(move) = self else { return nil }
            return move.sourceIndex
        }
    }

    private struct CurrentPageWaiter {
        let generation: LoadGeneration
        let index: Int
        let continuation: CheckedContinuation<(UIView & PageView)?, Never>
    }

    private struct PageCommandWaiter {
        let key: PageLoadKey
        let continuation: CheckedContinuation<PageCommandOutcome, Never>
    }

    weak var delegate: PaginationViewDelegate?

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int

    /// Queue of page indexes to be loaded by the current generation.
    private var loadingPageQueue: [PageLoadRequest] = []
    private var scheduledPageLoads: Set<PageLoadKey> = []
    private var pageCommandOutcomes: [PageLoadKey: PageCommandOutcome] = [:]
    private var failedPageLoads: Set<PageLoadKey> = []
    private var loadGeneration = LoadGeneration()
    private var currentPageWaiters: [UUID: CurrentPageWaiter] = [:]
    private var pageCommandWaiters: [UUID: PageCommandWaiter] = [:]
    private var activePageCommand: ActivePageCommand?

    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    private let scrollView = UIScrollView()

    private var viewportTransition: ViewportTransition?
    private var transitionSnapshot: UIView?
    private var committedPreloadRange: ClosedRange<Int>?
    private var preloadWaiter: CheckedContinuation<Void, Never>?

    private var commandAttemptIndex: Int {
        if case let .positioning(move) = viewportTransition {
            return move.key.index
        }
        return currentIndex
    }

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled && viewportTransition == nil }
    }

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = true
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        addSubview(scrollView)

        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        insertSubview(UIView(frame: .zero), at: 0)
        // Prevents the content from jumping down when the status bar is toggled
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size
        scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)

        for (index, view) in loadedViews {
            view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y: 0), size: size)
        }

        switch viewportTransition {
        case .presenting:
            break
        case .positioning, nil:
            scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            invalidateLoads(removingLoadedViews: true)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            invalidateLoads(removingLoadedViews: true)
        }
    }

    /// Returns the x offset to the page view with given index in the scroll view.
    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }

    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)

        let generation = invalidateLoads(removingLoadedViews: true, acknowledgingSupersession: true)
        guard loadGeneration == generation else { return }
        self.pageCount = pageCount
        self.readingProgression = readingProgression
        scheduleCurrentPage(PageLoadKey(generation: generation, index: index), location: location)
    }

    /// Updates the selection after a native drag has already moved the viewport.
    private func selectDraggedPage(_ index: Int) {
        guard 0 ..< pageCount ~= index, isEmpty || index != currentIndex else { return }
        let generation = invalidateLoads(removingLoadedViews: false, acknowledgingSupersession: true)
        guard loadGeneration == generation else { return }
        let location: PageLocation = currentIndex - 1 == index ? .end : .start
        scheduleCurrentPage(PageLoadKey(generation: generation, index: index), location: location)
    }

    @discardableResult
    private func scheduleCurrentPage(
        _ key: PageLoadKey,
        location: PageLocation,
        animated: Bool = false,
        navigationID: UUID? = nil
    ) -> ClosedRange<Int>? {
        let generation = key.generation
        guard loadGeneration == generation else { return nil }
        if viewportTransition == nil {
            currentIndex = key.index
        }
        enqueuePage(key, location: location, animated: animated, navigationID: navigationID)

        // Current page first, followed by forward and backward preloads.
        let last = scheduleNeighbors(from: key, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
        let first = scheduleNeighbors(from: key, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)
        guard loadGeneration == generation else { return nil }

        let preloadRange = first ... last
        let retainedSource = viewportTransition?.sourceIndex
        let retainedRange = retainedSource == nil ? nil : committedPreloadRange
        if retainedSource == nil {
            committedPreloadRange = preloadRange
        }
        evictViews(outside: preloadRange, alsoKeeping: retainedRange, source: retainedSource)

        startLoader(for: key)
        return loadGeneration == generation ? preloadRange : nil
    }

    private func evictViews(
        outside preloadRange: ClosedRange<Int>,
        alsoKeeping retainedRange: ClosedRange<Int>? = nil,
        source retainedSource: Int? = nil
    ) {
        let evicted = loadedViews.filter { index, _ in
            index != retainedSource && retainedRange?.contains(index) != true && !preloadRange.contains(index)
        }
        for index in evicted.keys {
            loadedViews.removeValue(forKey: index)
        }
        for view in evicted.values {
            view.removeFromSuperview()
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func startLoader(for currentAttempt: PageLoadKey) {
        let generation = currentAttempt.generation
        guard loadGeneration == generation else { return }
        let predecessor = loadPagesTask
        loadPagesTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }

            while !Task.isCancelled,
                  self.loadGeneration == generation,
                  let request = self.loadingPageQueue.first
            {
                if case let .positioning(move) = self.viewportTransition,
                   self.repositionsSourcePreload(request, during: move)
                {
                    await withCheckedContinuation { self.preloadWaiter = $0 }
                    continue
                }
                self.loadingPageQueue.removeFirst()
                guard self.isCurrent(request.key) else { continue }
                await self.loadPage(request)
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                if request.key == currentAttempt,
                   self.pageCommandOutcomes[request.key] != nil || self.failedPageLoads.contains(request.key)
                {
                    self.delegate?.paginationViewDidUpdateViews(self)
                }
            }
        }
    }

    private func resumePreloading() {
        let waiter = preloadWaiter
        preloadWaiter = nil
        waiter?.resume()
    }

    private func repositionsSourcePreload(_ request: PageLoadRequest, during move: PageMove) -> Bool {
        let index = request.key.index
        return request.key != move.key
            && committedPreloadRange?.contains(index) == true
            && loadedViews[index] != nil
            && (index < move.sourceIndex) != (index < move.key.index)
    }

    private func loadPage(_ request: PageLoadRequest) async {
        let index = request.key.index
        guard isCurrent(request.key) else {
            return
        }

        if loadedViews[index] == nil {
            guard let view = delegate?.paginationView(self, pageViewAtIndex: index) else {
                failPageLoad(request.key)
                return
            }

            guard isCurrent(request.key), loadedViews[index] == nil else { return }

            loadedViews[index] = view
            defer {
                // UIKit can attach the view after willMove(toSuperview:) invalidates its load.
                if loadedViews[index] !== view {
                    view.removeFromSuperview()
                }
            }
            scrollView.addSubview(view)
            guard isCurrent(request.key), loadedViews[index] === view else { return }
            setNeedsLayout()
            // The freshly added page view has no frame until the deferred layout
            // pass runs, but `view.go(to:)` below immediately drives
            // content-dependent navigation inside it. Commanding a zero-sized
            // web view makes every viewport-relative computation degenerate
            // (0-width layout viewport, clamped scroll writes), so force the
            // already-scheduled pass to complete before the first command.
            layoutIfNeeded()

            guard isCurrent(request.key), loadedViews[index] === view else {
                return
            }

            if index == currentIndex {
                resumeCurrentPageWaiters(with: view, for: request.key)
            }
        }

        guard
            isCurrent(request.key),
            let view = loadedViews[index]
        else {
            return
        }

        let commandID = UUID()
        let commandTask = Task { @MainActor in
            await view.go(to: request.location, animated: request.animated)
        }
        activePageCommand = ActivePageCommand(
            id: commandID,
            key: request.key,
            navigationID: request.navigationID,
            view: view,
            task: commandTask
        )
        let outcome = await commandTask.value
        if activePageCommand?.id == commandID {
            activePageCommand = nil
        }
        guard
            !Task.isCancelled,
            isCurrent(request.key),
            loadedViews[index] === view
        else {
            return
        }

        scheduledPageLoads.remove(request.key)
        pageCommandOutcomes[request.key] = outcome
        resumePageCommandWaiters(with: outcome, for: request.key)
    }

    /// Queues neighbors until the position budget is exhausted.
    private func scheduleNeighbors(
        from source: PageLoadKey,
        upToPositionCount positionCount: Int,
        direction: PageIndexDirection,
        location: PageLocation
    ) -> Int {
        let index = source.index + direction.rawValue
        guard source.generation == loadGeneration, positionCount > 0, 0 ..< pageCount ~= index else {
            return source.index
        }

        let neighbor = PageLoadKey(generation: source.generation, index: index)
        if index != viewportTransition?.sourceIndex || loadedViews[index] == nil {
            enqueuePage(neighbor, location: location)
        }

        guard let count = delegate?.paginationView(self, positionCountAtIndex: index) else {
            return source.index
        }
        guard source.generation == loadGeneration else { return source.index }
        return scheduleNeighbors(
            from: neighbor,
            upToPositionCount: positionCount - count,
            direction: direction,
            location: location
        )
    }

    private func enqueuePage(
        _ key: PageLoadKey,
        location: PageLocation,
        animated: Bool = false,
        navigationID: UUID? = nil
    ) {
        loadingPageQueue.removeAll { $0.key == key }
        scheduledPageLoads.insert(key)
        loadingPageQueue.append(PageLoadRequest(
            key: key,
            location: location,
            animated: animated,
            navigationID: navigationID
        ))
    }

    private func isCurrent(_ key: PageLoadKey) -> Bool {
        key.generation == loadGeneration
            && 0 ..< pageCount ~= key.index
            && scheduledPageLoads.contains(key)
    }

    /// Suspends until the exact current page object is installed for the
    /// active pagination generation. Page installation is independent from
    /// the page's initial `go` and from neighbor preloading.
    func waitForCurrentPage(at index: Int) async -> (UIView & PageView)? {
        guard index == currentIndex, 0 ..< pageCount ~= index else {
            return nil
        }
        let key = PageLoadKey(generation: loadGeneration, index: index)
        if failedPageLoads.contains(key) {
            return nil
        }
        if let view = loadedViews[index] {
            return view
        }
        guard !Task.isCancelled, scheduledPageLoads.contains(key) else { return nil }

        let generation = key.generation
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if
                    generation == loadGeneration,
                    index == currentIndex,
                    let view = loadedViews[index]
                {
                    continuation.resume(returning: view)
                } else if generation != loadGeneration || index != currentIndex {
                    continuation.resume(returning: nil)
                } else if !scheduledPageLoads.contains(key) {
                    continuation.resume(returning: nil)
                } else {
                    currentPageWaiters[waiterID] = CurrentPageWaiter(
                        generation: generation,
                        index: index,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCurrentPageWaiter(waiterID)
            }
        }
    }

    /// Reports supersession of a page-command wait, or `nil` to proceed with the wait.
    ///
    /// Callers bounds-validate their index at `goToIndex`, so both stale forms
    /// observable here — the attempt index moved on, or a concurrent reload
    /// shrank the page count — are supersession by the reader's own newer
    /// work, not a resolution failure inside the still-current generation.
    /// Reporting `.failed` would map to `.miss` at the consumer seam and send
    /// a fallback ladder chasing a navigation the reader already replaced.
    /// The in-continuation staleness arm below classifies the same conditions
    /// as `.cancelled`; this keeps the entry check symmetric with it.
    static func currentPageCommandEntryOutcome(
        index: Int,
        attemptIndex: Int,
        pageCount: Int
    ) -> PageCommandOutcome? {
        guard index == attemptIndex, 0 ..< pageCount ~= index else {
            return .cancelled
        }
        return nil
    }

    /// Waits for the active generation's exact target command. A staged target
    /// can be different from the visible page during a cross-page move.
    private func waitForCurrentPageCommand(for key: PageLoadKey) async -> PageCommandOutcome {
        guard key.generation == loadGeneration else { return .cancelled }
        if let outcome = Self.currentPageCommandEntryOutcome(
            index: key.index,
            attemptIndex: commandAttemptIndex,
            pageCount: pageCount
        ) {
            return outcome
        }

        if let outcome = pageCommandOutcomes[key] {
            return outcome
        }
        if failedPageLoads.contains(key) {
            return .failed
        }
        if Task.isCancelled {
            return .cancelled
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if let outcome = pageCommandOutcomes[key] {
                    continuation.resume(returning: outcome)
                } else if
                    key.generation != loadGeneration ||
                    key.index != commandAttemptIndex
                {
                    continuation.resume(returning: .cancelled)
                } else if failedPageLoads.contains(key) {
                    continuation.resume(returning: .failed)
                } else {
                    pageCommandWaiters[waiterID] = PageCommandWaiter(
                        key: key,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPageCommandWaiter(waiterID)
            }
        }
    }

    @discardableResult
    private func invalidateLoads(
        removingLoadedViews: Bool,
        acknowledgingSupersession: Bool = false
    ) -> LoadGeneration {
        let generation = LoadGeneration()
        let predecessor = loadPagesTask
        let outgoingCommand = activePageCommand
        let removedViews = removingLoadedViews ? Array(loadedViews.values) : []
        let interruptedTransition = viewportTransition
        let snapshot = transitionSnapshot

        loadGeneration = generation
        activePageCommand = nil
        viewportTransition = nil
        transitionSnapshot = nil
        loadingPageQueue.removeAll()
        scheduledPageLoads.removeAll()
        pageCommandOutcomes.removeAll()
        failedPageLoads.removeAll()
        drainCurrentPageWaiters()
        drainPageCommandWaiters()
        resumePreloading()

        if removingLoadedViews {
            loadedViews.removeAll()
            committedPreloadRange = nil
        }

        snapshot?.removeFromSuperview()
        if case .presenting = interruptedTransition, !removingLoadedViews, loadGeneration == generation {
            alignCommittedPage()
        }
        if interruptedTransition != nil {
            restorePresentation(for: generation)
        }
        if acknowledgingSupersession {
            outgoingCommand?.view.acknowledgeCommandSupersession()
        }
        outgoingCommand?.task.cancel()
        predecessor?.cancel()
        for view in removedViews {
            view.removeFromSuperview()
        }

        return generation
    }

    @discardableResult
    func cancelNavigationRequest(
        _ navigationID: UUID
    ) -> Task<PageCommandOutcome, Never>? {
        if let activePageCommand,
           activePageCommand.navigationID == navigationID
        {
            activePageCommand.task.cancel()
            return activePageCommand.task
        }

        let cancelledRequests = loadingPageQueue.filter {
            $0.navigationID == navigationID
        }
        loadingPageQueue.removeAll { $0.navigationID == navigationID }
        for request in cancelledRequests where request.key.generation == loadGeneration {
            scheduledPageLoads.remove(request.key)
            pageCommandOutcomes[request.key] = .cancelled
            resumeCurrentPageWaiters(with: nil, for: request.key)
            resumePageCommandWaiters(with: .cancelled, for: request.key)
        }
        return nil
    }

    private func resumeCurrentPageWaiters(
        with view: (UIView & PageView)?,
        for key: PageLoadKey
    ) {
        let waiterIDs = currentPageWaiters.compactMap { id, waiter in
            waiter.generation == key.generation && waiter.index == key.index
                ? id
                : nil
        }
        for id in waiterIDs {
            guard let waiter = currentPageWaiters.removeValue(forKey: id) else {
                continue
            }
            waiter.continuation.resume(returning: view)
        }
    }

    private func failPageLoad(_ key: PageLoadKey) {
        guard key.generation == loadGeneration else { return }
        scheduledPageLoads.remove(key)
        failedPageLoads.insert(key)

        resumeCurrentPageWaiters(with: nil, for: key)
        resumePageCommandWaiters(with: .failed, for: key)
    }

    private func resumePageCommandWaiters(
        with outcome: PageCommandOutcome,
        for key: PageLoadKey
    ) {
        let waiterIDs = pageCommandWaiters.compactMap { id, waiter in
            waiter.key == key ? id : nil
        }
        for id in waiterIDs {
            guard let waiter = pageCommandWaiters.removeValue(forKey: id) else {
                continue
            }
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func cancelPageCommandWaiter(_ id: UUID) {
        guard let waiter = pageCommandWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(returning: .cancelled)
    }

    private func drainPageCommandWaiters() {
        let waiters = pageCommandWaiters.values
        pageCommandWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: .cancelled)
        }
    }

    private func cancelCurrentPageWaiter(_ id: UUID) {
        guard let waiter = currentPageWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(returning: nil)
    }

    private func drainCurrentPageWaiters() {
        let waiters = currentPageWaiters.values
        currentPageWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Navigation

    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: The outcome of positioning the page and settling any viewport move.
    func goToIndex(
        _ index: Int,
        location: PageLocation,
        options: NavigatorGoOptions
    ) async -> PageCommandOutcome {
        await goToIndex(
            index,
            location: location,
            options: options,
            navigationID: UUID()
        )
    }

    func goToIndex(
        _ index: Int,
        location: PageLocation,
        options: NavigatorGoOptions,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        guard 0 ..< pageCount ~= index else {
            return .failed
        }

        return await withTaskCancellationHandler {
            let outcome = await performGoToIndex(
                index,
                location: location,
                options: options,
                navigationID: navigationID
            )
            guard Task.isCancelled else { return outcome }
            if let commandTask = cancelNavigationRequest(navigationID) {
                _ = await commandTask.value
            }
            return .cancelled
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelNavigationRequest(navigationID)
            }
        }
    }

    private func performGoToIndex(
        _ index: Int,
        location: PageLocation,
        options: NavigatorGoOptions,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        guard !Task.isCancelled else { return .cancelled }

        let shouldAnimate = options.animated && !UIAccessibility.isReduceMotionEnabled

        let sourceIndex = currentIndex
        let generation = invalidateLoads(removingLoadedViews: false, acknowledgingSupersession: true)
        guard loadGeneration == generation else { return .cancelled }

        let key = PageLoadKey(generation: generation, index: index)
        if sourceIndex == index {
            scheduleCurrentPage(key, location: location, animated: shouldAnimate, navigationID: navigationID)
            let outcome = await waitForCurrentPageCommand(for: key)
            return loadGeneration == generation ? outcome : .cancelled
        }

        return await moveToView(
            PageMove(key: key, sourceIndex: sourceIndex),
            location: location,
            animated: shouldAnimate,
            navigationID: navigationID
        )
    }

    private func moveToView(
        _ move: PageMove,
        location: PageLocation,
        animated: Bool,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        let key = move.key
        let positioning = ViewportTransition.positioning(move)
        let presenting = ViewportTransition.presenting(key)
        viewportTransition = positioning
        scrollView.isScrollEnabled = false
        guard let preloadRange = scheduleCurrentPage(key, location: location, navigationID: navigationID) else {
            return .cancelled
        }

        let outcome = await waitForCurrentPageCommand(for: key)
        guard outcome == .succeeded else {
            abortMove(move)
            return Task.isCancelled || loadGeneration != key.generation ? .cancelled : outcome
        }
        guard viewportTransition == positioning else { return .cancelled }

        let isAdjacent = abs(move.sourceIndex - key.index) == 1
        // The snapshot avoids exposing a rendering gap while a page slides in.
        let snapshot = animated && isAdjacent ? snapshotView(afterScreenUpdates: false) : nil
        defer { snapshot?.removeFromSuperview() }
        if let snapshot, viewportTransition == positioning {
            snapshot.frame = bounds
            transitionSnapshot = snapshot
            addSubview(snapshot)
        }

        if !isAdjacent, animated {
            await animate(duration: 0.15) {
                guard self.viewportTransition == positioning, !Task.isCancelled else { return }
                self.alpha = 0
            }
        }

        await animate(duration: isAdjacent && animated ? 0.3 : 0) {
            guard self.viewportTransition == positioning, !Task.isCancelled else { return }
            let offset = self.xOffsetForIndex(key.index)
            let translation = self.scrollView.contentOffset.x - offset
            self.currentIndex = key.index
            self.committedPreloadRange = preloadRange
            self.viewportTransition = presenting
            self.resumePreloading()
            self.scrollView.contentOffset.x = offset
            snapshot?.transform = CGAffineTransform(translationX: translation, y: 0)
        }

        guard viewportTransition == presenting else {
            abortMove(move)
            return .cancelled
        }

        if !isAdjacent, animated {
            await animate(duration: 0.15) {
                guard self.viewportTransition == presenting else { return }
                self.alpha = 1
            }
        }

        guard viewportTransition == presenting else { return .cancelled }
        viewportTransition = nil
        transitionSnapshot = nil
        alignCommittedPage()
        restorePresentation(for: key.generation)
        if loadGeneration == key.generation {
            evictViews(outside: preloadRange)
        }
        return loadGeneration == key.generation ? .succeeded : .cancelled
    }

    private func abortMove(_ move: PageMove) {
        guard viewportTransition == .positioning(move) else { return }
        // Keep cached source neighbors at their original entry edge if the move never commits.
        loadingPageQueue.removeAll { request in
            guard repositionsSourcePreload(request, during: move) else { return false }
            scheduledPageLoads.remove(request.key)
            return true
        }
        viewportTransition = nil
        transitionSnapshot = nil
        resumePreloading()
        setNeedsLayout()
        scrollView.contentOffset.x = xOffsetForIndex(move.sourceIndex)
        restorePresentation(for: move.key.generation)
    }

    private func alignCommittedPage() {
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func restorePresentation(for generation: LoadGeneration) {
        guard loadGeneration == generation else { return }
        alpha = 1
        guard loadGeneration == generation else { return }
        scrollView.isScrollEnabled = isScrollEnabled
    }

    private func animate(duration: TimeInterval, animations: @escaping () -> Void) async {
        if duration > 0 {
            await withCheckedContinuation { continuation in
                UIView.animate(
                    withDuration: duration,
                    animations: animations,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        } else {
            animations()
        }
    }
}

extension PaginationView: UIScrollViewDelegate {
    // We disable the scroll once the user releases the drag to prevent scrolling through more than 1 resource at a
    // time. Otherwise, because the pagination view's scroll view would have the focus during the scroll gesture, the
    // scrollable content of the resources would be skipped.
    // Note: using this approach might provide a better experience:
    // https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = isScrollEnabled && viewportTransition == nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled && viewportTransition == nil
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A programmatic transition owns the viewport until it settles.
        guard viewportTransition == nil else { return }

        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        selectDraggedPage(newIndex)
    }
}

#if RENDER_FAITHFUL_NAV_TESTING
    extension PaginationView {
        var loadPagesTaskForTesting: Task<Void, Never>? {
            loadPagesTask
        }
    }
#endif
