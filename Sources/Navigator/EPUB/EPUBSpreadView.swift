//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
@preconcurrency import WebKit

protocol EPUBSpreadViewDelegate: AnyObject {
    /// Returns the content inset the spread view should use.
    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets

    /// Called when the spread view finished loading.
    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async

    /// Called when the user tapped on an external link.
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL)

    /// Called when the user tapped on an internal link.
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?)

    /// Called when the user tapped on a decoration.
    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?)

    /// Called when the user tapped on an image for zooming.
    func spreadView(_ spreadView: EPUBSpreadView, didActivateImageAt url: URL, altText: String?, caption: String?, attribution: String?)

    /// Called when the text selection changes.
    /// - Parameters:
    ///   - text: The selected text with context
    ///   - frame: The bounding rectangle of the selection
    ///   - domRange: The DOM range for anchoring highlights (optional)
    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect, domRange: DOMRange?)

    /// Called when the pages visible in the spread changed.
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView)

    /// Called when the spread view needs to present a view controller.
    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController)

    /// Called when the user triggered an input pointer event.
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent)

    /// Called when the user triggered an input key event.
    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent)

    /// Called when WKWebview terminates
    func spreadViewDidTerminate()

    /// Called when the IntersectionObserver in the spread reports a new anchor
    /// crossing the viewport top.
    func spreadView(_ spreadView: EPUBSpreadView, visibleAnchorDidChange anchorId: String)

    /// The deadline of the locator operation whose cross-resource hop this spread is
    /// the target of, or nil for every other load.
    ///
    /// A pull rather than a push: a spread initializes on its own load event, not from
    /// the call stack of the navigation that asked for it, so the operation's deadline
    /// cannot be handed down to it. Asking at the point stabilization starts is what
    /// lets a hop spend the operation's REMAINDER instead of minting a fresh allowance
    /// on top of it.
    func spreadViewLocatorOperationDeadline(
        _ spreadView: EPUBSpreadView
    ) -> EPUBLocatorOperationDeadline?
}

extension EPUBSpreadViewDelegate {
    func spreadView(_ spreadView: EPUBSpreadView, visibleAnchorDidChange anchorId: String) {}

    func spreadViewLocatorOperationDeadline(
        _ spreadView: EPUBSpreadView
    ) -> EPUBLocatorOperationDeadline? {
        nil
    }
}

class EPUBSpreadView: UIView, Loggable, PageView {
    weak var delegate: EPUBSpreadViewDelegate?
    let viewModel: EPUBNavigatorViewModel
    let spread: EPUBSpread
    private(set) var focusedResource: ReadingOrder.Index?

    let webView: WebView
    let locatorCommandBridge: EPUBLocatorCommandBridge

    private var lastClick: ClickEvent?

    /// If YES, the content will be faded in once loaded.
    let animatedLoad: Bool

    weak var activityIndicatorView: UIActivityIndicatorView?
    private var activityIndicatorStopWorkItem: DispatchWorkItem?

    /// Sole authority for this spread's render generation and position
    /// writers. Document availability and external command readiness are
    /// intentionally separate states.
    let readiness = EPUBSpreadReadiness()
    private var spreadLoadTask: Task<Void, Never>?

    /// Latest runtime CSS settings, replayed newest-wins if a rapid sequence
    /// (e.g. a font-size slider drag) arrives while one apply is in flight.
    /// `nil` is the never-applied initial value.
    private let pendingCSSMutation = EPUBLatestMutation<String?>(initialValue: nil)
    private var cssMutationTask: Task<Void, Never>?

    private struct MainFrameNavigationRecord {
        let navigation: WKNavigation
        let generation: EPUBSpreadReadiness.Generation
    }

    private struct IssuingMainFrameNavigation {
        let generation: EPUBSpreadReadiness.Generation
        var provisionalNavigation: WKNavigation?
    }

    private var currentMainFrameNavigation: MainFrameNavigationRecord?
    private var issuingMainFrameNavigation: IssuingMainFrameNavigation?

    var isCommandReady: Bool {
        readiness.isCommandReady
    }

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        self.viewModel = viewModel
        self.spread = spread
        self.animatedLoad = animatedLoad

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(viewModel.server, forURLScheme: viewModel.server.scheme)
        config.mediaTypesRequiringUserActionForPlayback = .all

        let locatorCommandBridge = EPUBLocatorCommandBridge(
            layout: viewModel.publication.metadata.layout == .fixed ? .fixed : .reflowable,
            publicationBaseURL: viewModel.publicationBaseURL
        )
        locatorCommandBridge.install(in: config)
        self.locatorCommandBridge = locatorCommandBridge

        // Disable the Apple Intelligence Writing tools in the web views.
        // See https://github.com/readium/swift-toolkit/issues/509#issuecomment-2577780749
        if #available(iOS 18.0, *) {
            config.writingToolsBehavior = .none
        }

        webView = WebView(editingActions: viewModel.editingActions, configuration: config)
        locatorCommandBridge.attach(to: webView)

        super.init(frame: .zero)
        locatorCommandBridge.onDecorationActivated = { [weak self] body in
            self?.decorationDidActivate(body)
        }

        isOpaque = false
        backgroundColor = .clear

        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
        setupWebView()

        for script in scripts {
            webView.configuration.userContentController.addUserScript(script)
        }
        registerJSMessages()

        NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)

        updateActivityIndicator()
        loadSpread()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        clear()
    }

    /// Called when the spread view is removed from the view hierarchy, to
    /// clear pending operations and retain cycles.
    func clear() {
        webView.stopLoading()

        spreadLoadTask?.cancel()
        spreadLoadTask = nil
        cssMutationTask?.cancel()
        cssMutationTask = nil
        readiness.invalidate()

        // Revoke the frame capability and drop all frame registration so a
        // delayed, reloaded, or self-navigated document can never register or be
        // selected as the command target after this spread is torn down.
        locatorCommandBridge.revokeFrameCapability()

        // Disable JS messages to break WKUserContentController reference.
        disableJSMessages()
        locatorCommandBridge.disableMessageHandler()
    }

    func setupWebView() {
        scrollView.alpha = 0

        webView.backgroundColor = UIColor.clear
        scrollView.backgroundColor = UIColor.clear

        webView.allowsBackForwardNavigationGestures = false

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        // Prevents the pages from jumping down when the status bar is toggled
        scrollView.contentInsetAdjustmentBehavior = .never

        webView.navigationDelegate = self
        webView.uiDelegate = self
        scrollView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var scrollView: UIScrollView {
        webView.scrollView
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            clear()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        if superview != nil {
            enableJSMessages()
            locatorCommandBridge.enableMessageHandler()
            scrollView.delegate = self
        }
    }

    func loadSpread() {
        fatalError("loadSpread() must be implemented in subclasses")
    }

    /// Starts the generation before issuing an owned main-frame load. WebKit's
    /// provisional-navigation callback then validates and associates the
    /// returned navigation identity without advancing the generation again.
    @discardableResult
    func issueMainFrameLoad(
        _ operation: () -> WKNavigation?
    ) -> WKNavigation? {
        let generation = beginMainFrameLoading()
        issuingMainFrameNavigation = IssuingMainFrameNavigation(
            generation: generation,
            provisionalNavigation: nil
        )

        let navigation = operation()
        let provisionalNavigation = issuingMainFrameNavigation?.provisionalNavigation
        issuingMainFrameNavigation = nil

        guard
            let navigation,
            provisionalNavigation == nil || provisionalNavigation === navigation
        else {
            if readiness.fail(ifCurrent: generation) {
                locatorCommandBridge.invalidateDocument()
            }
            return navigation
        }

        registerMainFrameNavigation(navigation, generation: generation)
        return navigation
    }

    /// Called synchronously whenever a main-frame generation starts.
    func mainFrameLoadDidBegin(_ generation: EPUBSpreadReadiness.Generation) {}

    func currentMainFrameGeneration(
        for navigation: WKNavigation?
    ) -> EPUBSpreadReadiness.Generation? {
        guard
            let navigation,
            let record = currentMainFrameNavigation,
            record.navigation === navigation,
            record.generation == readiness.generation
        else {
            return nil
        }
        return record.generation
    }

    private func beginMainFrameLoading() -> EPUBSpreadReadiness.Generation {
        spreadLoadTask?.cancel()
        spreadLoadTask = nil
        let generation = readiness.beginLoading()
        locatorCommandBridge.beginDocument()
        mainFrameLoadDidBegin(generation)
        return generation
    }

    private func registerMainFrameNavigation(
        _ navigation: WKNavigation,
        generation: EPUBSpreadReadiness.Generation
    ) {
        currentMainFrameNavigation = MainFrameNavigationRecord(
            navigation: navigation,
            generation: generation
        )
    }

    /// Evaluates the given JavaScript into the resource's HTML page.
    @discardableResult
    func evaluateScript(_ script: String, inHREF href: AnyURL? = nil) async -> Result<Any, Error> {
        let generation = readiness.generation
        guard case .ready = await readiness.waitForCommandReadiness(for: generation) else {
            return .failure(CancellationError())
        }

        return await evaluateDocumentScript(script, inHREF: href)
    }

    /// Evaluates during initialization after the frame document exists, but
    /// before external command readiness is published.
    @discardableResult
    func evaluateDocumentScript(
        _ script: String,
        inHREF href: AnyURL? = nil
    ) async -> Result<Any, Error> {
        let generation = readiness.generation
        guard case .documentAvailable = await readiness.waitForDocumentAvailability(for: generation) else {
            return .failure(CancellationError())
        }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { [weak self] res, error in
                if let error = error {
                    let ns = error as NSError
                    self?.log(.error, "JavaScript evaluation failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(res ?? ()))
                }
            }
        }
    }

    /// Called from the JS code when logging a message.
    private func didLog(_ body: Any) {
        guard let body = body as? String else {
            return
        }
        log(.debug, "JavaScript: \(body)")
    }

    /// Called from the JS code when logging an error.
    private func didLogError(_ body: Any) {
        guard let error = body as? [String: Any],
              var message = error["message"] as? String
        else {
            return
        }
        message = "JavaScript: \(message)"

        if let file = error["filename"] as? String, file != "/",
           let line = error["line"] as? Int, line != 0
        {
            log(.error, message, file: file, line: line)
        } else {
            log(.error, message)
        }
    }

    /// Called from the JS code when a tap is detected.
    /// If the JS indicates the tap is being handled within the webview, don't take action,
    /// just save the tap data for use by webView(_ webView:decidePolicyFor:decisionHandler:)
    private func didTap(_ data: Any) {
        guard let clickEvent = ClickEvent(json: data) else {
            return
        }
        lastClick = clickEvent
    }

    /// Called from the JS code when receiving a pointer event.
    private func didReceivePointerEvent(_ data: Any) {
        guard
            let json = data as? [String: Any],
            // FIXME: Really needed?
            let defaultPrevented = json["defaultPrevented"] as? Bool,
            !defaultPrevented,
            // Ignores events on interactive elements
            (json["interactiveElement"] as? String) == nil,
            var event = PointerEvent(json: json)
        else {
            return
        }

        event.location = convertPointToNavigatorSpace(event.location)

        if let targetElement = targetElement(from: json["targetElement"]) {
            event.targetElement = targetElement
        }

        delegate?.spreadView(self, didReceive: event)
    }

    /// Parses the target element JSON produced by `extractTargetElement()` in
    /// gestures.js and builds a `PointerEvent.TargetElement` with coordinates
    /// converted to the spread view's coordinate space.
    private func targetElement(from json: Any?) -> PointerEvent.TargetElement? {
        guard
            let dict = json as? [String: Any],
            let frameDict = dict["frame"] as? [String: Any],
            let x = frameDict["x"] as? Double,
            let y = frameDict["y"] as? Double,
            let width = frameDict["width"] as? Double,
            let height = frameDict["height"] as? Double
        else {
            return nil
        }

        let frame = convertRectToNavigatorSpace(
            CGRect(x: x, y: y, width: width, height: height)
        )

        // In a two-page FXL spread both resources are loaded in separate
        // iframes, so we use `resourceHref` to identify the correct reading
        // order resource.
        let link = (dict["resourceHref"] as? String)
            .flatMap { AnyURL(string: $0) }
            .flatMap { spread.linkWithHREF($0) }
        guard let link else { return nil }

        // Build a locator pointing to the element inside the resource that
        // contains it.
        var locator = Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .xhtml
        )
        if let cssSelector = dict["cssSelector"] as? String {
            locator.locations.cssSelector = cssSelector
        }

        guard let content = contentElement(locator: locator, json: dict) else {
            return nil
        }
        return PointerEvent.TargetElement(frame: frame, content: content)
    }

    private func contentElement(
        locator: Locator,
        json: [String: Any]
    ) -> (any ContentElement)? {
        guard let tag = json["tag"] as? String else {
            return nil
        }

        // Relativize the src URL against the publication base URL so it
        // becomes a publication-relative href. External URLs (http://) or
        // already-relative URLs fall back to the raw value.
        let src: AnyURL? = (json["src"] as? String)
            .flatMap { AnyURL(string: $0) }
            .flatMap { viewModel.publicationBaseURL.relativize($0)?.anyURL ?? $0 }

        // Look up the Link in the publication manifest so the client gets full
        // metadata (media type, etc.). For resources not in the manifest (e.g.
        // external http:// images) we synthesise a plain Link.
        let embeddedLink: Link? = src.flatMap {
            viewModel.publication.linkWithHREF($0) ?? Link(href: $0.string)
        }

        var attributes: [ContentAttribute] = []
        if let label = json["accessibilityLabel"] as? String, !label.isEmpty {
            attributes.append(ContentAttribute(key: .accessibilityLabel, value: label))
        }
        let caption = json["caption"] as? String

        if let embeddedLink {
            switch tag {
            case "img", "svg":
                return ImageContentElement(
                    locator: locator,
                    embeddedLink: embeddedLink,
                    caption: caption,
                    attributes: attributes
                )
            default:
                break
            }
        }

        // Inline SVG fallback.
        if tag == "svg", let html = json["html"] as? String {
            return SVGContentElement(
                locator: locator,
                svg: html,
                caption: caption,
                attributes: attributes
            )
        }

        return nil
    }

    /// Converts the given JavaScript point into a point in the webview's coordinate space.
    func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        // To override in subclasses.
        point
    }

    /// Converts the given JavaScript rect into a rect in the webview's coordinate space.
    func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        // To override in subclasses.
        rect
    }

    // We override the UIResponder touches callbacks to handle taps around the
    // web view.

    override open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        on(.down, touches: touches, event: event)
    }

    override open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        on(.move, touches: touches, event: event)
    }

    override open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        on(.cancel, touches: touches, event: event)
    }

    override open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        on(.up, touches: touches, event: event)
    }

    private func on(_ phase: PointerEvent.Phase, touches: Set<UITouch>, event: UIEvent?) {
        for touch in touches {
            delegate?.spreadView(self, didReceive: PointerEvent(
                pointer: Pointer(touch: touch, event: event),
                phase: phase,
                location: touch.location(in: self),
                modifiers: KeyModifiers(event: event)
            ))
        }
    }

    private func spreadLoadDidStart(_ body: Any) {}

    /// Called by the javascript code when the spread contents is fully loaded.
    /// The JS message `spreadLoaded` needs to be emitted by a subclass script, EPUBSpreadView's scripts don't.
    private func spreadDidLoad(_ body: Any) {
        let generation = readiness.generation
        let frameCapability = EPUBSpreadFrameCapability()
        guard let rootLease = readiness.beginInitialization(
            for: generation,
            frameCapability: frameCapability
        ) else {
            return
        }

        // Unify the readiness authority's capability with the command bridge's:
        // the same token gates both spread reveal and frame registration. The
        // bridge injects it into the main frame's current document; reflowable
        // content registers directly, while a fixed-layout wrapper forwards it one
        // hop to its child resource frame. Either way, only the current document
        // (or the child it delegates to) — never a delayed old instance, same-URL
        // reload, or nested frame — can echo it back and register as the target.
        locatorCommandBridge.setFrameCapability(frameCapability)

        spreadLoadTask?.cancel()

        spreadLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            applySettings()
            let outcome = await initializeSpread()
            readiness.finishInitialization(
                rootLease,
                outcome: Task.isCancelled ? .failed : outcome
            )

            // The reveal path below keys on the frame-DOCUMENT capability, not
            // on the load generation: a position writer acquired the instant
            // readiness publishes (a precise locator landing racing this task's
            // suspensions) legitimately advances the generation while keeping
            // the same document. Requiring the original generation here left
            // the spread permanently hidden (scrollView at alpha 0, activity
            // indicator spinning) whenever such a command interleaved. Only a
            // replacement load, invalidation, or failure — which clear or
            // replace the capability — may keep the spread hidden.
            guard
                !Task.isCancelled,
                case .ready = await readiness.waitForCommandReadiness(
                    forDocument: frameCapability
                )
            else {
                return
            }

            await delegate?.spreadViewDidLoad(self)
            guard
                !Task.isCancelled,
                readiness.currentFrameCapability == frameCapability
            else {
                return
            }
            showSpread()
        }
    }

    /// To be overriden to customize the behavior after the spread is loaded.
    func initializeSpread() async -> EPUBSpreadReadiness.InitializationOutcome {
        .succeeded
    }

    /// The single instant this spread's stylesheet, font and geometry stabilization
    /// must be finished by.
    ///
    /// When the load is a locator operation's cross-resource hop, this is the earlier
    /// of the operation's remaining budget and the stage's own cap, so a landing costs
    /// the operation's budget rather than that budget once per resource it passes
    /// through. Every other load — an ordinary page turn, a settings re-layout, a
    /// PRELOADED NEIGHBOUR initializing during someone else's operation — keeps its own
    /// full allowance.
    func resolveInitializationStabilityDeadline() -> ContinuousClock.Instant {
        EPUBInitializationStabilityInheritance.resolve(
            ownCap: EPUBSpreadReadiness.makeInitializationStabilityDeadline(),
            inheritedFrom: delegate?.spreadViewLocatorOperationDeadline(self)
        )
    }

    func showSpread() {
        activityIndicatorView?.stopAnimating()
        activityIndicatorStopWorkItem?.cancel()
        UIView.animate(withDuration: animatedLoad ? 0.3 : 0, animations: {
            self.scrollView.alpha = 1
        })
    }

    /// Called by the JavaScript layer when the user selection changed.
    private func selectionDidChange(_ body: Any) {
        if body is NSNull {
            focusedResource = nil
            delegate?.spreadView(self, selectionDidChange: nil, frame: .zero, domRange: nil)
            return
        }

        guard
            let selection = body as? [String: Any],
            let hrefString = selection["href"] as? String,
            let href = AnyURL(string: hrefString),
            let text = try? Locator.Text(json: JSONValue(selection["text"])),
            var frame = CGRect(json: selection["rect"])
        else {
            focusedResource = nil
            delegate?.spreadView(self, selectionDidChange: nil, frame: .zero, domRange: nil)
            log(.warning, "Invalid body for selectionDidChange: \(body)")
            return
        }

        // Parse domRange from JavaScript (optional, used for precise highlight anchoring)
        let domRange: DOMRange?
        do {
            domRange = try DOMRange(json: JSONValue(selection["domRange"]))
        } catch {
            log(.debug, "Failed to parse domRange: \(error)")
            domRange = nil
        }

        focusedResource = viewModel.readingOrder.firstIndexWithHREF(href)
        frame.origin = convertPointToNavigatorSpace(frame.origin)
        delegate?.spreadView(self, selectionDidChange: text, frame: frame, domRange: domRange)
    }

    /// Update webview style to userSettings.
    /// To override in subclasses.
    func applySettings() {
        assert(Thread.isMainThread, "User settings must be updated from the main thread")
    }

    /// Applies a runtime CSS settings change (font family, theme, font size,
    /// publisher styles) as a generation-bound, latest-wins same-document
    /// mutation. Acquiring a position writer transitions the spread
    /// ready → initializing → ready in a new generation, so an in-flight precise
    /// landing is superseded rather than racing the reflow, and any later
    /// command awaits the settle through command readiness. Rapid changes
    /// coalesce newest-wins — the view model sends the FULL property snapshot,
    /// so coalescing never drops an earlier change's properties.
    ///
    /// A spread that is still loading applies the change once it publishes
    /// command readiness (its load generation resolves to `.ready` unchanged),
    /// so an offscreen neighbor mid-load is not left on stale CSS. A terminal or
    /// replaced document (a reload, invalidation, or failure supersedes it)
    /// drops out.
    func applyCSSSettings(_ script: String) {
        pendingCSSMutation.update(script)
        let predecessor = cssMutationTask
        predecessor?.cancel()
        cssMutationTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }

            if !self.readiness.isCommandReady {
                guard case .ready = await self.readiness.waitForCommandReadiness(
                    for: self.readiness.generation
                ) else {
                    return
                }
            }
            guard
                !Task.isCancelled,
                let writerLease = self.readiness.acquirePositionWriter()
            else {
                return
            }

            let succeeded = await self.pendingCSSMutation.applyLatest { latest in
                guard let latest else { return true }
                return await self.applyCSSScript(latest)
            }
            self.readiness.finishMutation(
                writerLease,
                outcome: Self.cssMutationOutcome(
                    succeeded: succeeded,
                    cancelled: Task.isCancelled
                )
            )
        }
    }

    /// Maps a CSS settings mutation's apply result to a readiness outcome. A
    /// cancelled mutation is a supersession — a newer settings change or a
    /// teardown replaced it — so it releases its lease cleanly and the document
    /// stays command-ready; only a genuine, non-cancelled apply failure revokes
    /// it. Success takes precedence over a late cancellation. Mirrors the
    /// extract-and-pin shape of `readinessGateDisposition`.
    static func cssMutationOutcome(
        succeeded: Bool,
        cancelled: Bool
    ) -> EPUBSpreadReadiness.MutationOutcome {
        if succeeded {
            return .succeeded
        } else if cancelled {
            return .superseded
        } else {
            return .failed
        }
    }

    /// Applies the CSS settings script into the live document, returning whether
    /// it succeeded. The reflowable spread overrides this to also await the
    /// resulting layout reflow, so command readiness is not republished until
    /// the new geometry settles. Fixed-layout content does not reflow on these
    /// properties, so the base implementation returns as soon as the write
    /// lands.
    func applyCSSScript(_ script: String) async -> Bool {
        guard case .success = await evaluateDocumentScript(script) else {
            return false
        }
        return true
    }

    /// A user drag takes over positioning; any in-flight precise navigation or
    /// page-turn command must yield so no programmatic scroll fights the
    /// gesture. Overridden by the reflowable spread, whose position commands
    /// scroll. Fixed-layout content is fully visible and runs no scrolling
    /// command (its only user gesture is zoom, which moves no command), so the
    /// base is a no-op.
    func cancelInFlightCommandForUserInteraction() {}

    // MARK: - Location and progression.

    /// Current progression in the resource with given href.
    func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        // To be overridden in subclasses if the resource supports a progression.
        0 ... 1
    }

    func go(to location: PageLocation, animated: Bool) async -> PageCommandOutcome {
        fatalError("go(to:) must be implemented in subclasses")
    }

    enum Direction: CustomStringConvertible {
        case left
        case right

        var description: String {
            switch self {
            case .left: return "left"
            case .right: return "right"
            }
        }
    }

    enum PageTurnOutcome: Equatable, Sendable {
        case succeeded
        case boundary
        case failed
        case cancelled
    }

    /// Pure disposition for a spread-level readiness gate — a `go`/page-turn
    /// that awaits command readiness before writing geometry.
    enum ReadinessGateDisposition: Equatable {
        /// The document is command-ready; the caller may write geometry.
        case proceed
        /// The wait was interrupted: caller cancellation, or a stale-lifecycle
        /// `.invalidated` (the generation advanced under the wait via teardown,
        /// reload, or replacement). The caller must NOT run a fallback.
        case cancelled
        /// A genuine, non-lifecycle failure.
        case failed
    }

    /// Maps a command-readiness wait outcome to a gate disposition. A
    /// stale-lifecycle `.invalidated` maps to `.cancelled`, NOT `.failed`, so a
    /// caller's progression / cross-resource fallback never fights a reader
    /// interruption (teardown, reload, replacement). This mirrors the
    /// controller-level `readySpreadNavigationDisposition`; keeping the two
    /// layers in agreement is the point. A genuine `.failed`, a `.timedOut`, or
    /// an unexpected `.documentAvailable` at a command gate stays a failure.
    static func readinessGateDisposition(
        for outcome: EPUBSpreadReadiness.WaitOutcome
    ) -> ReadinessGateDisposition {
        switch outcome {
        case .ready:
            return .proceed
        case .cancelled, .invalidated:
            return .cancelled
        case .documentAvailable, .timedOut, .failed:
            return .failed
        }
    }

    func go(
        to direction: Direction,
        options: NavigatorGoOptions
    ) async -> PageTurnOutcome {
        // The default implementation of a spread view considers that its content is entirely visible on screen.
        .boundary
    }

    func findFirstVisibleElementLocator() async -> Locator? {
        let result = await evaluateScript("readium.findFirstVisibleLocator()")
        do {
            let link = spread.first.link

            guard
                let json = try JSONValue(result.get()),
                let locator = try Locator(json: json)
            else {
                return nil
            }
            return locator.copy(href: link.url(), mediaType: link.mediaType ?? .xhtml)

        } catch {
            log(.error, "Visible locator decoding failed")
            return nil
        }
    }

    // MARK: - JS Messages

    private var JSMessages: [String: (Any) -> Void] = [:]
    private var JSMessagesEnabled = false

    /// Register a new JS message handler to be emitted from scripts.
    func registerJSMessage(named name: String, handler: @escaping (Any) -> Void) {
        guard JSMessages[name] == nil else {
            log(.error, "JS message already registered: \(name)")
            return
        }

        JSMessages[name] = handler
        if JSMessagesEnabled {
            webView.configuration.userContentController.add(self, name: name)
        }
    }

    /// To override in subclasses if needed.
    func registerJSMessages() {
        registerJSMessage(named: "log") { [weak self] in self?.didLog($0) }
        registerJSMessage(named: "logError") { [weak self] in self?.didLogError($0) }
        registerJSMessage(named: "tap") { [weak self] in self?.didTap($0) }
        registerJSMessage(named: "pointerEventReceived") { [weak self] in self?.didReceivePointerEvent($0) }
        registerJSMessage(named: "spreadLoadStarted") { [weak self] in self?.spreadLoadDidStart($0) }
        registerJSMessage(named: "spreadLoaded") { [weak self] in self?.spreadDidLoad($0) }
        registerJSMessage(named: "selectionChanged") { [weak self] in self?.selectionDidChange($0) }
        registerJSMessage(named: "keyEventReceived") { [weak self] in self?.didReceiveKeyEvent($0) }
        registerJSMessage(named: "imageActivated") { [weak self] in self?.didActivateImage($0) }
    }

    /// Add the message handlers for incoming javascript events.
    private func enableJSMessages() {
        guard !JSMessagesEnabled else {
            return
        }
        JSMessagesEnabled = true
        for name in JSMessages.keys {
            webView.configuration.userContentController.add(self, name: name)
        }
    }

    /// Removes message handlers (preventing strong reference cycle).
    private func disableJSMessages() {
        guard JSMessagesEnabled else {
            return
        }
        JSMessagesEnabled = false
        for name in JSMessages.keys {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    private func didReceiveKeyEvent(_ event: Any) {
        guard
            let dict = event as? [String: Any],
            let keyEvent = KeyEvent(dict: dict)
        else {
            return
        }

        delegate?.spreadView(self, didReceive: keyEvent)
    }

    // MARK: - Decorator

    /// Called by the JavaScript layer when the user activates a decoration.
    private func decorationDidActivate(_ body: Any) {
        guard
            let decoration = body as? [String: Any],
            let decorationId = decoration["id"] as? Decoration.Id,
            let groupName = decoration["group"] as? String,
            var frame = CGRect(json: decoration["rect"])
        else {
            log(.warning, "Invalid decoration activation body")
            return
        }

        frame = convertRectToNavigatorSpace(frame)
        let point = ClickEvent(json: decoration["click"])
            .map { convertPointToNavigatorSpace($0.point) }
        delegate?.spreadView(self, didActivateDecoration: decorationId, inGroup: groupName, frame: frame, point: point)
    }

    // MARK: - Image Activation

    /// Called by the JavaScript layer when the user taps on a zoomable image.
    private func didActivateImage(_ body: Any) {
        guard
            let data = body as? [String: Any],
            let srcString = data["src"] as? String,
            let url = URL(string: srcString)
        else {
            log(.warning, "Invalid body for didActivateImage: \(body)")
            return
        }

        let altText = data["alt"] as? String
        let caption = data["caption"] as? String
        let attribution = data["attribution"] as? String
        delegate?.spreadView(self, didActivateImageAt: url, altText: altText, caption: caption, attribution: attribution)
    }

    // MARK: - Accessibility

    private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning

    @objc private func voiceOverStatusDidChange() {
        // Avoids excessive settings refresh when the status didn't change.
        guard isVoiceOverRunning != UIAccessibility.isVoiceOverRunning else {
            return
        }
        isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        // Scroll mode will be activated if VoiceOver is on
        guard let lease = readiness.acquirePositionWriter() else {
            applySettings()
            return
        }
        applySettings()
        layoutIfNeeded()
        readiness.release(lease)
    }

    // MARK: - Scripts

    class func loadScript(named name: String) -> String {
        Bundle.module.url(forResource: "\(name)", withExtension: "js", subdirectory: "Assets/Static/scripts")
            .flatMap { try? String(contentsOf: $0) }!
    }
}

// MARK: - WKScriptMessageHandler for handling incoming message from the javascript layer.

extension EPUBSpreadView: WKScriptMessageHandler {
    /// Handles incoming calls from JS.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handler = JSMessages[message.name] else {
            return
        }
        handler(message.body)
    }
}

extension EPUBSpreadView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }

        if let record = currentMainFrameNavigation,
           record.navigation === navigation
        {
            guard
                record.generation == readiness.generation
            else {
                return
            }
            return
        }

        if var issuingMainFrameNavigation {
            guard issuingMainFrameNavigation.generation == readiness.generation else {
                return
            }
            issuingMainFrameNavigation.provisionalNavigation = navigation
            self.issuingMainFrameNavigation = issuingMainFrameNavigation
            registerMainFrameNavigation(
                navigation,
                generation: issuingMainFrameNavigation.generation
            )
            return
        }

        let generation = beginMainFrameLoading()
        registerMainFrameNavigation(navigation, generation: generation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let generation = currentMainFrameGeneration(for: navigation) else {
            return
        }
        if readiness.fail(ifCurrent: generation) {
            locatorCommandBridge.invalidateDocument()
        }
        let ns = error as NSError
        log(.error, "Web navigation failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let generation = currentMainFrameGeneration(for: navigation) else {
            return
        }
        if readiness.fail(ifCurrent: generation) {
            locatorCommandBridge.invalidateDocument()
        }
        let ns = error as NSError
        log(.error, "Provisional web navigation failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard currentMainFrameGeneration(for: navigation) != nil else {
            return
        }
        setNeedsStopActivityIndicator()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var policy: WKNavigationActionPolicy = .allow

        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                // Check if url is internal or external
                if let relativeURL = viewModel.publicationBaseURL.relativize(url) {
                    delegate?.spreadView(self, didTapOnInternalLink: relativeURL.string, clickEvent: lastClick)
                } else {
                    delegate?.spreadView(self, didTapOnExternalURL: url)
                }

                policy = .cancel
            }
        }

        decisionHandler(policy)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        readiness.invalidate()
        locatorCommandBridge.invalidateDocument()
        delegate?.spreadViewDidTerminate()
    }
}

extension EPUBSpreadView: UIScrollViewDelegate {
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isUserInteractionEnabled = true
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        webView.clearSelection()
        cancelInFlightCommandForUserInteraction()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Do not remove, overridden in subclasses.
    }
}

extension EPUBSpreadView: WKUIDelegate {}

extension EPUBSpreadView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Prevents the tap event from being triggered by the fallback tap
        // gesture recognizer when it is also recognized by the web view.
        true
    }
}

private extension EPUBSpreadView {
    func updateActivityIndicator() {
        switch viewModel.theme {
        case .dark:
            createActivityIndicator(color: .white)
        default:
            createActivityIndicator(color: .systemGray)
        }
    }

    func createActivityIndicator(color: UIColor) {
        guard activityIndicatorView?.color != color else {
            return
        }

        activityIndicatorView?.removeFromSuperview()
        activityIndicatorView = addCenteredActivityIndicator(color: color)
    }

    private func setNeedsStopActivityIndicator() {
        guard activityIndicatorStopWorkItem == nil else {
            return
        }

        activityIndicatorStopWorkItem = DispatchWorkItem { [weak self] in
            defer {
                self?.activityIndicatorStopWorkItem = nil
            }

            guard
                let self = self,
                let workItem = activityIndicatorStopWorkItem,
                !workItem.isCancelled
            else {
                return
            }

            trace("stopping activity indicator because spread \(spread.first.link.href) did not load")
            activityIndicatorView?.stopAnimating()
        }

        // If the spread doesn't begin loading within 2 seconds it means that we
        // likely encountered an error. In that case the work item we
        // schedule below will stop the activity indicator.
        // If the spread begins to load it will send a `spreadLoadStart` JS
        // event which will cancel the work item being scheduled here.
        trace("scheduling activity indicator stop")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2,
            execute: activityIndicatorStopWorkItem!
        )
    }
}

/// Produced by gestures.js
struct ClickEvent {
    let defaultPrevented: Bool
    let point: CGPoint
    let targetElement: String
    let interactiveElement: String?

    init(dict: [String: Any]) {
        defaultPrevented = dict["defaultPrevented"] as? Bool ?? false
        point = CGPoint(x: dict["x"] as? Double ?? 0, y: dict["y"] as? Double ?? 0)
        targetElement = dict["targetElement"] as? String ?? ""
        interactiveElement = dict["interactiveElement"] as? String
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any] else {
            return nil
        }
        self.init(dict: dict)
    }
}

/// Produced by gestures.js
private extension PointerEvent {
    init?(json: [String: Any]) {
        guard
            let pointerId = json["pointerId"] as? Int,
            let pointerType = json["pointerType"] as? String,
            let phase = PointerEvent.Phase(json: json["phase"]),
            let x = json["x"] as? Double,
            let y = json["y"] as? Double
        else {
            return nil
        }

        let optionalPointer: Pointer? = switch pointerType {
        case "mouse":
            .mouse(MousePointer(id: pointerId, buttons: MouseButtons(json: json)))
        case "touch":
            .touch(TouchPointer(id: pointerId))
        default:
            nil
        }

        guard let pointer = optionalPointer else {
            return nil
        }

        self.init(
            pointer: pointer,
            phase: phase,
            location: CGPoint(x: x, y: y),
            modifiers: KeyModifiers(json: json)
        )
        // FIXME:
//        interactiveElement = dict["interactiveElement"] as? String
    }
}

private extension MouseButtons {
    init(json: [String: Any]) {
        self.init()

        guard let buttons = json["buttons"] as? Int else {
            return
        }

        self = MouseButtons(rawValue: buttons)
    }
}

private extension PointerEvent.Phase {
    init?(json: Any?) {
        guard let json = json as? String else {
            return nil
        }

        switch json {
        case "down": self = .down
        case "cancel": self = .cancel
        case "move": self = .move
        case "up": self = .up
        default: return nil
        }
    }
}

private extension KeyModifiers {
    init(json: [String: Any]) {
        self.init()

        if (json["control"] as? Bool) ?? false {
            insert(.control)
        }
        if (json["command"] as? Bool) ?? false {
            insert(.command)
        }
        if (json["shift"] as? Bool) ?? false {
            insert(.shift)
        }
        if (json["option"] as? Bool) ?? false {
            insert(.option)
        }
    }
}

private extension KeyEvent {
    /// Parses the dictionary created in keyboard.js
    init?(dict: [String: Any]) {
        guard
            let phase = Phase(json: dict["phase"]),
            let code = dict["code"] as? String
        else {
            return nil
        }

        let key: Key
        switch code {
        case "Enter":
            key = .enter
        case "Tab":
            key = .tab
        case "Space":
            key = .space
        case "ArrowDown":
            key = .arrowDown
        case "ArrowLeft":
            key = .arrowLeft
        case "ArrowRight":
            key = .arrowRight
        case "ArrowUp":
            key = .arrowUp
        case "End":
            key = .end
        case "Home":
            key = .home
        case "PageDown":
            key = .pageDown
        case "PageUp":
            key = .pageUp
        case "MetaLeft", "MetaRight":
            key = .command
        case "ControlLeft", "ControlRight":
            key = .control
        case "AltLeft", "AltRight":
            key = .option
        case "ShiftLeft", "ShiftRight":
            key = .shift
        case "Backspace":
            key = .backspace
        case "Escape":
            key = .escape
        default:
            guard let char = dict["key"] as? String else {
                return nil
            }
            key = .character(char.lowercased())
        }

        var modifiers = KeyModifiers(json: dict)
        if let modifier = KeyModifiers(key: key) {
            modifiers.remove(modifier)
        }

        self.init(phase: phase, key: key, modifiers: modifiers)
    }
}

private extension KeyEvent.Phase {
    init?(json: Any?) {
        guard let json = json as? String else {
            return nil
        }

        switch json {
        case "up": self = .up
        case "down": self = .down
        default: return nil
        }
    }
}
