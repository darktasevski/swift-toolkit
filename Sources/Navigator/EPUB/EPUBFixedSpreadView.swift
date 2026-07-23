//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a fixed layout.
final class EPUBFixedSpreadView: EPUBSpreadView {
    private struct LayoutConfiguration: Equatable {
        let viewportSize: CGSize
        let insets: UIEdgeInsets
        let fit: String
    }

    /// Generation whose host wrapper has completed its one bootstrap.
    private var wrapperBootstrapGeneration: EPUBSpreadReadiness.Generation?
    /// URL to load in the iframe once the wrapper page is loaded.
    private var urlToLoad: URL?
    private var layoutMutation: EPUBLatestMutation<LayoutConfiguration>?
    private var layoutTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?

    private static let fixedScript = loadScript(named: "readium-fixed")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        var scripts = scripts
        scripts.append(WKUserScript(source: Self.fixedScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        super.init(viewModel: viewModel, spread: spread, scripts: scripts, animatedLoad: animatedLoad)
    }

    override func setupWebView() {
        super.setupWebView()

        // Used to center the web view's content. Since the web view is centered by changing its frame directly, unclipping its bounds allows to see the overflowing content when zooming in.
        webView.clipsToBounds = false
        scrollView.clipsToBounds = false
        clipsToBounds = true

        // Required to have the page centered when zooming out. It also feels more natural.
        scrollView.bounces = true

        // Makes sure that we can see the superview's background color behind the iframe.
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        scrollView.backgroundColor = UIColor.clear

        // Loads the wrapper page into the web view.
        let spreadFile = "fxl-spread-\(viewModel.spreadEnabled ? "two" : "one")"
        if
            let wrapperPageURL = Bundle.module.url(forResource: spreadFile, withExtension: "html", subdirectory: "Assets"),
            var wrapperPage = try? String(contentsOf: wrapperPageURL, encoding: .utf8)
        {
            wrapperPage = wrapperPage.replacingOccurrences(
                of: "{{ASSETS_URL}}",
                with: viewModel.assetsBaseURL.string
            )

            // The publication's base URL is used to make sure we can access the resources through the iframe with JavaScript.
            issueMainFrameLoad {
                webView.loadHTMLString(
                    wrapperPage,
                    baseURL: viewModel.publicationBaseURL.url
                )
            }
        }
    }

    override func mainFrameLoadDidBegin(
        _ generation: EPUBSpreadReadiness.Generation
    ) {
        wrapperBootstrapGeneration = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        layoutTask?.cancel()
        layoutTask = nil
    }

    override func clear() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        layoutTask?.cancel()
        layoutTask = nil
        super.clear()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSpread()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        layoutSpread()
    }

    /// Layouts the resource to fit its content in the bounds.
    private func layoutSpread() {
        guard wrapperBootstrapGeneration == readiness.generation else {
            return
        }

        var insets = delegate?.spreadViewContentInset(self) ?? .zero

        // Use the same insets on the left and right side (the largest one) to
        // keep the pages centered on the screen even if the notches are not
        // symmetrical.
        let horizontalInsets = max(insets.left, insets.right)
        insets.left = horizontalInsets
        insets.right = horizontalInsets

        let viewportSize = bounds.inset(by: insets).size
        let fitString = viewModel.settings.fit.rawValue
        let configuration = LayoutConfiguration(
            viewportSize: viewportSize,
            insets: insets,
            fit: fitString
        )
        guard configuration != layoutMutation?.latestValue else {
            return
        }
        if let layoutMutation {
            layoutMutation.update(configuration)
        } else {
            layoutMutation = EPUBLatestMutation(initialValue: configuration)
        }

        guard readiness.isCommandReady else {
            return
        }

        guard let writerLease = readiness.acquirePositionWriter() else {
            return
        }
        let predecessor = layoutTask
        predecessor?.cancel()
        layoutTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            let outcome: EPUBSpreadReadiness.MutationOutcome
            if Task.isCancelled {
                outcome = .superseded
            } else if await self.applyLatestLayout() {
                outcome = .succeeded
            } else {
                outcome = Task.isCancelled ? .superseded : .failed
            }
            self.readiness.finishMutation(writerLease, outcome: outcome)
        }
    }

    private func viewportScript(for configuration: LayoutConfiguration) -> String {
        """
        spread.setViewport(
            {'width': \(Int(configuration.viewportSize.width)), 'height': \(Int(configuration.viewportSize.height))},
            {'top': \(Int(configuration.insets.top)), 'left': \(Int(configuration.insets.left)), 'bottom': \(Int(configuration.insets.bottom)), 'right': \(Int(configuration.insets.right))},
            '\(configuration.fit)'
        );
        """
    }

    private func applyLatestLayout(
        stabilityDeadline: ContinuousClock.Instant? = nil
    ) async -> Bool {
        guard let layoutMutation else { return false }
        return await layoutMutation.applyLatest { [weak self] configuration in
            guard let self else { return false }
            guard await self.evaluateViewport(configuration) else { return false }
            return await self.waitForFixedLayoutStability(until: stabilityDeadline)
        }
    }

    private func evaluateViewport(_ configuration: LayoutConfiguration) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(viewportScript(for: configuration)) { [weak self] _, error in
                if let error {
                    let ns = error as NSError
                    self?.log(.warning, "Fixed viewport failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    private func waitForFixedLayoutStability(
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
                const currentFramesAndDocuments = () => {
                    const frames = Array.from(document.querySelectorAll('iframe'));
                    const documents = frames.map(frame => frame.contentDocument);
                    if (frames.length === 0 || documents.some(child => child === null)) {
                        return null;
                    }
                    return {frames, documents};
                };
                const stabilityWork = async () => {
                    var loaded;
                    while (beforeDeadline()) {
                        loaded = currentFramesAndDocuments();
                        if (loaded && loaded.documents.every(child => {
                            const links = Array.from(child.querySelectorAll('link[rel~="stylesheet"]'));
                            return links.every(link => link.sheet !== null);
                        })) {
                            break;
                        }
                        await nextFrame();
                    }
                    if (!loaded || !beforeDeadline()) {
                        return false;
                    }
                    await Promise.all(loaded.documents.map(child => child.fonts?.ready));
                    if (!beforeDeadline()) {
                        return false;
                    }

                    var previous = null;
                    var stableFrames = 0;
                    for (let frameIndex = 0; frameIndex < 12 && stableFrames < 2 && beforeDeadline(); frameIndex += 1) {
                        await nextFrame();
                        loaded = currentFramesAndDocuments();
                        if (!loaded) {
                            return false;
                        }
                        const current = loaded.frames.flatMap((frame, index) => {
                            const child = loaded.documents[index];
                            const rect = frame.getBoundingClientRect();
                            return [
                                rect.width,
                                rect.height,
                                child.documentElement.scrollWidth,
                                child.documentElement.scrollHeight,
                                child.body?.scrollWidth ?? 0,
                                child.body?.scrollHeight ?? 0,
                            ];
                        });
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
            return
                !Task.isCancelled &&
                generation == readiness.generation &&
                result as? Bool == true
        } catch is CancellationError {
            return false
        } catch {
            let ns = error as NSError
            log(.warning, "Fixed layout stability failed type=\(type(of: error)) [\(ns.domain)#\(ns.code)]")
            return false
        }
    }

    override func initializeSpread() async -> EPUBSpreadReadiness.InitializationOutcome {
        let generation = readiness.generation
        guard let layoutLease = readiness.acquireWriterLease(for: generation) else {
            return .failed
        }
        let stabilityDeadline = EPUBSpreadReadiness.makeInitializationStabilityDeadline()
        let succeeded = await applyLatestLayout(stabilityDeadline: stabilityDeadline)
        readiness.finishInitialization(
            layoutLease,
            outcome: succeeded ? .succeeded : .failed
        )
        return succeeded ? .succeeded : .failed
    }

    override func loadSpread() {
        guard wrapperBootstrapGeneration == readiness.generation else {
            return
        }
        // We call this directly on the web view on purpose, because this needs
        // to be executed before the spread is loaded.
        let spreadJSON = spread.jsonString(
            forBaseURL: viewModel.publicationBaseURL,
            readingProgression: viewModel.readingProgression
        )
        webView.evaluateJavaScript("spread.load(\(spreadJSON));")
    }

    override func evaluateScript(_ script: String, inHREF href: AnyURL? = nil) async -> Result<Any, any Error> {
        let href = href?.string ?? ""
        let script = "spread.eval('\(href)', `\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`);"
        return await super.evaluateScript(script)
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * scrollView.zoomScale - scrollView.contentOffset.x + webView.frame.minX,
            y: point.y * scrollView.zoomScale - scrollView.contentOffset.y + webView.frame.minY
        )
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        rect.size = CGSize(
            width: rect.width * scrollView.zoomScale,
            height: rect.height * scrollView.zoomScale
        )
        return rect
    }

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        guard
            let generation = currentMainFrameGeneration(for: navigation),
            wrapperBootstrapGeneration != generation
        else {
            return
        }

        wrapperBootstrapGeneration = generation
        layoutSpread()
        bootstrapTask?.cancel()
        bootstrapTask = Task { @MainActor [weak self] in
            guard let self, let layoutMutation else { return }
            let succeeded = await layoutMutation.applyLatest { [weak self] configuration in
                guard let self else { return false }
                return await self.evaluateViewport(configuration)
            }
            guard
                succeeded,
                !Task.isCancelled,
                self.readiness.generation == generation,
                self.wrapperBootstrapGeneration == generation
            else {
                if !Task.isCancelled,
                   self.wrapperBootstrapGeneration == generation,
                   self.readiness.fail(ifCurrent: generation)
                {
                    self.locatorCommandBridge.invalidateDocument()
                }
                return
            }
            self.loadSpread()
        }
    }

    // MARK: - Location and progression

    override func go(
        to location: PageLocation,
        animated: Bool
    ) async -> PageCommandOutcome {
        // Fixed layout resources are always fully visible so we don't use the
        // location.
        let generation = readiness.generation
        switch await readiness.waitForCommandReadiness(for: generation) {
        case .ready:
            return .succeeded
        case .cancelled:
            return .cancelled
        case .documentAvailable, .invalidated, .timedOut, .failed:
            return .failed
        }
    }
}
