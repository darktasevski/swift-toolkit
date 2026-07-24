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
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
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

    /// Loaded page views in reading order.
    private var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)

        if readingProgression == .rtl {
            orderedViews.reverse()
        }

        return orderedViews
    }

    private let scrollView = UIScrollView()

    /// Set while a transition animation is in progress to prevent
    /// `layoutSubviews` from resetting `contentOffset` and interrupting the
    /// animation.
    private var isAnimatingContentOffset = false

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
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

        if !isAnimatingContentOffset {
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

        activePageCommand?.view.acknowledgeCommandSupersession()
        let predecessor = invalidateLoads(removingLoadedViews: true)
        self.pageCount = pageCount
        self.readingProgression = readingProgression
        setCurrentIndex(
            index,
            location: location,
            replacing: predecessor,
            startsNewGeneration: false
        )
    }

    /// Updates the current and pre-loaded views.
    private func setCurrentIndex(
        _ index: Int,
        location: PageLocation? = nil,
        replacing predecessor: Task<Void, Never>? = nil,
        startsNewGeneration: Bool = true,
        replacingCurrentCommand: Bool = false,
        pageNavigationAnimated: Bool = false,
        navigationID: UUID? = nil
    ) {
        guard replacingCurrentCommand || isEmpty || index != currentIndex else {
            return
        }

        let loadPredecessor: Task<Void, Never>?
        if startsNewGeneration {
            activePageCommand?.view.acknowledgeCommandSupersession()
            loadPredecessor = invalidateLoads(removingLoadedViews: false)
        } else {
            loadPredecessor = predecessor
        }

        // If no explicit location is given, we'll load either the beginning or the end of the
        // resource depending on the last index. This allows to navigate backward across resources,
        // starting from the end of each previous resource.
        let movingBackward = (currentIndex - 1 == index)
        let location = location ?? (movingBackward ? .end : .start)

        currentIndex = index

        // To make sure that the views the most likely to be visible are loaded first, we first load
        // the current one, then the next ones and to finish the previous ones.
        scheduleLoadPage(
            at: index,
            location: location,
            animated: pageNavigationAnimated,
            navigationID: navigationID
        )
        let lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
        let firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)

        for (i, view) in loadedViews {
            // Flushes the views that are not needed anymore.
            guard firstIndex ... lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                continue
            }
        }

        loadPages(replacing: loadPredecessor)
    }

    private func loadPages(replacing predecessor: Task<Void, Never>?) {
        let generation = loadGeneration
        loadPagesTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard
                !Task.isCancelled,
                let self,
                self.loadGeneration == generation
            else {
                return
            }

            await self.loadNextPage(for: generation)
            guard
                !Task.isCancelled,
                self.loadGeneration == generation
            else {
                return
            }
            self.delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func loadNextPage(for generation: LoadGeneration) async {
        guard
            !Task.isCancelled,
            loadGeneration == generation,
            let request = loadingPageQueue.popFirst(),
            request.key.generation == generation
        else {
            return
        }

        let index = request.key.index
        guard isCurrent(request.key) else {
            return
        }

        if loadedViews[index] == nil {
            guard let view = delegate?.paginationView(self, pageViewAtIndex: index) else {
                failPageLoad(request.key)
                return
            }

            guard isCurrent(request.key), loadedViews[index] == nil else {
                view.removeFromSuperview()
                return
            }

            loadedViews[index] = view
            scrollView.addSubview(view)
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
        guard outcome == .succeeded else {
            return
        }
        await loadNextPage(for: generation)
    }

    /// Queue views to be loaded until reaching the given number of pre-loaded positions.
    ///
    /// - Parameters:
    ///   - positionCount: Number of positions to pre-load before stopping.
    ///   - sourceIndex: Starting page index from which to pre-load the views.
    ///   - direction: The direction in which to load the views from the sourceIndex.
    /// - Returns: The last page index to be loaded after reaching the requested number of positions.
    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction,
            location: location
        )
    }

    /// Queue a page to be loaded at the given index, if it's not already loaded.
    ///
    /// - Returns: Whether page is or will be loaded.
    @discardableResult
    private func scheduleLoadPage(
        at index: Int,
        location: PageLocation,
        animated: Bool = false,
        navigationID: UUID? = nil
    ) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        let key = PageLoadKey(generation: loadGeneration, index: index)
        loadingPageQueue.removeAll { $0.key == key }
        scheduledPageLoads.insert(key)
        loadingPageQueue.append(PageLoadRequest(
            key: key,
            location: location,
            animated: animated,
            navigationID: navigationID
        ))
        return true
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
        if Task.isCancelled {
            return nil
        }

        let generation = loadGeneration
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
                } else if failedPageLoads.contains(PageLoadKey(
                    generation: generation,
                    index: index
                )) {
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

    /// Suspends until the exact current page's positioning command completes
    /// for the active pagination generation. Neighbor preloading is not part
    /// of this completion stage.
    private func waitForCurrentPageCommand(at index: Int) async -> PageCommandOutcome {
        guard index == currentIndex, 0 ..< pageCount ~= index else {
            return .failed
        }

        let key = PageLoadKey(generation: loadGeneration, index: index)
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
                    key.index != currentIndex
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
    private func invalidateLoads(removingLoadedViews: Bool) -> Task<Void, Never>? {
        let predecessor = loadPagesTask
        activePageCommand?.task.cancel()
        predecessor?.cancel()
        loadPagesTask = nil
        loadGeneration = LoadGeneration()
        loadingPageQueue.removeAll()
        scheduledPageLoads.removeAll()
        pageCommandOutcomes.removeAll()
        failedPageLoads.removeAll()
        drainCurrentPageWaiters()
        drainPageCommandWaiters()

        if removingLoadedViews {
            for view in loadedViews.values {
                view.removeFromSuperview()
            }
            loadedViews.removeAll()
        }

        return predecessor
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
            resumePageCommandWaiters(with: .cancelled, for: request.key)
        }
        return nil
    }

    private func resumeCurrentPageWaiters(
        with view: UIView & PageView,
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

        let identityWaiterIDs = currentPageWaiters.compactMap { id, waiter in
            waiter.generation == key.generation && waiter.index == key.index
                ? id
                : nil
        }
        for id in identityWaiterIDs {
            guard let waiter = currentPageWaiters.removeValue(forKey: id) else {
                continue
            }
            waiter.continuation.resume(returning: nil)
        }

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
    /// - Returns: The terminal outcome of the page-positioning command.
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

        if currentIndex == index {
            return await scrollToView(
                at: index,
                location: location,
                animated: shouldAnimate,
                navigationID: navigationID
            )
        } else if abs(currentIndex - index) == 1 {
            return await slideToView(
                at: index,
                location: location,
                animated: shouldAnimate,
                navigationID: navigationID
            )
        } else {
            return await fadeToView(
                at: index,
                location: location,
                animated: shouldAnimate,
                navigationID: navigationID
            )
        }
    }

    private func slideToView(
        at index: Int,
        location: PageLocation,
        animated: Bool,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        let fromOffset = scrollView.contentOffset
        let targetOffset = CGPoint(x: xOffsetForIndex(index), y: fromOffset.y)
        let translationX = fromOffset.x - targetOffset.x

        // We use a snapshot of the current view for two reasons:
        //
        // 1. The current view might get flushed when calling
        //    `setCurrentIndex()`, but we want to keep it on the screen during
        //    the animation.
        // 2. A workaround for visual glitches, see https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        let snapshot = snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = bounds
            addSubview(snapshot)
        } else {
            log(.warning, "Could not take a snapshot before sliding to view at index \(index); page transition may flash")
        }

        isAnimatingContentOffset = true
        scrollView.isScrollEnabled = false

        defer {
            snapshot?.removeFromSuperview()
            isAnimatingContentOffset = false
            scrollView.isScrollEnabled = isScrollEnabled
        }

        setCurrentIndex(index, location: location, navigationID: navigationID)

        guard await waitForCurrentPage(at: index) != nil else {
            return await waitForCurrentPageCommand(at: index)
        }
        let outcome = await waitForCurrentPageCommand(at: index)
        guard outcome == .succeeded else {
            return outcome
        }

        scrollView.contentOffset = fromOffset

        if animated {
            await animate(duration: 0.3) {
                snapshot?.transform = CGAffineTransform(translationX: translationX, y: 0)
                self.scrollView.contentOffset = targetOffset
            }
        } else {
            scrollView.contentOffset = targetOffset
        }
        return .succeeded
    }

    private func fadeToView(
        at index: Int,
        location: PageLocation,
        animated: Bool,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        func fade(to alpha: CGFloat) async {
            await animate(duration: animated ? 0.15 : 0) {
                self.alpha = alpha
            }
        }

        await fade(to: 0)
        let outcome = await scrollToView(
            at: index,
            location: location,
            animated: false,
            navigationID: navigationID
        )
        await fade(to: 1)
        return outcome
    }

    private func scrollToView(
        at index: Int,
        location: PageLocation,
        animated: Bool,
        navigationID: UUID
    ) async -> PageCommandOutcome {
        guard currentIndex != index else {
            setCurrentIndex(
                index,
                location: location,
                replacingCurrentCommand: true,
                pageNavigationAnimated: animated,
                navigationID: navigationID
            )
            guard await waitForCurrentPage(at: index) != nil else {
                return await waitForCurrentPageCommand(at: index)
            }
            return await waitForCurrentPageCommand(at: index)
        }

        scrollView.isScrollEnabled = isScrollEnabled
        setCurrentIndex(index, location: location, navigationID: navigationID)

        guard await waitForCurrentPage(at: index) != nil else {
            return await waitForCurrentPageCommand(at: index)
        }
        let outcome = await waitForCurrentPageCommand(at: index)
        guard outcome == .succeeded else {
            return outcome
        }

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: xOffsetForIndex(index),
                y: scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: animated)
        return .succeeded
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
        scrollView.isScrollEnabled = isScrollEnabled
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // A programmatic slide animation sets isScrollEnabled = false and drives the
        // content offset directly. If a delegate callback fires during or just after
        // that window it could call setCurrentIndex with a stale offset, so we bail out.
        guard !isAnimatingContentOffset else { return }

        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        setCurrentIndex(newIndex)
    }
}
