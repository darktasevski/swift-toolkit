//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumInternal
import ReadiumShared
import SafariServices
import SwiftSoup
import UIKit
import WebKit

@MainActor public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate,
    ViewportObservingNavigatorDelegate, VisibleAnchorObservingNavigatorDelegate
{
    // MARK: - WebView Customization

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController)

    // MARK: - Image Zoom

    /// Called when the user tapped on an image that should be zoomed.
    func navigator(_ navigator: EPUBNavigatorViewController, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?)
}

public extension EPUBNavigatorDelegate {
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}

    func navigator(_ navigator: EPUBNavigatorViewController, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?) {}
}

public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

/// The observable result of a render-faithful locator command.
public enum LocatorNavigationOutcome: Equatable, Sendable {
    case landed
    case miss
    case cancelled
}

open class EPUBNavigatorViewController: InputObservableViewController,
    VisualNavigator, ViewportObservingNavigator, VisibleAnchorObservingNavigator,
    SelectableNavigator, DecorableNavigator, Configurable, Loggable
{
    enum PageCommandNavigationDisposition: Equatable {
        case landed
        case miss
        case cancelled
    }

    static func navigationDisposition(
        for outcome: PageCommandOutcome
    ) -> PageCommandNavigationDisposition {
        switch outcome {
        case .succeeded:
            return .landed
        case .failed:
            return .miss
        case .cancelled:
            return .cancelled
        }
    }

    /// - Parameter documentIsCurrent: whether the frame document `outcome`
    ///   resolved against is still the one this spread owns. Read ONLY for a
    ///   `.ready` outcome, because only a `.ready` outcome bound a document: a
    ///   timeout or failure resolved against nothing, so folding currency into
    ///   the guard below would turn it into a silent `.cancelled` and strand the
    ///   caller with no fallback rung and no logged failure.
    ///
    ///   Currency here is document identity, never generation equality. A
    ///   position or decoration writer acquired the instant readiness publishes
    ///   advances the generation while keeping the same document — the benign
    ///   same-document mutation that an equality gate reports as supersession.
    /// Whether the world `outcome` bound is still the one the spread owns.
    ///
    /// Both terms are load-bearing and neither is obvious:
    ///
    /// - The capability is read through `currentFrameCapability`, which answers during
    ///   `.initializing` as well as `.ready`. A `.ready`-only destructure would read nil while
    ///   a same-document mutation is in flight and report the landing superseded — the bug this
    ///   whole path exists to fix, one line further down.
    /// - Generation is compared with `>=`, not `==`. The bounded wait resumes through a task
    ///   group, so several main-actor suspensions separate the `.ready` publish from this read,
    ///   and a same-document mutation can land in any of them. An equality gate turns that into
    ///   a silent `.cancelled`: a tap that does nothing, with no fallback rung.
    ///
    /// A LOWER generation is not reachable while `targetIsCurrent` holds — that pins the same
    /// spread object, whose readiness is a `let` — so the comparison is really "has not gone
    /// backwards" stated for a case the caller has already excluded. Kept because the term costs
    /// nothing and the exclusion lives in a different function.
    static func readySpreadDocumentIsCurrent(
        for outcome: EPUBSpreadReadiness.WaitOutcome,
        currentCapability: EPUBSpreadFrameCapability?,
        currentGeneration: EPUBSpreadReadiness.Generation
    ) -> Bool {
        // A non-`.ready` outcome bound no document; `readySpreadNavigationDisposition` ignores
        // this value for those, and returning `false` keeps a non-landing from ever reading as
        // a current world if a future caller forgets that.
        guard case let .ready(readyGeneration, readyCapability) = outcome else {
            return false
        }
        return currentCapability == readyCapability && currentGeneration >= readyGeneration
    }

    static func readySpreadNavigationDisposition(
        for outcome: EPUBSpreadReadiness.WaitOutcome,
        targetIsCurrent: Bool,
        documentIsCurrent: Bool,
        taskIsCancelled: Bool
    ) -> PageCommandNavigationDisposition {
        guard !taskIsCancelled, targetIsCurrent else {
            return .cancelled
        }

        switch outcome {
        case .ready:
            return documentIsCurrent ? .landed : .cancelled
        case .documentAvailable, .timedOut, .failed:
            return .miss
        case .invalidated, .cancelled:
            return .cancelled
        }
    }

    enum PageTurnNavigationDisposition: Equatable {
        case moved
        case crossResource
        case failed
        case cancelled
    }

    static func pageTurnNavigationDisposition(
        for outcome: EPUBSpreadView.PageTurnOutcome
    ) -> PageTurnNavigationDisposition {
        switch outcome {
        case .succeeded:
            return .moved
        case .boundary:
            return .crossResource
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    public enum EPUBError: Error {
        /// The provided publication is restricted. Check that any DRM was
        /// properly unlocked using a Content Protection.
        case publicationRestricted

        /// Returned when calling evaluateJavaScript() before a resource is
        /// loaded.
        case spreadNotLoaded

        /// Failed to serve the publication or assets with the provided HTTP
        /// server.
        @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
        case serverFailure(Error)
    }

    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: EPUBPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: EPUBDefaults

        /// Editing actions which will be displayed in the default text selection menu.
        ///
        /// The default set of editing actions is `EditingAction.defaultActions`.
        ///
        /// You can provide custom actions with `EditingAction(title: "Highlight", action: #selector(highlight:))`.
        /// Then, implement the selector in one of your classes in the responder chain. Typically, in the
        /// `UIViewController` wrapping the `EPUBNavigatorViewController`.
        public var editingActions: [EditingAction]

        /// Disables horizontal page turning when scroll is enabled.
        public var disablePageTurnsWhileScrolling: Bool

        /// Content insets used to add some vertical margins around reflowable
        /// EPUB publications. Note that the margins include the safe area
        /// insets. To avoid any "jump" when toggling the status bar, provide
        /// values large enough.
        ///
        /// The insets can be configured for each size class to allow smaller
        /// margins on compact screens.
        ///
        /// For more control, implement the `navigatorContentInset()` delegate
        /// method, which takes precedence over this configuration property
        /// when implemented.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount: Int

        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount: Int

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Additional font families which will be available in the preferences.
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]

        /// Readium CSS reading system settings.
        ///
        /// See https://readium.org/readium-css/docs/CSS19-api.html#reading-system-styles
        public var readiumCSSRSProperties: CSSRSProperties

        /// Logs the state changes when true.
        public var debugState: Bool

        /// Tolerant XHTML well-formedness repair (host fork, ADR-0145), applied
        /// to HTML resources in `serve(href:)` BEFORE Readium CSS injection.
        /// `href` is the served resource (the host keys the per-resource
        /// `anchor_order_preserved` signal on it). The closure owns the UTF-8
        /// decode and returns the original `Data` on any failure. `nil` ⇒
        /// disabled (no cost). The host runs the blocking FFI off the main actor.
        public var xhtmlRepairTransform: (@Sendable (RelativeURL, Data) async -> Data)?

        public init(
            preferences: EPUBPreferences = .empty,
            defaults: EPUBDefaults = EPUBDefaults(),
            editingActions: [EditingAction] = EditingAction.defaultActions,
            disablePageTurnsWhileScrolling: Bool = false,
            contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
                .compact: (top: 34, bottom: 34),
                .regular: (top: 62, bottom: 62),
            ],
            preloadPreviousPositionCount: Int = 2,
            preloadNextPositionCount: Int = 6,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties(),
            debugState: Bool = false,
            xhtmlRepairTransform: (@Sendable (RelativeURL, Data) async -> Data)? = nil
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.editingActions = editingActions
            self.disablePageTurnsWhileScrolling = disablePageTurnsWhileScrolling
            self.contentInset = contentInset
            self.preloadPreviousPositionCount = preloadPreviousPositionCount
            self.preloadNextPositionCount = preloadNextPositionCount
            self.decorationTemplates = decorationTemplates
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
            self.debugState = debugState
            self.xhtmlRepairTransform = xhtmlRepairTransform
        }

        func contentInset(for sizeClass: UIUserInterfaceSizeClass) -> EPUBContentInsets {
            contentInset[sizeClass]
                ?? contentInset[.regular]
                ?? contentInset[.unspecified]
                ?? (top: 0, bottom: 0)
        }
    }

    public weak var delegate: EPUBNavigatorDelegate?

    /// Information about the visible portion of the publication, when rendered.
    public private(set) var viewport: NavigatorViewport? {
        didSet {
            if oldValue != viewport {
                delegate?.navigator(self, viewportDidChange: viewport)
            }
        }
    }

    @available(*, deprecated, renamed: "NavigatorViewport")
    public typealias Viewport = NavigatorViewport

    /// Navigation state.
    private enum State: Equatable {
        /// Initializing the navigator.
        case initializing
        /// Loading the spreads at the `pendingLocator`, for example after
        /// changing the user settings, rotating the screen or loading the
        /// publication.
        case loading(pendingLocator: Locator?)
        /// Waiting for further navigation instructions.
        case idle
        /// Jumping to `pendingLocator`.
        case jumping(pendingLocator: Locator)
        /// Turning the page in the given `direction`.
        case moving(direction: EPUBSpreadView.Direction)

        var pendingLocator: Locator? {
            switch self {
            case let .loading(pendingLocator: locator):
                return locator
            case let .jumping(pendingLocator: locator):
                return locator
            default:
                return nil
            }
        }

        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            // Loading the spreads is always possible, because it can be triggered by rotating the
            // screen. In which case it cancels any on-going state.
            case let (_, .load(locator)):
                self = .loading(pendingLocator: locator)

            // All events are ignored when loading spreads, except for `loaded` and `load`.
            case (.loading, .loaded):
                self = .idle

            case (.loading, _):
                return false

            case let (.idle, .jump(locator)):
                self = .jumping(pendingLocator: locator)

            case let (.idle, .move(direction)):
                self = .moving(direction: direction)

            case (.jumping, .jumped):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending jump.
            case (.jumping, .jump),
                 (.jumping, .move):
                return false

            case (.moving, .moved):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending move.
            case (.moving, .jump),
                 (.moving, .move):
                return false

            default:
                log(.error, "Invalid event \(event) for state \(self)")
                return false
            }

            return true
        }
    }

    /// Navigation event.
    private enum Event: Equatable {
        /// Load the spreads at the given locator, for example after changing
        /// the user settings, rotating the screen or loading the publication.
        case load(Locator?)
        /// The spreads were loaded.
        case loaded
        /// Jump to the given locator.
        case jump(Locator)
        /// Finished jumping to a locator.
        case jumped
        /// Turn the page in the given direction.
        case move(EPUBSpreadView.Direction)
        /// Finished turning the page.
        case moved
    }

    /// Current navigation state.
    private var state: State = .initializing {
        didSet {
            if config.debugState {
                log(.debug, "* \(state)")
            }

            // Disable user interaction while transitioning, to avoid UX issues.
            switch state {
            case .initializing, .loading, .jumping, .moving:
                paginationView?.isUserInteractionEnabled = false
                _ = idleNotificationGate.setIdle(false)
            case .idle:
                paginationView?.isUserInteractionEnabled = true
                // Drain a request coalesced mid-navigation the instant we settle.
                if idleNotificationGate.setIdle(true) {
                    Task { @MainActor [weak self] in
                        await self?.notifyCurrentLocation()
                    }
                }
            }
        }
    }

    private let readingOrder: [Link]
    public private(set) var currentLocation: Locator?
    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private let viewModel: EPUBNavigatorViewModel
    public var publication: Publication {
        viewModel.publication
    }

    var config: Configuration {
        viewModel.config
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    ///
    /// - Parameters:
    ///   - publication: EPUB publication to render.
    ///   - initialLocation: Starting location in the publication, defaults to
    ///   the beginning.
    ///   - readingOrder: Custom order of resources to display. Used for example
    ///   to display a non-linear resource on its own.
    ///   - config: Additional navigator configuration.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        visibleAnchorTargets: [String: [String]] = [:]
    ) throws {
        precondition(readingOrder.map { !$0.isEmpty } ?? true)

        guard !publication.isRestricted else {
            throw EPUBError.publicationRestricted
        }

        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder ?? publication.readingOrder,
            config: config
        )
        viewModel.updateVisibleAnchorTargets(visibleAnchorTargets)

        self.init(
            viewModel: viewModel,
            initialLocation: initialLocation,
            readingOrder: viewModel.readingOrder,
            positionsByReadingOrder:
            // Positions and total progression only make sense in the context
            // of the publication's actual reading order. Therefore when
            // provided with a different reading order, we should assume the
            // positions list is empty, and also not compute the
            // totalProgression when calculating the current locator.
            (readingOrder != nil) ? { .success([]) } : publication.positionsByReadingOrder
        )
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        httpServer: HTTPServer
    ) throws {
        try self.init(
            publication: publication,
            initialLocation: initialLocation,
            readingOrder: readingOrder,
            config: config
        )
    }

    private init(
        viewModel: EPUBNavigatorViewModel,
        initialLocation: Locator?,
        readingOrder: [Link],
        positionsByReadingOrder: @escaping () async -> ReadResult<[[Locator]]>
    ) {
        self.viewModel = viewModel
        currentLocation = initialLocation
        self.readingOrder = readingOrder
        loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

        viewModel.delegate = self
        viewModel.editingActions.delegate = self

        setupLegacyInputCallbacks(
            onTap: { [weak self] point in
                guard let self else { return }
                self.delegate?.navigator(self, didTapAt: point)
            },
            onPressKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didPressKey: event)
            },
            onReleaseKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didReleaseKey: event)
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        // Will call `accessibilityScroll()` when VoiceOver reaches the end of
        // the current resource. We can use this to go to the next resource.
        view.accessibilityTraits.insert(.causesPageTurn)

        Task {
            await initialize()
        }
    }

    private var isActive = true

    @objc private func willResignActive() {
        isActive = false
    }

    @objc private func didBecomeActive() {
        isActive = true

        // The device may have rotated since the last time the app was active.
        // We may need to refresh the spreads in this situation. Unfortunately,
        // the `viewWillTransition(to:with:)` API is called before we receive
        // the `didBecomeActive` notification, so we cannot rely on it here.
        viewModel.viewSizeWillChange(view.bounds.size)

        if needsReloadSpreadsOnActive {
            needsReloadSpreadsOnActive = false
            reloadSpreads()
        }
    }

    private func initialize() async {
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }

        paginationView = makePaginationView(
            hasPositions: !positionsByReadingOrder.isEmpty
        )

        paginationView!.frame = view.bounds
        paginationView!.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView!)

        applySettings()

        _reloadSpreads()

        onInitializedCallbacks.complete()
    }

    private let onInitializedCallbacks = CompletionList()

    private func initialized() async {
        await withCheckedContinuation { continuation in
            whenInitialized {
                continuation.resume()
            }
        }
    }

    private func whenInitialized(_ callback: @escaping () -> Void) {
        let callback = onInitializedCallbacks.add(callback)
        if state != .initializing {
            callback()
        }
    }

    @available(iOS 13.0, *)
    override open func buildMenu(with builder: UIMenuBuilder) {
        viewModel.editingActions.buildMenu(with: builder)
        super.buildMenu(with: builder)
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.viewSizeWillChange(view.bounds.size)
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if isActive {
            viewModel.viewSizeWillChange(size)
        }
    }

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread, "Raising navigation events must be done from the main thread")

        if config.debugState {
            log(.debug, "-> on \(event)")
        }

        return state.transition(event)
    }

    /// Mapping between reading order hrefs and the table of contents title.
    private var tableOfContentsTitleByHref: [AnyURL: String] {
        get async { await tableOfContentsTitleByHrefTask.value }
    }

    private lazy var tableOfContentsTitleByHrefTask: Task<[AnyURL: String], Never> = Task {
        func fulfill(linkList: [Link]) -> [AnyURL: String] {
            var result = [AnyURL: String]()

            for link in linkList {
                if let title = link.title {
                    result[link.url()] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { current, _ -> String in
                    current
                }
            }
            return result
        }

        guard let toc = try? await publication.tableOfContents().get() else {
            return [:]
        }

        return fulfill(linkList: toc)
    }

    /// Goes to the next or previous page in the given scroll direction.
    private func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard
            let paginationView = paginationView,
            on(.move(direction))
        else {
            return false
        }

        if let spreadView = paginationView.currentView as? EPUBSpreadView {
            let pageTurnOutcome = await spreadView.go(to: direction, options: options)
            switch Self.pageTurnNavigationDisposition(for: pageTurnOutcome) {
            case .moved:
                on(.moved)
                return true
            case .failed, .cancelled:
                on(.moved)
                return false
            case .crossResource:
                break
            }
        }

        let isRTL = (viewModel.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let outcome: PageCommandOutcome = await {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndex(currentSpreadIndex - delta, location: location, options: options)
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndex(currentSpreadIndex + delta, location: location, options: options)
            }
        }()

        on(.moved)
        return Self.navigationDisposition(for: outcome) == .landed
    }

    // MARK: - Pagination and spreads

    private var paginationView: PaginationView?

    private func makePaginationView(hasPositions: Bool) -> PaginationView {
        let view = PaginationView(
            frame: .zero,
            preloadPreviousPositionCount: hasPositions ? config.preloadPreviousPositionCount : 0,
            preloadNextPositionCount: hasPositions ? config.preloadNextPositionCount : 0,
            isScrollEnabled: isPaginationViewScrollingEnabled
        )
        view.delegate = self
        view.backgroundColor = .clear
        return view
    }

    private func invalidatePaginationView() {
        guard let paginationView = paginationView else {
            return
        }

        paginationView.isScrollEnabled = isPaginationViewScrollingEnabled
        reloadSpreads()
    }

    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    private var currentSpreadIndex: Int {
        paginationView?.currentIndex ?? 0
    }

    private var needsReloadSpreadsOnActive = false

    private func reloadSpreads() {
        guard
            state != .initializing,
            isViewLoaded
        else {
            return
        }

        guard isActive else {
            // If we reload the spreads while the app is in the background, the
            // web view will reset to progression 0 instead of the current one.
            // We need to wait for the application to return to the foreground
            // to maintain the current location.
            needsReloadSpreadsOnActive = true
            return
        }

        _reloadSpreads()
    }

    private func _reloadSpreads() {
        // Rebuilding the spreads invalidates any in-flight precise locator
        // landing: its target spread is about to be torn down. Drain the queue
        // with an explicit .cancelled outcome (and abort the suspended bridge
        // command) before the rebuild, rather than relying on the operation
        // self-erroring once its webview vanishes. This is also the drain point
        // for a process-termination rebuild (spreadViewDidTerminate → reload).
        locatorNavigationTaskQueue.cancelPending()

        let locator = currentLocation

        guard
            let paginationView = paginationView,
            on(.load(locator))
        else {
            return
        }

        spreads = EPUBSpread.makeSpreads(
            for: publication,
            readingOrder: readingOrder,
            readingProgression: viewModel.readingProgression,
            spread: viewModel.spreadEnabled,
            offsetFirstPage: viewModel.offsetFirstPage
        )

        let initialIndex: ReadingOrder.Index = {
            if
                let href = locator?.href,
                let index = readingOrder.firstIndexWithHREF(href),
                let foundIndex = self.spreads.firstIndexWithReadingOrderIndex(index)
            {
                return foundIndex
            } else {
                return 0
            }
        }()

        paginationView.reloadAtIndex(
            initialIndex,
            location: PageLocation(locator),
            pageCount: spreads.count,
            readingProgression: viewModel.readingProgression
        )

        on(.loaded)
    }

    private func loadedSpreadViewForHREF<T: URLConvertible>(_ href: T) -> EPUBSpreadView? {
        guard
            let loadedViews = paginationView?.loadedViews,
            let index = readingOrder.firstIndexWithHREF(href)
        else {
            return nil
        }

        return loadedViews
            .compactMap { _, view in view as? EPUBSpreadView }
            .first { $0.spread.contains(index: index) }
    }

    // MARK: - Navigator

    private var isPaginationViewScrollingEnabled: Bool {
        !(config.disablePageTurnsWhileScrolling && settings.scroll)
    }

    public var presentation: VisualNavigatorPresentation {
        VisualNavigatorPresentation(
            readingProgression: settings.readingProgression,
            scroll: settings.scroll,
            axis: (settings.scroll && !settings.verticalText)
                ? .vertical
                : .horizontal
        )
    }

    private func computeCurrentLocationAndViewport() async -> (Locator?, NavigatorViewport?) {
        if case .initializing = state {
            assertionFailure("Cannot update current location when initializing the navigator")
            return (nil, nil)
        }

        // Returns any pending locator to prevent returning invalid locations
        // while loading it.
        if let pendingLocator = state.pendingLocator {
            return (pendingLocator, nil)
        }

        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return (nil, nil)
        }

        let (locator, viewport) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: spreadView.spread.readingOrderIndices,
            progression: { spreadView.progression(in: $0) },
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder,
            tableOfContentsTitleByHref: tableOfContentsTitleByHref,
            fallbackLocator: { [publication] in await publication.locate($0) }
        )
        return (locator, viewport)
    }

    public func firstVisibleElementLocator() async -> Locator? {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        return await spreadView.findFirstVisibleElementLocator()
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?

    /// Postpones the location notification until the navigator settles into
    /// its `idle` state. An edge-triggered gate coalesces requests made
    /// mid-navigation and drains them on the `busy → idle` transition (see the
    /// `state` observer) instead of polling every fixed interval.
    private let idleNotificationGate = EPUBIdleNotificationGate(isIdle: false)

    private func updateCurrentLocation() {
        guard idleNotificationGate.request() else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.notifyCurrentLocation()
        }
    }

    private func notifyCurrentLocation() async {
        (currentLocation, viewport) = await computeCurrentLocationAndViewport()

        guard
            let delegate = delegate,
            let location = currentLocation,
            location != notifiedCurrentLocation
        else {
            return
        }
        notifiedCurrentLocation = location
        delegate.navigator(self, locationDidChange: location)
    }

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        await goToLocator(locator, options: options) == .succeeded
    }

    /// Executes the locator's pagination stage without collapsing failure and
    /// cancellation into the public Navigator `Bool` contract.
    func goToLocator(
        _ locator: Locator,
        options: NavigatorGoOptions
    ) async -> PageCommandOutcome {
        let locator = publication.normalizeLocator(locator)

        guard
            let paginationView = paginationView,
            let index = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(index),
            on(.jump(locator))
        else {
            return .failed
        }

        let outcome = await paginationView.goToIndex(
            spreadIndex,
            location: .locator(locator),
            options: options
        )
        on(.jumped)
        if Self.navigationDisposition(for: outcome) == .landed {
            delegate?.navigator(self, didJumpTo: locator)
        }
        return outcome
    }

    /// Whether the bridge locator command may animate its scroll. After a
    /// resource hop the document was already positioned at the FULL target
    /// locator during spread initialization (pre-reveal, via the pending
    /// location), so the bridge run is a verification of an already-positioned
    /// page and must be invisible — animating it replays the scroll after
    /// reveal as a spurious slide. Without a hop the bridge IS the user-visible
    /// motion and honors the caller's request.
    nonisolated static func bridgeCommandAnimated(
        requestedAnimated: Bool,
        didHopToResource: Bool
    ) -> Bool {
        requestedAnimated && !didHopToResource
    }

    /// Navigates with the bounded, fixed-source locator command bridge and
    /// reports the command's actual landing result, together with the receipt
    /// binding the world it landed in.
    ///
    /// The receipt is what lets the caller's later steps — uniqueness
    /// validation, a transient decoration, a fallback rung — prove they are
    /// still acting on the world this command landed in rather than on whatever
    /// replaced it while they were suspended. It is present only for `.landed`.
    public func navigateToLocatorJSON(
        _ locatorJSON: String,
        animated: Bool
    ) async -> EPUBLocatorNavigationResult {
        let receiptSlot = EPUBLocatorCommandReceiptSlot()
        let outcome = await locatorNavigationTaskQueue.run { [weak self] in
            guard let self else { return .cancelled }
            return await self.performLocatorNavigation(
                locatorJSON,
                animated: animated,
                receiptSlot: receiptSlot
            )
        } cancellationRelay: { [weak self] in
            await self?.cancelInFlightLocatorNavigation()
        }
        // A landing is the only outcome that bound a world. The queue also
        // downgrades a completed operation to `.cancelled` when the request was
        // superseded on the way out, and that downgrade must drop the receipt
        // with it.
        guard outcome == .landed else {
            return .unreceipted(outcome)
        }
        return EPUBLocatorNavigationResult(outcome: outcome, receipt: receiptSlot.receipt)
    }

    private func performLocatorNavigation(
        _ locatorJSON: String,
        animated: Bool,
        receiptSlot: EPUBLocatorCommandReceiptSlot
    ) async -> LocatorNavigationOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }
        // Every locator navigation takes the next sequence number, so a later
        // one starting is exactly what makes an earlier one's receipt stale.
        locatorOperationSequence &+= 1
        // Operation start: the ONE deadline every rung below spends from — the
        // cross-resource hop, page identity, command readiness, and the bridge
        // command's own viewport/settle/correction waits. No rung re-mints it, so
        // the wall-clock cost of a landing can no longer grow with the number of
        // resources it passes through.
        let deadline = EPUBLocatorOperationDeadline(
            startingAt: locatorClock.now(),
            budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
        )
        guard
            let payload = try? EPUBLocatorCommandDecoder.decode(locatorJSON),
            let decoded = try? Locator(json: payload.locator)
        else {
            return .miss
        }
        let locator = publication.normalizeLocator(decoded)
        guard
            let paginationView,
            let readingOrderIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(readingOrderIndex)
        else {
            return .miss
        }

        let spreadView: EPUBSpreadView
        var didHopToResource = false
        if
            paginationView.currentIndex == spreadIndex,
            let loaded = paginationView.loadedViews[spreadIndex] as? EPUBSpreadView,
            loaded.isCommandReady
        {
            spreadView = loaded
        } else {
            // Hop with the FULL locator, not a resource-only one: the pending
            // location applies it as the final initialization stage, so the
            // spread reveals ALREADY positioned at the target (a single
            // perceived landing — no chapter-top paint, no post-reveal slide).
            // The bridge run below stays the truthful landing authority.
            didHopToResource = true
            // Publish the hop so the TARGET spread's stylesheet/font/geometry
            // stabilization spends what is LEFT of this deadline rather than minting a
            // fresh allowance of its own. The spread initializes on its own load event,
            // so it pulls this back through the delegate instead of receiving it down
            // the call stack. Scoped to the hop and identity-guarded on withdrawal: a
            // preloaded neighbour loading in this window is not part of the operation,
            // and a superseded predecessor unwinding here must not clear a successor's
            // entry.
            let hop = EPUBActiveLocatorOperation(
                readingOrderIndex: readingOrderIndex,
                deadline: deadline
            )
            activeLocatorOperationSlot.publish(hop)
            defer { activeLocatorOperationSlot.clear(hop) }

            let resourceOutcome = await goToLocator(
                locator,
                options: NavigatorGoOptions(animated: animated)
            )
            switch Self.navigationDisposition(for: resourceOutcome) {
            case .landed:
                break
            case .miss:
                return .miss
            case .cancelled:
                return .cancelled
            }
            switch await waitForReadySpread(at: spreadIndex, deadline: deadline) {
            case let .ready(loaded):
                spreadView = loaded
            case .miss:
                return .miss
            case .cancelled:
                return .cancelled
            }
        }

        guard let writerLease = spreadView.readiness.acquirePositionWriter() else {
            return .cancelled
        }
        defer { spreadView.readiness.release(writerLease) }

        // Expose this bridge so a superseding request's relay can abort the
        // command below in its own frame. Clear only if a newer request has not
        // already claimed the tracker (the bounded-acknowledgement race).
        let bridge = spreadView.locatorCommandBridge
        inFlightLocatorBridge = bridge
        defer {
            if inFlightLocatorBridge === bridge {
                inFlightLocatorBridge = nil
            }
        }

        let result = await bridge.navigate(
            locatorJSON: locatorJSON,
            targetHREF: locator.href,
            animated: Self.bridgeCommandAnimated(
                requestedAnimated: animated,
                didHopToResource: didHopToResource
            ),
            deadline: deadline
        )
        switch result.outcome {
        case .applied:
            // Mint the receipt from the SAME snapshot every later revalidation
            // rebuilds, so the two can never drift apart. If the world has
            // already moved off this spread by the time the command reports,
            // there is nothing truthful to bind and the landing carries no
            // receipt — the caller then treats every later step as stale, which
            // is the fail-closed direction.
            if
                let world = currentLocatorWorld(),
                world.spreadIndex == spreadIndex,
                world.spreadIdentity == ObjectIdentifier(spreadView)
            {
                receiptSlot.record(EPUBLocatorCommandReceipt(world: world))
            }
            return .landed
        case .miss:
            return .miss
        case .cancelled:
            return .cancelled
        }
    }

    /// Snapshots the render world of the spread currently on screen.
    ///
    /// One builder serves both minting and revalidation: a receipt is this
    /// snapshot taken at landing, and currency is the comparison against a later
    /// one. Sharing the builder is what makes "the same world" mean the same
    /// thing at both ends.
    private func currentLocatorWorld() -> EPUBLocatorCommandReceipt.World? {
        guard let paginationView else { return nil }
        let index = paginationView.currentIndex
        guard let spreadView = paginationView.loadedViews[index] as? EPUBSpreadView else {
            return nil
        }
        return EPUBLocatorCommandReceipt.World(
            spreadIndex: index,
            spreadIdentity: ObjectIdentifier(spreadView),
            generation: spreadView.readiness.generation,
            frameCapability: spreadView.readiness.currentFrameCapability,
            isCommandReady: spreadView.isCommandReady,
            operationSequence: locatorOperationSequence
        )
    }

    /// Whether a landing receipt still describes the live world.
    ///
    /// Callers revalidate after every suspension between the landing and the
    /// act it authorizes — uniqueness validation, a transient decoration apply
    /// or clear — so a command superseded mid-flight cannot paint into, or wipe,
    /// the world its successor established.
    public func isReceiptCurrent(_ receipt: EPUBLocatorCommandReceipt) -> Bool {
        guard let world = currentLocatorWorld() else { return false }
        return receipt.isCurrent(in: world)
    }

    /// Checks the transient-highlight uniqueness rule inside the isolated
    /// command world. Only a closed command outcome crosses back to native.
    ///
    /// Requires the landing's receipt, and revalidates it on both sides of the
    /// bridge round-trip: a uniqueness answer is only meaningful for the
    /// document the command landed in, and a stale `true` is precisely what
    /// would let a superseded command paint a look-alike occurrence in whatever
    /// replaced it.
    public func isLocatorTextUnique(
        _ locatorJSON: String,
        cssSelector: String?,
        receipt: EPUBLocatorCommandReceipt
    ) async -> Bool {
        guard
            !Task.isCancelled,
            isReceiptCurrent(receipt),
            let payload = try? EPUBLocatorCommandDecoder.decode(locatorJSON),
            let decoded = try? Locator(json: payload.locator)
        else {
            return false
        }
        let locator = publication.normalizeLocator(decoded)
        guard
            let readingOrderIndex = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(readingOrderIndex),
            let paginationView,
            paginationView.currentIndex == spreadIndex,
            let spreadView = paginationView.loadedViews[spreadIndex] as? EPUBSpreadView,
            spreadView.isCommandReady
        else {
            return false
        }
        let result = await spreadView.locatorCommandBridge.validateUniqueTextMatch(
            locatorJSON: locatorJSON,
            targetHREF: locator.href,
            cssSelector: cssSelector,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
        )
        guard !Task.isCancelled, isReceiptCurrent(receipt) else { return false }
        return result.outcome == .applied
    }

    /// Extracts a bounded visible excerpt through fixed source in the isolated
    /// content world. Publisher content is returned only to the local caller.
    public func extractVisibleText(maximumLength: Int) async -> String? {
        guard
            let paginationView,
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            spreadView.isCommandReady
        else {
            return nil
        }
        let targetHREF = currentLocation?.href ?? spreadView.spread.first.link.url()
        return await spreadView.locatorCommandBridge.visibleText(
            targetHREF: targetHREF,
            maximumLength: maximumLength,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
        )
    }

    private enum ReadySpreadWaitResult {
        case ready(EPUBSpreadView)
        case miss
        case cancelled
    }

    /// - Parameter deadline: the operation-wide deadline; this rung is bounded by the
    ///   smaller of its own cap and what remains of it.
    private func waitForReadySpread(
        at index: Int,
        deadline: EPUBLocatorOperationDeadline
    ) async -> ReadySpreadWaitResult {
        guard
            let paginationView,
            paginationView.currentIndex == index
        else {
            return .cancelled
        }

        guard let spreadView = await paginationView.waitForCurrentPage(at: index) as? EPUBSpreadView else {
            let targetIsCurrent = self.paginationView === paginationView
                && paginationView.currentIndex == index
            return Task.isCancelled || !targetIsCurrent ? .cancelled : .miss
        }

        // Bounded by the SMALLER of this rung's own cap and what is left of the
        // operation: the per-rung cap still limits a single stuck readiness wait,
        // but it can no longer extend a landing past the operation deadline.
        let readinessCap = locatorClock.now().advanced(
            by: EPUBSpreadReadiness.commandReadinessBudget
        )
        let readinessDeadline = deadline.effectiveDeadline(cappedBy: readinessCap)
        // Follow the DOCUMENT, not a fixed generation. Between reading readiness
        // here and the wait registering, the host can acquire a position or
        // decoration writer on a `.ready` spread — which advances the generation
        // while keeping the same frame document. A generation-keyed wait sees
        // that benign same-document mutation as `.invalidated` and reports the
        // whole landing `.cancelled`, so the tap does nothing: no fallback rung,
        // no logged failure. The document-keyed wait resumes on the successor
        // generation instead. Only when no document is live is there nothing to
        // follow, and the generation wait is the honest fallback.
        let outcome: EPUBSpreadReadiness.WaitOutcome
        if let capability = spreadView.readiness.currentFrameCapability {
            outcome = await spreadView.readiness.waitForCommandReadiness(
                forDocument: capability,
                until: readinessDeadline
            )
        } else {
            outcome = await spreadView.readiness.waitForCommandReadiness(
                for: spreadView.readiness.generation,
                until: readinessDeadline
            )
        }
        let targetIsCurrent = self.paginationView === paginationView
            && paginationView.currentIndex == index
            && paginationView.loadedViews[index] === spreadView
        // Currency is asked of the world the OUTCOME bound, matching
        // `EPUBLocatorCommandReceipt.isCurrent`.
        let documentIsCurrent = Self.readySpreadDocumentIsCurrent(
            for: outcome,
            currentCapability: spreadView.readiness.currentFrameCapability,
            currentGeneration: spreadView.readiness.generation
        )

        switch Self.readySpreadNavigationDisposition(
            for: outcome,
            targetIsCurrent: targetIsCurrent,
            documentIsCurrent: documentIsCurrent,
            taskIsCancelled: Task.isCancelled
        ) {
        case .landed:
            return .ready(spreadView)
        case .miss:
            return .miss
        case .cancelled:
            return .cancelled
        }
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
    }

    @discardableResult
    public func goForward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .right
            case .rtl:
                return .left
            }
        }()
        return await go(to: direction, options: options)
    }

    @discardableResult
    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .left
            case .rtl:
                return .right
            }
        }()
        return await go(to: direction, options: options)
    }

    // MARK: - SelectableNavigator

    public var currentSelection: Selection? {
        viewModel.editingActions.selection
    }

    public func clearSelection() {
        guard let paginationView = paginationView else {
            return
        }

        for (_, pageView) in paginationView.loadedViews {
            (pageView as? EPUBSpreadView)?.webView.clearSelection()
        }
    }

    // MARK: - DecorableNavigator

    private var decorations: [DecorationGroup: [DiffableDecoration]] = [:]

    /// Decoration group callbacks, indexed by the group name.
    private var decorationCallbacks: [DecorationGroup: [DecorableNavigator.OnActivatedCallback]] = [:]

    /// Serializes decoration replacement and cleanup within each group.
    private let decorationApplyTaskQueue = DecorationApplyTaskQueue()

    /// Serializes rapid locator requests with latest-request-wins semantics.
    private let locatorNavigationTaskQueue = EPUBLocatorNavigationTaskQueue()

    /// Monotonic count of locator navigations started on this navigator. A
    /// receipt captures the value current when its command landed, so a newer
    /// navigation starting is what makes every older receipt stale — which is
    /// how a predecessor paused between its landing and its decoration is
    /// stopped from acting after its successor has landed.
    private var locatorOperationSequence: UInt64 = 0

    /// The locator operation whose cross-resource hop is in flight, published for the
    /// target spread to read back when it initializes. The hop's spread loads on its own
    /// load event rather than from this call stack, so the deadline reaches it by pull.
    private let activeLocatorOperationSlot = EPUBActiveLocatorOperationSlot()

    /// The single monotonic source this authority mints deadlines from, measures
    /// remaining budget against, and sleeps on. One seam rather than a
    /// `ContinuousClock()` read per rung: scattered reads are individually correct
    /// but collectively unsubstitutable, so nothing below could be driven to its
    /// deadline in a test without waiting out the real budget.
    let locatorClock: EPUBMonotonicClock = .continuous

    /// The command bridge whose navigation is currently suspended in
    /// JavaScript. A superseding request's cancellation relay reads this to
    /// abort the predecessor in its own frame. Cleared only when the same
    /// bridge instance is still tracked, so a bounded-acknowledgement race
    /// never nils a newer request's bridge.
    private weak var inFlightLocatorBridge: EPUBLocatorCommandBridge?

    /// Runs the predecessor's cancellation relay: aborts its suspended
    /// JavaScript navigation so it acknowledges promptly. A no-op when no
    /// navigation is in flight.
    private func cancelInFlightLocatorNavigation() async {
        guard let bridge = inFlightLocatorBridge else {
            return
        }
        // Bounded by the supersession backstop rather than a command budget: this
        // relay exists to make the predecessor acknowledge promptly, and the
        // successor is already only willing to wait that long for it.
        await bridge.cancelInFlightNavigation(
            deadline: EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: EPUBLocatorNavigationTaskQueue.predecessorAcknowledgementBudget
            )
        )
    }

    /// The deadline for one whole decoration operation — an apply/rollback
    /// transaction, or a replay sweep — rather than one per affected resource.
    private func makeDecorationOperationDeadline() -> EPUBLocatorOperationDeadline {
        EPUBLocatorOperationDeadline(
            startingAt: locatorClock.now(),
            budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
        )
    }

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: DecorationGroup) {
        decorationApplyTaskQueue.submit(in: group) { [weak self] isSuperseding in
            guard let self else { return }
            await self.initialized()

            guard
                !Task.isCancelled,
                let paginationView = self.paginationView
            else {
                return
            }

            let source = self.decorations[group] ?? []
            let target = decorations.map {
                var d = $0
                d.locator = self.publication.normalizeLocator(d.locator)
                return DiffableDecoration(decoration: d)
            }
            let transaction = DecorationApplyTransaction(group: group, source: source, target: target)

            var affectedHREFs = Array(transaction.changesByHREF.keys)
            if transaction.target.isEmpty || isSuperseding {
                for (_, pageView) in paginationView.loadedViews {
                    guard let spreadView = pageView as? EPUBSpreadView else { continue }
                    for index in spreadView.spread.readingOrderIndices {
                        guard let href = self.readingOrder.getOrNil(index)?.url() else { continue }
                        if !affectedHREFs.contains(where: { $0.isEquivalentTo(href) }) {
                            affectedHREFs.append(href)
                        }
                    }
                }
            }

            let activable = !(self.decorationCallbacks[group] ?? []).isEmpty
            let decorationTemplates = self.config.decorationTemplates

            @MainActor
            func values(
                from decorations: [DiffableDecoration],
                for href: AnyURL
            ) -> [EPUBDecorationCommandItem]? {
                decorations
                    .filter { $0.decoration.locator.href.isEquivalentTo(href) }
                    .commandItems(styles: decorationTemplates)
            }

            // ONE deadline for the whole transaction — apply across every affected
            // resource plus any rollback — rather than one per resource. Minting per
            // command made a transaction's worst case the per-command budget times the
            // number of preloaded resources it touched, doubled again by rollback, with
            // no relationship to the frozen total.
            let deadline = self.makeDecorationOperationDeadline()
            // One readiness resolution per spread, shared by every HREF the
            // transaction touches on it and by rollback. Several HREFs can be backed
            // by ONE spread (a two-page fixed-layout spread is two), and re-deriving
            // per HREF accepted whatever document occupied the spread at that moment
            // — so a replacement mid-transaction let a later write land on a document
            // the transaction never checked while the earlier writes were lost with
            // the old one, and the transaction still committed as applied.
            let writeGate = EPUBDecorationWriteGate()
            let resourceTransaction = DecorationApplyResourceTransaction(resources: affectedHREFs)
            let didApply = await resourceTransaction.run(
                apply: { href in
                    guard let spreadView = self.loadedSpreadViewForHREF(href) else {
                        return true
                    }
                    switch writeGate.resolve(
                        spread: ObjectIdentifier(spreadView),
                        isCommandReady: spreadView.isCommandReady,
                        currentCapability: spreadView.readiness.currentFrameCapability
                    ) {
                    case .skip:
                        return true
                    case .documentReplaced:
                        return false
                    case .write:
                        break
                    }
                    guard let items = values(from: transaction.target, for: href) else {
                        self.log(.error, "Decoration command encoding failed")
                        return false
                    }
                    guard let writerLease = spreadView.readiness.acquirePositionWriter() else {
                        return false
                    }
                    defer { spreadView.readiness.release(writerLease) }

                    let result = await spreadView.locatorCommandBridge.replaceDecorations(
                        items,
                        in: group,
                        targetHREF: href,
                        activable: activable,
                        deadline: deadline
                    )
                    guard result.outcome == .applied else {
                        self.log(.warning, "Decoration command rejected reason=\(result.reason.rawValue)")
                        return false
                    }
                    return true
                },
                rollback: { href in
                    guard let spreadView = self.loadedSpreadViewForHREF(href) else {
                        return true
                    }
                    switch writeGate.resolve(
                        spread: ObjectIdentifier(spreadView),
                        isCommandReady: spreadView.isCommandReady,
                        currentCapability: spreadView.readiness.currentFrameCapability
                    ) {
                    case .skip:
                        return true
                    case .documentReplaced:
                        return false
                    case .write:
                        break
                    }
                    guard let items = values(from: source, for: href) else {
                        self.log(.error, "Decoration rollback encoding failed")
                        return false
                    }
                    guard let writerLease = spreadView.readiness.acquirePositionWriter() else {
                        return false
                    }
                    defer { spreadView.readiness.release(writerLease) }

                    let result = await spreadView.locatorCommandBridge.replaceDecorations(
                        items,
                        in: group,
                        targetHREF: href,
                        activable: activable,
                        deadline: deadline
                    )
                    guard result.outcome == .applied else {
                        self.log(.warning, "Decoration rollback rejected reason=\(result.reason.rawValue)")
                        return false
                    }
                    return true
                }
            )
            guard didApply else {
                return
            }
            transaction.commit(to: &self.decorations)
        }
    }

    public func observeDecorationInteractions(inGroup group: DecorationGroup, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        Task {
            await decorationApplyTaskQueue.replay(in: group) { [weak self] in
                guard let self else { return }
                await self.initialized()

                guard let paginationView = self.paginationView else { return }
                // One deadline for the whole sweep: it spans every loaded spread and
                // every reading-order index within each, so a per-command budget would
                // scale the sweep's cost with the preload window.
                let deadline = self.makeDecorationOperationDeadline()
                let committed = self.decorations[group] ?? []
                for (_, view) in paginationView.loadedViews {
                    guard let spreadView = view as? EPUBSpreadView else { continue }
                    for index in spreadView.spread.readingOrderIndices {
                        guard
                            let href = self.readingOrder.getOrNil(index)?.url(),
                            let items = committed
                            .filter({ $0.decoration.locator.href.isEquivalentTo(href) })
                            .commandItems(styles: self.config.decorationTemplates)
                        else {
                            continue
                        }
                        _ = await Self.runDecorationReplayWrite(
                            on: spreadView.readiness
                        ) {
                            _ = await spreadView.locatorCommandBridge.replaceDecorations(
                                items,
                                in: group,
                                targetHREF: href,
                                activable: true,
                                deadline: deadline
                            )
                        }
                    }
                }
            }
        }
    }

    /// Runs a decoration replay write under a generation-bound writer lease so
    /// re-applying committed decorations onto a live spread can never paint a
    /// superseded generation. Returns `false` without running `write` unless
    /// the spread currently publishes command readiness, mirroring the
    /// apply/rollback lease discipline. The `isCommandReady` gate runs before
    /// `acquirePositionWriter()` so a spread mid-initialization is skipped
    /// rather than joined as an additional writer.
    @MainActor
    static func runDecorationReplayWrite(
        on readiness: EPUBSpreadReadiness,
        _ write: @MainActor () async -> Void
    ) async -> Bool {
        guard
            readiness.isCommandReady,
            let lease = readiness.acquirePositionWriter()
        else {
            return false
        }
        defer { readiness.release(lease) }
        await write()
        return true
    }

    // MARK: - Configurable

    public var settings: EPUBSettings {
        viewModel.settings
    }

    public func submitPreferences(_ preferences: EPUBPreferences) {
        viewModel.submitPreferences(preferences)
        applySettings()

        delegate?.navigator(self, presentationDidChange: presentation)
    }

    /// Updates the anchor-target list and re-issues `initAnchorTracking`
    /// against every currently-loaded spread. Intended for the late-bind
    /// path: navigator construction may happen before the conformer's
    /// asynchronous anchor-list build completes, so spreads loaded with
    /// an empty cache need their anchor list re-pushed once the cache
    /// populates.
    ///
    /// Concurrent so multi-spread layouts (e.g., iPad split view) finish
    /// in roughly one round-trip instead of N sequential awaits. Per-
    /// spread failures (e.g., WebView process termination mid-call) are
    /// logged but do not abort the batch.
    public func updateVisibleAnchorTargets(_ targets: [String: [String]]) async {
        viewModel.updateVisibleAnchorTargets(targets)
        // Sendable-correct fan-out: capture only Sendable keys (AnyURL is
        // Sendable per Sources/Shared/Toolkit/URL/URLProtocol.swift; UIView
        // is NOT). Re-resolve the spread view inside the @MainActor task
        // body via the existing loadedSpreadViewForHREF<T: URLConvertible>(_:)
        // helper.
        let hrefs: [AnyURL] = (paginationView?.loadedViews ?? [:])
            .values.compactMap {
                ($0 as? EPUBSpreadView)?
                    .spread.first.link.url(relativeTo: viewModel.publicationBaseURL)
            }
        await withTaskGroup(of: Void.self) { group in
            for href in hrefs {
                group.addTask { @MainActor [weak self] in
                    guard let self,
                          let spread = self.loadedSpreadViewForHREF(href) else { return }
                    await self.reinjectAnchorTracking(into: spread)
                }
            }
        }
    }

    private func reinjectAnchorTracking(into spread: EPUBSpreadView) async {
        guard
            !Task.isCancelled,
            spread.isCommandReady,
            let writerLease = spread.readiness.acquirePositionWriter()
        else {
            return
        }
        defer { spread.readiness.release(writerLease) }
        let anchorIds = viewModel.anchorIds(forResourceAt: spread.spread.first.link.url(relativeTo: viewModel.publicationBaseURL)) ?? []
        guard anchorIds.count <= AnchorTrackingLimits.maxAnchorIdsPerResource else {
            log(.warning, "anchor tracking reinjection skipped: list size=\(anchorIds.count)")
            return
        }
        do {
            _ = try await spread.webView.callAsyncJavaScript(
                "readium.initAnchorTracking(anchorIds);",
                arguments: ["anchorIds": anchorIds],
                in: nil,
                contentWorld: .page
            )
        } catch is CancellationError {
            return
        } catch {
            let ns = error as NSError
            log(.warning, "anchor tracking reinjection failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
        }
    }

    public func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        viewModel.editor(of: preferences)
    }

    /// Applies user settings that require native configuration instead of
    /// CSS properties.
    private func applySettings() {
        guard isViewLoaded else {
            return
        }

        view.backgroundColor = settings.effectiveBackgroundColor.uiColor
        paginationView?.isScrollEnabled = isPaginationViewScrollingEnabled
    }

    // MARK: - EPUB-specific extensions

    /// Evaluates the given JavaScript on the currently visible HTML resource.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return .failure(EPUBError.spreadNotLoaded)
        }
        return await spreadView.evaluateScript(script)
    }

    // MARK: - UIAccessibilityAction

    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !super.accessibilityScroll(direction) else {
            return true
        }

        let options = NavigatorGoOptions(animated: false)

        Task {
            switch direction {
            case .right:
                await goLeft(options: options)
            case .left:
                await goRight(options: options)
            case .next, .down:
                await goForward(options: options)
            case .previous, .up:
                await goBackward(options: options)
            @unknown default:
                break
            }
        }
        return true
    }
}

extension EPUBNavigatorViewController: EPUBNavigatorViewModelDelegate {
    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {
        invalidatePaginationView()
    }

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, applyCSSSettings script: String) {
        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            // Each spread runs the CSS change as its own generation-bound,
            // latest-wins mutation. The call is fire-and-forget here: the spread
            // holds a readiness lease for the duration, so any subsequent
            // command awaits the reflow through the authority — there is nothing
            // for the fan-out to await.
            for (_, view) in paginationView.loadedViews {
                (view as? EPUBSpreadView)?.applyCSSSettings(script)
            }
        }
    }

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        DispatchQueue.main.async {
            self.delegate?.navigator(self, didFailToLoadResourceAt: href, withError: error)
        }
    }
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        if let inset = delegate?.navigatorContentInset(self) {
            return inset
        }

        // We use the window's safeAreaInsets instead of the view's because we
        // only want to take into account the device notch and status bar, not
        // the application's bars.
        var insets = view.window?.safeAreaInsets ?? .zero

        switch publication.metadata.epubLayout {
        case .fixed:
            // With iPadOS and macOS, we aim to display content edge-to-edge
            // since there are no physical notches or Dynamic Island like on the
            // iPhone.
            if UIDevice.current.userInterfaceIdiom != .phone {
                insets = .zero
            }

        case .reflowable:
            let configInset = config.contentInset(for: view.traitCollection.verticalSizeClass)
            insets.top = max(insets.top, configInset.top)
            insets.bottom = max(insets.bottom, configInset.bottom)
        }

        return insets
    }

    func spreadViewLocatorOperationDeadline(
        _ spreadView: EPUBSpreadView
    ) -> EPUBLocatorOperationDeadline? {
        activeLocatorOperationSlot.operationDeadline(for: spreadView.spread)
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {
        let links = spreadView.spread.readingOrderIndices
            .compactMap { readingOrder.getOrNil($0) }

        for group in Array(decorations.keys) {
            await decorationApplyTaskQueue.replay(in: group) { [weak self, weak spreadView] in
                guard let self, let spreadView else { return }
                // One deadline for this spread's whole replay, across all its links.
                let deadline = self.makeDecorationOperationDeadline()
                let committed = self.decorations[group] ?? []
                for link in links {
                    let href = link.url()
                    guard let items = committed
                        .filter({ $0.decoration.locator.href.isEquivalentTo(href) })
                        .commandItems(styles: self.config.decorationTemplates)
                    else {
                        continue
                    }
                    let result = await spreadView.locatorCommandBridge.replaceDecorations(
                        items,
                        in: group,
                        targetHREF: href,
                        activable: !(self.decorationCallbacks[group] ?? []).isEmpty,
                        deadline: deadline
                    )
                    if result.outcome != .applied {
                        self.log(.warning, "Initial decoration command rejected reason=\(result.reason.rawValue)")
                    }
                }
            }
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {
        Task {
            var event = event
            event.location = view.convert(event.location, from: spreadView)
            if let targetElement = event.targetElement {
                event.targetElement?.frame = view.convert(targetElement.frame, from: spreadView)
            }
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {
        Task {
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        guard state == .idle else { return }

        delegate?.navigator(self, presentExternalURL: url)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        guard
            let url = AnyURL(string: href),
            var link = publication.linkWithHREF(url)
        else {
            log(.warning, "Cannot find link with HREF: \(href)")
            return
        }
        link.href = href

        Task {
            // Check to see if this was a noteref link and give delegate the
            // opportunity to display it.
            if
                let clickEvent = clickEvent,
                let interactive = clickEvent.interactiveElement,
                let (note, referrer) = await getNoteData(anchor: interactive, href: href),
                let delegate = delegate
            {
                if !delegate.navigator(
                    self,
                    shouldNavigateToNoteAt: link,
                    content: note,
                    referrer: referrer
                ) {
                    return
                }
            }

            // Ask if we should navigate to the link
            if let delegate = delegate, !delegate.navigator(self, shouldNavigateToLink: link) {
                return
            }

            await go(to: link)
        }
    }

    /// Checks if the internal link is a noteref, and retrieves both the referring text of the link and the body of the note.
    ///
    /// Uses the navigation href from didTapOnInternalLink because it is normalized to a path within the book,
    /// whereas the anchor tag may have just a hash fragment like `#abc123` which is hard to work with.
    /// We do at least validate to ensure that the two hrefs match.
    ///
    /// Uses `#id` when retrieving the body of the note, not `aside#id` because it may be a `<section>`.
    /// See https://idpf.github.io/epub-vocabs/structure/#footnotes
    /// and http://kb.daisy.org/publishing/docs/html/epub-type.html#ex
    func getNoteData(anchor: String, href: String) async -> (String, String)? {
        do {
            let doc = try parse(anchor)
            guard let link = try doc.select("a[epub:type=noteref]").first() else { return nil }

            let anchorHref = try link.attr("href")
            guard href.hasSuffix(anchorHref) else { return nil }

            guard
                let url = AnyURL(string: href),
                let id = url.fragment
            else {
                log(.warning, "Could not find hash in link \(href)")
                return nil
            }

            // Read the note's resource through the publication's resource API.
            guard let resource = publication.get(url.removingFragment()) else {
                log(.warning, "Could not open note resource: \(href)")
                return nil
            }
            let contents = try await resource.read().asString().get()
            let document = try parse(contents)

            guard let aside = try document.select("#\(id)").first() else {
                log(.warning, "Could not find the element '#\(id)' in document \(href)")
                return nil
            }

            return try (aside.html(), link.html())

        } catch {
            log(.warning, "Caught error while getting note content: \(error)")
            return nil
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {
        guard
            let callbacks = decorationCallbacks[group].takeIf({ !$0.isEmpty }),
            let decoration: Decoration = decorations[group]?
            .first(where: { $0.decoration.id == id })
            .map(\.decoration)
        else {
            return
        }

        for callback in callbacks {
            callback(OnDecorationActivatedEvent(decoration: decoration, group: group, rect: frame, point: point))
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?) {
        delegate?.navigator(self, didActivateImageAt: url, altText: altText, caption: caption, attribution: attribution)
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect, domRange: DOMRange?) {
        guard
            let locator = currentLocation,
            let text = text
        else {
            viewModel.editingActions.selection = nil
            return
        }

        // Create the selection locator, including domRange in otherLocations if available
        let selectionLocator = locator.copy(
            locations: { locations in
                if let domRange = domRange {
                    locations = locations.adding("domRange", value: domRange.jsonValue)
                }
            },
            text: { $0 = text }
        )

        viewModel.editingActions.selection = Selection(
            locator: selectionLocator,
            frame: frame
        )
    }

    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if paginationView?.currentView == spreadView {
            updateCurrentLocation()
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadViewDidTerminate() {
        reloadSpreads()
    }

    /// Forwards the JS-side anchor change to the host's
    /// `VisibleAnchorObservingNavigatorDelegate`, packaged as a `VisibleAnchor`
    /// keyed on the spread's resource href.
    func spreadView(_ spreadView: EPUBSpreadView, visibleAnchorDidChange anchorId: String) {
        let link = spreadView.spread.first.link
        let href = link.url(relativeTo: viewModel.publicationBaseURL)
        delegate?.navigator(self, didChangeVisibleAnchor: VisibleAnchor(href: href, fragmentId: anchorId))
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        delegate?.navigator(self, shouldShowMenuForSelection: selection) ?? true
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        delegate?.navigator(self, canPerformAction: action, for: selection) ?? true
    }
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
        let spread = spreads[index]
        let spreadViewType = (publication.metadata.layout == .fixed) ? EPUBFixedSpreadView.self : EPUBReflowableSpreadView.self
        let spreadView = spreadViewType.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [],
            animatedLoad: false
        )
        spreadView.delegate = self

        let userContentController = spreadView.webView.configuration.userContentController
        delegate?.navigator(self, setupUserScripts: userContentController)

        return spreadView
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        // Note that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first
        // invocation.
        updateCurrentLocation()
    }

    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int {
        spreads[index].positionCount(in: readingOrder, positionsByReadingOrder: positionsByReadingOrder)
    }
}

// Compiled ONLY under `RENDER_FAITHFUL_NAV_TESTING` (see `Package.swift`). The
// `@_spi(Testing)` annotation below governs who may import these; it does NOT keep
// them out of a shipping binary, which is what this condition is for. Every hook here
// is phase-only — opaque UUIDs and Booleans — so nothing derived from book content,
// hrefs, selectors, or geometry can cross the seam even where it IS compiled.
#if RENDER_FAITHFUL_NAV_TESTING
    @_spi(Testing)
    public extension EPUBNavigatorViewController {
        /// Test-only: the frame-capability UUIDs the current spread's readiness
        /// authority and locator command bridge each hold. Proves `spreadDidLoad`
        /// hands ONE capability to both authorities — a mismatch would mean a frame
        /// that echoes the injected capability could never be selected by the bridge
        /// registry, so a landed command would be impossible. Returns `nil` when no
        /// spread is current. Content-free: only opaque UUIDs cross the seam.
        var currentSpreadFrameCapabilityIDsForTesting: (readiness: UUID?, bridge: UUID?)? {
            guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
                return nil
            }
            return (
                spreadView.readiness.currentFrameCapability?.id,
                spreadView.locatorCommandBridge.currentFrameCapability?.id
            )
        }

        /// Test-only: whether the current spread is a fixed-layout (pre-paginated)
        /// spread, which loads its resource inside a child iframe of a wrapper main
        /// frame. Lets a test prove it is exercising the wrapper→child capability
        /// forwarding path rather than a silently reflowable resource. `nil` when no
        /// spread is current.
        var currentSpreadIsFixedLayoutForTesting: Bool? {
            guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
                return nil
            }
            return spreadView is EPUBFixedSpreadView
        }

        /// Test-only: awaits the point at which the current spread's initialization
        /// becomes idle — command readiness published for the LATEST generation of
        /// the same frame document, with every generation-bound position/layout
        /// writer released.
        ///
        /// A precise landing is only trustworthy if it survives the writers that
        /// were still in flight when it returned. Because a same-document mutation
        /// (a font/stylesheet settle, a pending progression apply, a relayout offset
        /// correction) advances the generation while retaining the frame capability,
        /// this follows the DOCUMENT rather than a fixed generation and resolves on
        /// the last one to publish. That lets a test re-verify a landing's visibility
        /// against a deterministic lifecycle gate instead of a sleep.
        ///
        /// Returns `false` when no spread is current, when the document holds no
        /// capability, or when the document was replaced/invalidated before readiness
        /// republished. Content-free: only a Boolean crosses the seam.
        func awaitCurrentSpreadDocumentIdleForTesting() async -> Bool {
            guard let spreadView = paginationView?.currentView as? EPUBSpreadView,
                  let capability = spreadView.readiness.currentFrameCapability
            else {
                return false
            }
            // Bounded deliberately. The document-scoped wait loops while the capability
            // survives, re-waiting on each successor generation — so a document whose
            // generation keeps advancing (exactly the font/stylesheet/progression churn
            // this probe exists to wait out) would never return. Unbounded, that is a suite
            // HANG rather than a failure: no assertion message, no diagnostic, the whole run
            // dies. The deadline converts that into an ordinary `false`.
            let deadline = EPUBLocatorOperationDeadline(
                startingAt: locatorClock.now(),
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
            guard case .ready = await spreadView.readiness.waitForCommandReadiness(
                forDocument: capability,
                until: deadline.expiresAt
            ) else {
                return false
            }
            return true
        }
    }
#endif
