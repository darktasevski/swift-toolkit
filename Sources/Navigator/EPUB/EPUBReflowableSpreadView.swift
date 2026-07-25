//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// Owns the single continuation waiting for a smooth scroll to settle.
/// Requests are removed from the coordinator before they are resumed.
@MainActor
final class EPUBScrollAnimationCoordinator {
    final class Request {
        fileprivate let id: UUID
        private var continuation: CheckedContinuation<Void, Never>?

        fileprivate init(
            id: UUID,
            continuation: CheckedContinuation<Void, Never>
        ) {
            self.id = id
            self.continuation = continuation
        }

        func resume() {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    private var pendingRequest: Request?

    var hasPendingRequest: Bool {
        pendingRequest != nil
    }

    func waitUntilSettled() async {
        let requestID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }

                let request = Request(id: requestID, continuation: continuation)
                let previous = takePendingRequest()
                previous?.resume()
                pendingRequest = request

                Task { @MainActor [weak self, weak request] in
                    try? await Task.sleep(seconds: 0.8)
                    guard let self, let request else { return }
                    finish(request)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard
                    let self,
                    let request = self.pendingRequest,
                    request.id == requestID
                else {
                    return
                }
                self.takePendingRequest(matching: request)?.resume()
            }
        }
    }

    func takePendingRequest(matching request: Request? = nil) -> Request? {
        guard request == nil || pendingRequest === request else {
            return nil
        }
        let pendingRequest = pendingRequest
        self.pendingRequest = nil
        return pendingRequest
    }

    func finish(_ request: Request? = nil) {
        takePendingRequest(matching: request)?.resume()
    }
}

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private struct ContentInsetConfiguration: Equatable {
        let inset: UIEdgeInsets
        let scroll: Bool
    }

    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var contentInsetConfiguration: ContentInsetConfiguration?
    private var settingsLayoutTask: Task<Void, Never>?
    private let scrollAnimationCoordinator = EPUBScrollAnimationCoordinator()
    private final class PositionCommandOwnership {
        var isSupersessionAcknowledged = false
    }

    private struct PositionCommandEntry {
        let ownership: PositionCommandOwnership
        let task: Task<PageTurnOutcome, Never>
    }

    private var activePositionCommand: PositionCommandEntry?

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        var scripts = scripts
        scripts.append(WKUserScript(
            source: Self.reflowableScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: scripts,
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
        settingsLayoutTask?.cancel()
        settingsLayoutTask = nil
        activePositionCommand?.task.cancel()
        activePositionCommand = nil
        super.clear()
        scrollAnimationCoordinator.finish()
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = !viewModel.scroll

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        issueMainFrameLoad {
            webView.load(URLRequest(url: url.url))
        }
    }

    override func applySettings() {
        super.applySettings()

        // Disables paginated mode if scroll is on.
        scrollView.isPagingEnabled = !viewModel.scroll

        updateContentInset()
    }

    override func applyCSSScript(_ script: String) async -> Bool {
        guard case .success = await evaluateDocumentScript(script) else {
            return false
        }
        // Reflowable content repaginates on a CSS settings change; hold command
        // readiness until the reflow settles so a following command lands on the
        // new geometry.
        return await waitForLayoutStability()
    }

    private func updateContentInset() {
        let contentInset = delegate?.spreadViewContentInset(self) ?? .zero
        let configuration = ContentInsetConfiguration(
            inset: contentInset,
            scroll: viewModel.scroll
        )
        guard configuration != contentInsetConfiguration else {
            return
        }
        contentInsetConfiguration = configuration

        let writerLease = readiness.acquirePositionWriter()

        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInset

        } else {
            topConstraint.constant = contentInset.top
            bottomConstraint.constant = -contentInset.bottom
            scrollView.contentInset = .zero
        }

        layoutIfNeeded()

        guard let writerLease else { return }
        let predecessor = settingsLayoutTask
        predecessor?.cancel()
        settingsLayoutTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            let outcome: EPUBSpreadReadiness.MutationOutcome
            if Task.isCancelled {
                outcome = .superseded
            } else if await self.waitForLayoutStability() {
                outcome = .succeeded
            } else {
                outcome = Task.isCancelled ? .superseded : .failed
            }
            self.readiness.finishMutation(writerLease, outcome: outcome)
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func initializeSpread() async -> EPUBSpreadReadiness.InitializationOutcome {
        let stabilityDeadline = EPUBSpreadReadiness.makeInitializationStabilityDeadline()
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            guard case .success = await evaluateDocumentScript("readium.link = \(linkJSON);") else {
                return .failed
            }
        }

        guard await waitForLayoutStability(until: stabilityDeadline) else { return .failed }

        // Anchor-tracking init: pull the per-resource anchor list from the
        // view model and call into the JS module. Even on oversized/invalid
        // input, we MUST call into JS so the always-teardown-first contract
        // runs on re-injection — otherwise a stale observer from a prior
        // page survives. Size and per-element caps are checked AFTER we
        // commit to dispatching the init (with empty list when invalid).
        let rawAnchorIds = viewModel.anchorIds(forResourceAt: spread.first.link.url(relativeTo: viewModel.publicationBaseURL)) ?? []
        let anchorIds: [String] = {
            if rawAnchorIds.count > AnchorTrackingLimits.maxAnchorIdsPerResource {
                log(.warning, "anchor tracking init: list size=\(rawAnchorIds.count) exceeds cap, dispatching empty for teardown")
                return []
            }
            if !rawAnchorIds.allSatisfy({ $0.utf8.count <= AnchorTrackingLimits.maxAnchorIdByteLength }) {
                log(.warning, "anchor tracking init: oversized element, dispatching empty for teardown")
                return []
            }
            return rawAnchorIds
        }()
        do {
            _ = try await webView.callAsyncJavaScript(
                "readium.initAnchorTracking(anchorIds);",
                arguments: ["anchorIds": anchorIds],
                in: nil,
                contentWorld: .page
            )
        } catch is CancellationError {
            // Spread teardown — not a failure.
            return .failed
        } catch {
            // type+domain+code only — never bare \(error). WKErrorDomain.userInfo
            // can echo script source + arguments.
            let ns = error as NSError
            log(.warning, "anchor tracking init failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
        }

        // Positioning is the final suspending initialization stage so a
        // locator received during stylesheet/font or anchor setup cannot be
        // skipped by an older pending value.
        guard await pendingLocationMutation.applyLatest({ [weak self] location in
            guard let self else { return false }
            guard let location else { return true }
            guard await self.apply(location) else { return false }
            return await self.waitForLayoutStability(until: stabilityDeadline)
        }) else {
            return .failed
        }
        return .succeeded
    }

    /// Waits for every external stylesheet, fonts and a bounded run of stable
    /// animation frames. A caller-provided deadline lets all initialization
    /// stages share one non-resetting budget.
    private func waitForLayoutStability(
        until deadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        let generation = readiness.generation
        guard case .documentAvailable = await readiness.waitForDocumentAvailability(for: generation) else {
            return false
        }

        let deadline = deadline ?? EPUBSpreadReadiness.makeInitializationStabilityDeadline()
        let remainingMilliseconds = EPUBSpreadReadiness
            .remainingInitializationStabilityMilliseconds(until: deadline)
        guard remainingMilliseconds > 0 else { return false }

        do {
            let result = try await webView.callAsyncJavaScript(
                """
                const absoluteDeadline = performance.now() + deadlineMilliseconds;
                const beforeDeadline = () => performance.now() < absoluteDeadline;
                const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
                const cappedWait = new Promise(resolve => {
                    setTimeout(() => resolve(false), Math.max(0, absoluteDeadline - performance.now()));
                });
                const stabilityWork = async () => {
                    while (beforeDeadline()) {
                        const stylesheetLinks = Array.from(
                            document.querySelectorAll('link[rel~="stylesheet"]')
                        );
                        if (stylesheetLinks.every(link => link.sheet !== null)) {
                            break;
                        }
                        await nextFrame();
                    }
                    if (!beforeDeadline()) {
                        return false;
                    }
                    if (document.fonts) {
                        await document.fonts.ready;
                    }
                    if (!beforeDeadline()) {
                        return false;
                    }

                    var previous = null;
                    var stableFrames = 0;
                    for (let frame = 0; frame < 12 && stableFrames < 2 && beforeDeadline(); frame += 1) {
                        await nextFrame();
                        const current = [
                            document.documentElement.scrollWidth,
                            document.documentElement.scrollHeight,
                            document.body?.scrollWidth ?? 0,
                            document.body?.scrollHeight ?? 0,
                        ];
                        if (previous !== null && current.every((value, index) => value === previous[index])) {
                            stableFrames += 1;
                        } else {
                            stableFrames = 0;
                        }
                        previous = current;
                    }
                    return stableFrames >= 2;
                };
                return await Promise.race([stabilityWork(), cappedWait]);
                """,
                arguments: [
                    "deadlineMilliseconds": remainingMilliseconds,
                ],
                in: nil,
                contentWorld: .page
            )
            guard
                !Task.isCancelled,
                generation == readiness.generation
            else {
                return false
            }
            return result as? Bool == true
        } catch is CancellationError {
            return false
        } catch {
            let ns = error as NSError
            log(.warning, "Layout stability failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
            return false
        }
    }

    override func go(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions
    ) async -> PageTurnOutcome {
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        if !readiness.isCommandReady, activePositionCommand == nil {
            guard !Task.isCancelled else { return .cancelled }
            let generation = readiness.generation
            switch await Self.readinessGateDisposition(
                for: readiness.waitForCommandReadiness(for: generation)
            ) {
            case .proceed:
                guard !Task.isCancelled else { return .cancelled }
            case .cancelled:
                return .cancelled
            case .failed:
                return .failed
            }
        }

        return await runPositionCommand(.pageTurn(PendingPageTurn(
            direction: direction,
            animated: options.animated
        )))
    }

    private struct PendingPageTurn {
        let direction: EPUBSpreadView.Direction
        let animated: Bool
    }

    private struct PendingLocation {
        let ownerID: UUID
        let location: PageLocation
        let animated: Bool

        init(
            ownerID: UUID = UUID(),
            location: PageLocation,
            animated: Bool
        ) {
            self.ownerID = ownerID
            self.location = location
            self.animated = animated
        }
    }

    private enum PendingPositionCommand {
        case location(PendingLocation)
        case pageTurn(PendingPageTurn)
    }

    /// Location to scroll to in the resource once the page is loaded.
    private let pendingLocationMutation = EPUBLatestMutation<PendingLocation?>(
        initialValue: PendingLocation(location: .start, animated: false)
    )
    private let pendingPositionMutation = EPUBLatestMutation<PendingPositionCommand>(
        initialValue: .location(PendingLocation(location: .start, animated: false))
    )

    func acknowledgeCommandSupersession() {
        activePositionCommand?.ownership.isSupersessionAcknowledged = true
    }

    override func cancelInFlightCommandForUserInteraction() {
        // The user grabbed the page: acknowledge the active command as
        // superseded so it releases its lease cleanly (the document stays
        // command-ready at the user's new spot rather than failing), then cancel
        // it. The command surfaces `.cancelled`, so no fallback scroll fights
        // the gesture. Idle when nothing is in flight.
        acknowledgeCommandSupersession()
        activePositionCommand?.task.cancel()
    }

    override func go(
        to location: PageLocation,
        animated: Bool
    ) async -> PageCommandOutcome {
        let pendingLocation = PendingLocation(
            location: location,
            animated: animated
        )
        pendingLocationMutation.update(pendingLocation)

        return await withTaskCancellationHandler {
            let outcome = await go(to: pendingLocation)
            if outcome == .cancelled || Task.isCancelled {
                clearPendingLocation(ownedBy: pendingLocation.ownerID)
                return .cancelled
            }
            return outcome
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.clearPendingLocation(ownedBy: pendingLocation.ownerID)
            }
        }
    }

    private func go(to pendingLocation: PendingLocation) async -> PageCommandOutcome {
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard readiness.isCommandReady || activePositionCommand != nil else {
            let generation = readiness.generation
            switch await Self.readinessGateDisposition(
                for: readiness.waitForCommandReadiness(for: generation)
            ) {
            case .proceed:
                return Task.isCancelled ? .cancelled : .succeeded
            case .cancelled:
                return .cancelled
            case .failed:
                return .failed
            }
        }

        let outcome = await runPositionCommand(.location(pendingLocation))
        switch outcome {
        case .succeeded:
            return .succeeded
        case .cancelled:
            return .cancelled
        case .boundary, .failed:
            return .failed
        }
    }

    private func clearPendingLocation(ownedBy ownerID: UUID) {
        guard pendingLocationMutation.latestValue?.ownerID == ownerID else {
            return
        }
        pendingLocationMutation.update(nil)
    }

    private func runPositionCommand(
        _ command: PendingPositionCommand
    ) async -> PageTurnOutcome {
        pendingPositionMutation.update(command)

        let predecessor = activePositionCommand?.task
        activePositionCommand?.ownership.isSupersessionAcknowledged = true
        predecessor?.cancel()

        let ownership = PositionCommandOwnership()
        let task = Task { @MainActor [weak self, ownership] in
            if let predecessor {
                _ = await predecessor.value
            }
            guard let self else { return PageTurnOutcome.cancelled }
            let outcome = await self.executePositionCommand(ownership: ownership)
            if self.activePositionCommand?.ownership === ownership {
                self.activePositionCommand = nil
            }
            return outcome
        }
        activePositionCommand = PositionCommandEntry(
            ownership: ownership,
            task: task
        )

        return await withTaskCancellationHandler {
            let outcome = await task.value
            guard Task.isCancelled else { return outcome }
            cancelPositionCommand(ownedBy: ownership)
            _ = await task.value
            return .cancelled
        } onCancel: {
            Task { @MainActor [weak self, ownership] in
                self?.cancelPositionCommand(ownedBy: ownership)
            }
        }
    }

    private func cancelPositionCommand(
        ownedBy ownership: PositionCommandOwnership
    ) {
        guard activePositionCommand?.ownership === ownership else { return }
        activePositionCommand?.task.cancel()
    }

    private func executePositionCommand(
        ownership: PositionCommandOwnership
    ) async -> PageTurnOutcome {
        guard !Task.isCancelled else {
            if !ownership.isSupersessionAcknowledged {
                readiness.invalidate()
            }
            return .cancelled
        }
        guard let writerLease = readiness.acquirePositionWriter() else {
            return Task.isCancelled ? .cancelled : .failed
        }

        var appliedOutcome = PageTurnOutcome.failed
        let succeeded = await pendingPositionMutation.applyLatest { [weak self] command in
            guard let self else { return false }
            appliedOutcome = await self.apply(command)
            return appliedOutcome == .succeeded || appliedOutcome == .boundary
        }

        let mutationOutcome: EPUBSpreadReadiness.MutationOutcome
        if succeeded {
            mutationOutcome = .succeeded
        } else if Task.isCancelled, ownership.isSupersessionAcknowledged {
            mutationOutcome = .superseded
        } else {
            mutationOutcome = .failed
        }
        readiness.finishMutation(writerLease, outcome: mutationOutcome)

        if succeeded {
            return appliedOutcome
        }
        return Task.isCancelled ? .cancelled : .failed
    }

    private func apply(
        _ command: PendingPositionCommand
    ) async -> PageTurnOutcome {
        switch command {
        case let .location(location):
            guard await apply(location) else { return .failed }
            return await waitForLayoutStability() ? .succeeded : .failed
        case let .pageTurn(turn):
            return await apply(turn)
        }
    }

    private func apply(_ turn: PendingPageTurn) async -> PageTurnOutcome {
        let factor: CGFloat
        switch turn.direction {
        case .left:
            factor = -1
        case .right:
            factor = 1
        }
        guard scrollView.bounds.width > 0 else { return .failed }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return .boundary
        }

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let behavior = turn.animated ? "smooth" : "instant"
        let result = await evaluateDocumentScript(
            "window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });"
        )
        guard case .success = result else {
            return .failed
        }

        // One deadline for the whole page turn, spent by BOTH settle rungs. Each
        // previously minted its own allowance, so a slow layout settle bought the
        // scroll-position wait a fresh second rather than eating into a shared
        // budget. Taking the earlier of this and each rung's own cap can only
        // tighten a turn, never extend one.
        let settleDeadline = EPUBLocatorOperationDeadline(
            startingAt: ContinuousClock().now,
            budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
        )
        let settlement = Task { @MainActor [weak self] in
            guard let self else { return false }
            if turn.animated {
                await scrollAnimationCoordinator.waitUntilSettled()
            }
            let layoutCap = EPUBSpreadReadiness.makeInitializationStabilityDeadline()
            guard await waitForLayoutStability(
                until: settleDeadline.effectiveDeadline(cappedBy: layoutCap)
            ) else {
                return false
            }
            return await waitForScrollPosition(targetX, until: settleDeadline)
        }
        let didSettle = await settlement.value
        guard didSettle else { return .failed }
        return Task.isCancelled ? .cancelled : .succeeded
    }

    /// - Parameter operationDeadline: the page turn's single deadline. This rung is
    ///   bounded by the EARLIER of its own settle cap and what remains of the turn, so
    ///   it can no longer re-arm a full second after the rungs above it ran long.
    private func waitForScrollPosition(
        _ targetX: CGFloat,
        until operationDeadline: EPUBLocatorOperationDeadline
    ) async -> Bool {
        let clock = ContinuousClock()
        let settleCap = clock.now.advanced(by: .seconds(1))
        let deadline = operationDeadline.effectiveDeadline(cappedBy: settleCap)
        while clock.now < deadline {
            if abs(scrollView.contentOffset.x - targetX) <= 1 {
                return true
            }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func apply(_ location: PendingLocation) async -> Bool {
        switch location.location {
        case let .locator(locator):
            return await go(to: locator, animated: location.animated)
        case .start:
            return await scroll(toProgression: 0, animated: location.animated)
        case .end:
            return await scroll(toProgression: 1, animated: location.animated)
        }
    }

    private func scrollDidEnd() {
        scrollAnimationCoordinator.finish()
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        let hasDocumentAnchor = locator.locations.domRange != nil
            || locator.locations.cssSelector != nil
            || locator.locations.fragments.contains { !$0.isEmpty }
            || locator.text.highlight != nil

        if hasDocumentAnchor {
            let outcome = await navigationOutcome(to: locator, animated: animated)
            switch Self.anchorLandingDecision(for: outcome) {
            case .landed:
                return true
            case .degradeToProgression:
                break
            case .cancelled:
                return false
            }
        }

        let progression = locator.locations.progression ?? 0
        return await scroll(toProgression: progression, animated: animated)
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            let result = await evaluateDocumentScript(
                "readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))"
            )
            guard case .success = result else { return false }
            return true
        }
    }

    enum AnchorLandingDecision: Equatable {
        case landed
        case degradeToProgression
        case cancelled
    }

    /// Pure decision over a pending-location anchor command's bridge outcome
    /// (mirrors `EPUBNavigatorHolder.citationRetryDecision`). A genuine
    /// `.miss` degrades to the progression landing rather than failing
    /// initialization outright; `.cancelled` must NOT degrade, or it would
    /// silently "succeed" via the fallback.
    nonisolated static func anchorLandingDecision(
        for outcome: EPUBLocatorCommandOutcome
    ) -> AnchorLandingDecision {
        switch outcome {
        case .applied: return .landed
        case .miss: return .degradeToProgression
        case .cancelled: return .cancelled
        }
    }

    /// Resolves and scrolls to a document anchor in the isolated locator
    /// command world. Publisher-derived locator data is passed as a typed
    /// argument and is never interpolated into executable source.
    ///
    /// Returns the bridge's closed outcome so callers can distinguish a
    /// genuine anchor miss (degradable) from cancellation (must propagate —
    /// collapsing them into a Bool let a cancelled command "succeed" via the
    /// caller's progression fallback). An unencodable locator is a miss: the
    /// anchor cannot be resolved, but nothing was interrupted.
    private func navigationOutcome(
        to locator: Locator,
        animated: Bool
    ) async -> EPUBLocatorCommandOutcome {
        guard let json = try? locator.jsonString() else {
            return .miss
        }
        // A DISTINCT operation, not a rung of `performLocatorNavigation`: this is the
        // spread's own anchor apply, reached through `go(to:animated:)` during spread
        // setup, and no operation deadline exists above it to inherit. Minting here is
        // therefore the operation start — not the per-rung re-arming the single-deadline
        // contract forbids.
        let deadline = EPUBLocatorOperationDeadline(
            startingAt: ContinuousClock().now,
            budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
        )
        let result = await locatorCommandBridge.navigate(
            locatorJSON: json,
            targetHREF: viewModel.url(to: spread.first.link),
            animated: animated,
            deadline: deadline
        )
        return result.outcome
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
            isCommandReady,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
        registerJSMessage(named: "visibleAnchorChanged") { [weak self] in self?.visibleAnchorDidChange($0) }
    }

    private func visibleAnchorDidChange(_ body: Any) {
        // WKScriptMessage.body decode is privacy-safe by silence: we never
        // log the raw body. anchorId can embed publisher-controlled chapter
        // titles.
        //
        // Threat model: EPUB 3 publications MAY ship `<script>` blocks. Such
        // a script can call `webkit.messageHandlers.visibleAnchorChanged.postMessage(...)`
        // directly with a forged payload — `WKUserContentController` registers
        // handlers on the page world, not an isolated world. Blast radius is
        // bounded: the receiving reducer's lookup-miss arm in `.visibleAnchorChanged`
        // (see `ReaderFeature+Persistence.swift`) treats the fragmentId as
        // untrusted and only writes `currentChapterId` if the (href, fragmentId)
        // pair is present in `visibleAnchorLookup` — which is sourced from the
        // NCX, not the script. At worst, an attacker with a `<script>` block
        // can lie about which sub-chapter the user is reading WITHIN the same
        // spread.
        guard let anchorId = Self.decodeVisibleAnchorBody(body) else { return }
        delegate?.spreadView(self, visibleAnchorDidChange: anchorId)
    }

    /// Pure decoder for the `visibleAnchorChanged` JS message body. Returns
    /// `nil` for any malformed/oversized/empty input — silence is the
    /// privacy mechanism (decode-failure logs would name the offending
    /// publisher-controlled value). Static + `nonisolated` so unit tests can
    /// exercise it without constructing a heavy `EPUBReflowableSpreadView`
    /// instance (the enclosing class is `@MainActor`-isolated via `UIView`).
    @_spi(Testing)
    public nonisolated static func decodeVisibleAnchorBody(_ body: Any) -> String? {
        guard let dict = body as? [String: Any],
              let anchorId = dict["anchorId"] as? String,
              !anchorId.isEmpty,
              anchorId.utf8.count <= AnchorTrackingLimits.maxAnchorIdByteLength
        else {
            return nil
        }
        return anchorId
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }
}
