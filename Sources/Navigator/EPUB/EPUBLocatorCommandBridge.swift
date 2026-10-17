//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreFoundation
import Foundation
import ReadiumShared
@preconcurrency import WebKit

enum EPUBLocatorFrameLayout: Sendable {
    case reflowable
    case fixed
}

enum EPUBLocatorFrameMissReason: String, Equatable, Sendable {
    case frameMissing
    case staleDocument
    case crossOriginFrame
    case fixedLayoutIneligible
    case duplicateFrame
}

enum EPUBLocatorFrameSelection: Equatable, Sendable {
    case selected(String)
    case miss(EPUBLocatorFrameMissReason)
}

/// A content-free model of the frames that announced readiness from the
/// isolated locator command world.
///
/// `WKFrameInfo` is deliberately kept out of this type. The WebKit-facing
/// bridge owns those objects on the main actor and uses the selected opaque ID
/// to retrieve one frame only after this policy has failed closed.
struct EPUBLocatorFrameRegistry: Sendable {
    private struct Entry: Sendable {
        let id: String
        let href: String
        let capability: EPUBSpreadFrameCapability
        let isMainFrame: Bool
        let isSameOrigin: Bool
    }

    let layout: EPUBLocatorFrameLayout
    private var entriesByID: [String: Entry] = [:]

    init(layout: EPUBLocatorFrameLayout) {
        self.layout = layout
    }

    /// Registers a frame and returns the IDs it replaced. A reflowable main frame
    /// replaces every main-frame entry holding the same capability: a handshake
    /// retry echoes that capability again from a new frame handle, which must not
    /// leave two eligible entries. Fixed-layout duplicates still fail closed.
    @discardableResult
    mutating func register(
        id: String,
        href: String,
        capability: EPUBSpreadFrameCapability,
        isMainFrame: Bool,
        isSameOrigin: Bool
    ) -> [String] {
        var replaced: [String] = []
        if layout == .reflowable, isMainFrame {
            replaced = entriesByID.values
                .filter { $0.id != id && $0.isMainFrame && $0.capability == capability }
                .map(\.id)
            for replacedID in replaced {
                entriesByID[replacedID] = nil
            }
        }
        entriesByID[id] = Entry(
            id: id,
            href: href,
            capability: capability,
            isMainFrame: isMainFrame,
            isSameOrigin: isSameOrigin
        )
        return replaced
    }

    mutating func removeAll() {
        entriesByID.removeAll(keepingCapacity: true)
    }

    /// Selects the single eligible frame that echoed the current document
    /// capability. A `nil` current capability (no document has yet received a
    /// capability from the native side) matches no entry and fails closed.
    func select(
        href: String,
        capability: EPUBSpreadFrameCapability?
    ) -> EPUBLocatorFrameSelection {
        let matchingHref = entriesByID.values.filter { $0.href == href }
        guard !matchingHref.isEmpty else {
            return .miss(.frameMissing)
        }

        let current = matchingHref.filter { $0.capability == capability }
        guard !current.isEmpty else {
            return .miss(.staleDocument)
        }

        let sameOrigin = current.filter(\.isSameOrigin)
        guard !sameOrigin.isEmpty else {
            return .miss(.crossOriginFrame)
        }

        let eligible: [Entry]
        switch layout {
        case .reflowable:
            eligible = sameOrigin.filter(\.isMainFrame)
        case .fixed:
            eligible = sameOrigin.filter { !$0.isMainFrame }
        }

        guard !eligible.isEmpty else {
            return .miss(.fixedLayoutIneligible)
        }
        guard eligible.count == 1, let selected = eligible.first else {
            return .miss(.duplicateFrame)
        }
        return .selected(selected.id)
    }
}

enum EPUBLocatorCommandOperationKind: String, Hashable, Sendable {
    case navigation
    case decoration
    case validation
}

struct EPUBLocatorCommandToken: Equatable, Sendable {
    struct AuthorizationIdentity: Equatable, Sendable {
        let webViewInstanceID: String
        let documentEpoch: Int
        let operationKind: EPUBLocatorCommandOperationKind
        let sequence: Int
        let groupID: String?
    }

    let webViewInstanceID: String
    let documentEpoch: Int
    let operationKind: EPUBLocatorCommandOperationKind
    let sequence: Int
    let groupID: String?
    /// What remains of the ONE absolute monotonic deadline minted at operation
    /// start, in milliseconds. The script converts this to a `performance.now()`
    /// instant once and bounds every wait by what is left of it, so a starved
    /// frame callback can no longer multiply a per-rung allowance across the
    /// viewport, offset-settle, and correction rungs. It is injected rather than
    /// hardcoded in JavaScript for two reasons: the deadline belongs to the whole
    /// operation (which begins on the native side, before any script runs), and a
    /// JavaScript-internal constant would be untestable — the only tier that can
    /// observe the script is the shipping-bundle suite, whose visible-window host
    /// lets frames fire normally so an internal deadline could never be driven to
    /// expiry.
    let budgetMilliseconds: Int

    /// Stable fields that authorize a script message against native command
    /// state. The remaining deadline is execution payload, not authority.
    var authorizationIdentity: AuthorizationIdentity {
        AuthorizationIdentity(
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            operationKind: operationKind,
            sequence: sequence,
            groupID: groupID
        )
    }

    var javascriptValue: [String: Any] {
        var value: [String: Any] = [
            "webViewInstanceID": webViewInstanceID,
            "documentEpoch": documentEpoch,
            "operationKind": operationKind.rawValue,
            "sequence": sequence,
            "budgetMilliseconds": budgetMilliseconds,
        ]
        if let groupID {
            value["groupID"] = groupID
        }
        return value
    }
}

enum EPUBLocatorCommandOutcome: String, Sendable {
    case applied
    case miss
    case cancelled
}

enum EPUBLocatorCommandReason: String, Sendable {
    case none
    case frameMissing
    case staleDocument
    case crossOriginFrame
    case fixedLayoutIneligible
    case duplicateFrame
    case malformed
    case payloadTooLarge
    case nestingTooDeep
    case duplicateField
    case invalidRoot
    case unknownField
    case missingRequiredField
    case invalidField
    case stringTooLong
    case selectorTooLong
    case quoteContextTooLong
    case highlightTooLong
    case invalidNumber
    case invalidInteger
    case invalidDOMRange
    case invalidToken
    case invalidCommand
    case staleToken
    case notFound
    case notUnique
    case matchRootTooLarge
    case paintTimeout
    case notScrollable
    case rangeCollapsed
    case rangeDetached
    case rangeNotVisible
    case rangeTooComplex
    case rangeSuppressed
    case rangeObscured
    case geometryUnverifiable
    case viewportNotReady
    case internalError
    case invalidResult
    case webKitFailure
    /// The script call never returned before the operation's deadline elapsed —
    /// a wedged page main thread or a content process that stopped servicing the
    /// world without reporting termination. Distinct from `webKitFailure` (the
    /// call returned an error) and from `paintTimeout` (the script ran and gave
    /// up waiting for a frame): only this one means no script outcome exists.
    /// Native-only: the script never emits this code, by definition — a script that
    /// reported an outcome is a script that ran. Note the decoder does not ENFORCE
    /// that, since it maps any `reasonCode` through `init(rawValue:)`; a page that
    /// echoed this string would produce a misleading log line and nothing more,
    /// because `reason` is never switched on.
    case commandUnresponsive
}

struct EPUBLocatorCommandResult: Sendable {
    let token: EPUBLocatorCommandToken
    let outcome: EPUBLocatorCommandOutcome
    let reason: EPUBLocatorCommandReason
}

struct EPUBDecorationCommandStyle: Sendable {
    let layout: String
    let width: String
    let element: String
    let stylesheet: String

    init(layout: String, width: String, element: String, stylesheet: String = "") {
        self.layout = layout
        self.width = width
        self.element = element
        self.stylesheet = stylesheet
    }

    fileprivate var javascriptValue: [String: Any] {
        [
            "layout": layout,
            "width": width,
            "element": element,
            "stylesheet": stylesheet,
        ]
    }
}

struct EPUBDecorationCommandItem: Sendable {
    let id: String
    let locatorJSON: String
    let style: EPUBDecorationCommandStyle

    fileprivate var javascriptValue: [String: Any] {
        [
            "id": id,
            "locator": locatorJSON,
            "style": style.javascriptValue,
        ]
    }
}

@MainActor
final class EPUBLocatorCommandBridge: NSObject, Loggable {
    private struct StoredFrame {
        let info: WKFrameInfo
        let capability: EPUBSpreadFrameCapability
    }

    /// The navigation command currently suspended inside `callAsyncJavaScript`.
    /// `cancelInFlightNavigation()` reads this to run the `invalidate(token)`
    /// round-trip in the exact frame the command is executing in.
    private struct InFlightNavigation {
        let token: EPUBLocatorCommandToken
        let frame: WKFrameInfo
    }

    private struct DecorationActivationState {
        let token: EPUBLocatorCommandToken
        let identifiers: Set<String>
    }

    private struct CommandSequenceKey: Hashable {
        let operationKind: EPUBLocatorCommandOperationKind
        let groupID: String?
    }

    private struct DecorationActivationStateKey: Hashable {
        let frameID: String
        let groupID: String
    }

    static let contentWorld = WKContentWorld.world(name: "ReaderLocatorCommands")
    private static let frameReadyMessageName = "readerLocatorFrameReady"
    private static let decorationActivatedMessageName = "readerLocatorDecorationActivated"
    private static let commandScript = "return await readerLocatorCommands.execute(command, token);"
    private static let invalidateScript = "return readerLocatorCommands.invalidate(token);"
    private static let acceptFrameCapabilityScript = "readerLocatorCommands.acceptFrameCapability(capability);"
    private static let readProgressionScript = "return readerLocatorCommands.readProgression(expectedCapability);"
    private static let visibleTextScript = """
    const range = document.caretRangeFromPoint(globalThis.innerWidth / 2, globalThis.innerHeight / 2);
    if (!range) return '';
    const text = range.commonAncestorContainer.textContent || '';
    return text.slice(0, maximumLength);
    """
    private static let commandSource: String? = {
        guard let url = Bundle.module.url(
            forResource: "readium-reader-locator-commands",
            withExtension: "js",
            subdirectory: "Assets/Static/scripts"
        ) else {
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return nil
        }
    }()

    private let publicationBaseURL: AbsoluteURL
    /// The monotonic source for the remaining-budget read and for the watchdog that
    /// bounds `callAsyncJavaScript`. Injected so a test can drive a command to its
    /// deadline without waiting out the real budget.
    private let clock: EPUBMonotonicClock
    private let webViewInstanceID = UUID().uuidString
    private var registry: EPUBLocatorFrameRegistry
    private var framesByID: [String: StoredFrame] = [:]
    private var latestSequences: [CommandSequenceKey: Int] = [:]
    private var decorationActivationStates: [DecorationActivationStateKey: DecorationActivationState] = [:]
    private var inFlightNavigation: InFlightNavigation?
    private(set) var documentEpoch = 0
    /// The unforgeable capability for the frame document the current spread
    /// generation minted. Only a frame that echoes this exact capability may
    /// register as the command target. Cleared on every new document so a
    /// delayed old document cannot register before the next capability is
    /// injected.
    private(set) var currentFrameCapability: EPUBSpreadFrameCapability?
    private weak var webView: WKWebView?
    private weak var userContentController: WKUserContentController?
    private var isMessageHandlerEnabled = false
    var onDecorationActivated: ((Any) -> Void)?

    /// Performs one location-reporting script call in `frame` (the main frame
    /// when `nil`) of the locator command world.
    typealias LocationScriptInvocation = @MainActor (
        _ webView: WKWebView,
        _ script: String,
        _ arguments: [String: Any],
        _ frame: WKFrameInfo?,
        _ completion: @escaping @MainActor @Sendable (Result<Any, any Error>) -> Void
    ) -> Void

    /// The production invocation: the completion-handler `callAsyncJavaScript`,
    /// whose completion WebKit calls exactly once, even for a call that outlives
    /// every deadline.
    static let callAsyncJavaScript: LocationScriptInvocation = { webView, script, arguments, frame, completion in
        webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: frame,
            in: contentWorld,
            completionHandler: completion
        )
    }

    /// One reflowable capability hand-off: the injection and the wait for the
    /// frame's registration, bounded together by one deadline.
    private struct HandshakeAttempt {
        enum Phase: Equatable {
            case awaitingTransport
            case injecting
            case awaitingRegistration
        }

        /// What the attempt's injection and deadline answer to. The capability
        /// cannot be the key: re-issuing it starts a new attempt while the
        /// superseded injection may still be outstanding.
        let id: Int
        let capability: EPUBSpreadFrameCapability
        let deadline: EPUBLocatorOperationDeadline
        let timer: EPUBScheduledDeadline
        var phase: Phase
    }

    /// Arms the location transport's deadlines. Location observation shares
    /// it, so its read deadlines and the transport's run on one clock.
    let deadlineScheduler: EPUBDeadlineScheduler
    private let invokeLocationScript: LocationScriptInvocation
    /// The one physical reflowable capability injection or progression read
    /// this web view may have outstanding.
    private let locationTransport: EPUBLocationTransport
    private var handshake: HandshakeAttempt?
    private var lastHandshakeID = 0

    /// Called after a frame registers under the current capability.
    var onFrameRegistered: (@MainActor (EPUBSpreadFrameCapability) -> Void)?
    /// Called with the location transport's closed, content-free outcomes.
    var onLocationTransportEvent: (@MainActor (EPUBLocationTransportEvent) -> Void)?

    /// - Parameters:
    ///   - deadlineScheduler: arms the location transport's deadlines; derived
    ///     from `clock` unless a test supplies its own.
    ///   - invokeLocationScript: reaches WebKit for location reporting; replaced
    ///     by a test to hold a call open and complete it on demand.
    @MainActor
    init(
        layout: EPUBLocatorFrameLayout,
        publicationBaseURL: AbsoluteURL,
        clock: EPUBMonotonicClock = .continuous,
        deadlineScheduler: EPUBDeadlineScheduler? = nil,
        invokeLocationScript: LocationScriptInvocation? = nil
    ) {
        self.publicationBaseURL = publicationBaseURL
        self.clock = clock
        registry = EPUBLocatorFrameRegistry(layout: layout)
        let scheduler = deadlineScheduler ?? .clock(clock)
        self.deadlineScheduler = scheduler
        self.invokeLocationScript = invokeLocationScript ?? Self.callAsyncJavaScript
        locationTransport = EPUBLocationTransport(scheduler: scheduler)
        super.init()
        // A pending hand-off takes the freed slot before any read: it carries
        // the authority every later read needs.
        locationTransport.onSlotFreed = { [weak self] in
            self?.startPendingHandshake()
        }
        locationTransport.onLateCompletion = { [weak self] in
            self?.onLocationTransportEvent?(.lateCompletion)
        }
        locationTransport.onSlotAvailable = { [weak self] in
            self?.onLocationTransportEvent?(.slotAvailable)
        }
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard let commandSource = Self.commandSource else {
            log(.error, "Locator command bundle unavailable")
            userContentController = controller
            enableMessageHandler()
            return
        }
        controller.addUserScript(WKUserScript(
            source: commandSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.contentWorld
        ))
        userContentController = controller
        enableMessageHandler()
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func enableMessageHandler() {
        guard !isMessageHandlerEnabled, let userContentController else {
            return
        }
        userContentController.add(
            self,
            contentWorld: Self.contentWorld,
            name: Self.frameReadyMessageName
        )
        userContentController.add(
            self,
            contentWorld: Self.contentWorld,
            name: Self.decorationActivatedMessageName
        )
        isMessageHandlerEnabled = true
    }

    func disableMessageHandler() {
        guard isMessageHandlerEnabled, let userContentController else {
            return
        }
        userContentController.removeScriptMessageHandler(
            forName: Self.frameReadyMessageName,
            contentWorld: Self.contentWorld
        )
        userContentController.removeScriptMessageHandler(
            forName: Self.decorationActivatedMessageName,
            contentWorld: Self.contentWorld
        )
        isMessageHandlerEnabled = false
    }

    /// Starts a new document. An outstanding location call keeps the transport
    /// until WebKit completes it; a read's answer then reports `.cancelled`.
    @MainActor
    func beginDocument() {
        documentEpoch += 1
        currentFrameCapability = nil
        framesByID.removeAll(keepingCapacity: true)
        registry.removeAll()
        latestSequences.removeAll(keepingCapacity: true)
        decorationActivationStates.removeAll(keepingCapacity: true)
        inFlightNavigation = nil
        endHandshake(reporting: nil)
    }

    @MainActor
    func invalidateDocument() {
        beginDocument()
    }

    /// Revokes the current frame capability and drops all frame registration so a
    /// delayed, reloaded, or self-navigated document can never register or be
    /// selected as the command target after the spread is torn down.
    ///
    /// Wired to `EPUBSpreadView.clear()` (removal, disappearance, deinit). Unlike
    /// `beginDocument()` it does not advance the command epoch: `clear()` is a
    /// teardown, not the start of a new document, and the readiness authority
    /// already owns in-flight command cancellation (`readiness.invalidate()`).
    /// The JavaScript side self-revokes its own copy on `pagehide` (see
    /// `reader-locator-commands.js`), covering a child self-navigation or reload
    /// the native spread load never observes.
    @MainActor
    func revokeFrameCapability() {
        currentFrameCapability = nil
        framesByID.removeAll(keepingCapacity: true)
        registry.removeAll()
        endHandshake(reporting: nil)
        locationTransport.close()
    }

    /// Publishes the capability the current spread generation minted and injects
    /// it into the main frame's *current* document via `callAsyncJavaScript(in: nil)`.
    /// WebKit runs the injection in whichever document currently occupies the
    /// main frame, so a superseded or old document instance can never receive it.
    /// Reflowable content is the main frame and registers directly; a fixed-layout
    /// wrapper is the main frame and the JS side forwards the capability one hop to
    /// its child resource frame (see `forwardCapabilityToChildFrames` in
    /// `reader-locator-commands.js`), which is where registration happens for that
    /// layout. Either way only the current document tree can echo it back.
    ///
    /// A reflowable hand-off shares the location transport: it waits for an
    /// outstanding call rather than adding a second one, injects the latest
    /// capability once the slot frees, and reports an attempt that ends without
    /// a registration through `onLocationTransportEvent`. Registration, not the
    /// injection's completion, is what authorizes the frame.
    @MainActor
    func setFrameCapability(_ capability: EPUBSpreadFrameCapability) {
        currentFrameCapability = capability
        guard let webView else {
            return
        }
        guard registry.layout == .fixed else {
            beginHandshake(for: capability)
            return
        }
        // Bounded even though nothing awaits it: a wedged page would otherwise retain
        // this task — and through it the bridge and the capability — for the process
        // lifetime, once per document.
        let deadline = EPUBLocatorOperationDeadline(
            startingAt: clock.now(),
            budget: .milliseconds(Self.totalCommandDeadlineMilliseconds)
        )
        // Captured by value so the task retains no reference to the bridge.
        let injectionClock = clock
        Task { @MainActor in
            _ = try? await EPUBLocatorCommandWatchdog.run(until: deadline, clock: injectionClock) {
                _ = try await webView.callAsyncJavaScript(
                    Self.acceptFrameCapabilityScript,
                    arguments: ["capability": capability.id.uuidString],
                    in: nil,
                    contentWorld: Self.contentWorld
                )
            }
        }
    }

    /// Why a progression read did not start. When it does start, its
    /// completion receives exactly one outcome unless the spread is cleared
    /// first.
    enum ProgressionReadStart: Equatable {
        case started
        /// Another location call is still outstanding.
        case transportOccupied
        /// No frame is registered and selectable under the current capability.
        case frameUnavailable
        case deadlinePassed
    }

    /// Reads the viewport of the reflowable main frame registered under the
    /// current capability, in that frame and the locator command world.
    ///
    /// The capability alone does not identify the resource frame (a direct
    /// same-origin child holds it too), so the read runs in the frame the
    /// registry selected, and its answer counts only if the capability and that
    /// selection are both unchanged when it arrives.
    @MainActor
    func readProgression(
        targetHREF: AnyURL,
        deadline: EPUBLocatorOperationDeadline,
        completion: @escaping @MainActor (EPUBProgressionReadOutcome) -> Void
    ) -> ProgressionReadStart {
        guard !locationTransport.isOccupied else {
            return .transportOccupied
        }
        guard
            let targetURL = publicationBaseURL.resolve(targetHREF)?.url,
            let targetKey = frameKey(for: targetURL),
            let capability = currentFrameCapability,
            case let .selected(frameID) = registry.select(href: targetKey, capability: capability),
            let storedFrame = framesByID[frameID],
            let webView
        else {
            return .frameUnavailable
        }
        let invoke = invokeLocationScript
        let started = locationTransport.start(
            until: deadline,
            invocation: { done in
                invoke(
                    webView,
                    Self.readProgressionScript,
                    ["expectedCapability": capability.id.uuidString],
                    storedFrame.info,
                    done
                )
            },
            deliver: { [weak self] delivery in
                guard let self else {
                    return
                }
                completion(progressionReadOutcome(
                    delivery,
                    targetKey: targetKey,
                    frameID: frameID,
                    capability: capability
                ))
            }
        )
        return started ? .started : .deadlinePassed
    }

    /// Currency outranks the answer: a read that completes after its capability
    /// or selected frame changed is `.cancelled`, whatever it says. A new
    /// document clears the registry, so the selection check covers it too.
    @MainActor
    private func progressionReadOutcome(
        _ delivery: EPUBLocationTransport.Delivery,
        targetKey: String,
        frameID: String,
        capability: EPUBSpreadFrameCapability
    ) -> EPUBProgressionReadOutcome {
        guard case let .completed(result) = delivery else {
            return .expired
        }
        guard
            currentFrameCapability == capability,
            registry.select(href: targetKey, capability: capability) == .selected(frameID)
        else {
            return .cancelled
        }
        switch result {
        case .failure:
            return .failed
        case let .success(value):
            return .decoding(value, expecting: capability)
        }
    }

    /// Replaces any earlier attempt: only the latest capability is worth
    /// injecting, and it waits for the transport if a call is outstanding.
    @MainActor
    private func beginHandshake(for capability: EPUBSpreadFrameCapability) {
        endHandshake(reporting: nil)
        lastHandshakeID += 1
        let id = lastHandshakeID
        let deadline = EPUBLocatorOperationDeadline(
            startingAt: deadlineScheduler.now(),
            budget: .milliseconds(Self.totalCommandDeadlineMilliseconds)
        )
        let timer = deadlineScheduler.schedule(deadline.expiresAt) { [weak self] in
            self?.handshakeDeadlineDidPass(attempt: id)
        }
        handshake = HandshakeAttempt(
            id: id,
            capability: capability,
            deadline: deadline,
            timer: timer,
            phase: .awaitingTransport
        )
        startPendingHandshake()
    }

    @MainActor
    private func startPendingHandshake() {
        guard
            let attempt = handshake,
            attempt.phase == .awaitingTransport,
            let webView
        else {
            return
        }
        let id = attempt.id
        let capability = attempt.capability
        let invoke = invokeLocationScript
        // The attempt is marked injecting before the call starts: an answer
        // delivered inside the invocation frees the slot, and this attempt
        // must not take it again.
        handshake?.phase = .injecting
        let started = locationTransport.start(
            until: attempt.deadline,
            invocation: { done in
                invoke(
                    webView,
                    Self.acceptFrameCapabilityScript,
                    ["capability": capability.id.uuidString],
                    nil,
                    done
                )
            },
            deliver: { [weak self] delivery in
                self?.handshakeInjectionDidFinish(delivery, attempt: id)
            }
        )
        if !started {
            handshake?.phase = .awaitingTransport
        }
    }

    /// The attempt's own deadline reports an injection that never answered, so
    /// the transport's `.expired` is not a second verdict here.
    @MainActor
    private func handshakeInjectionDidFinish(
        _ delivery: EPUBLocationTransport.Delivery,
        attempt id: Int
    ) {
        guard
            case let .completed(result) = delivery,
            handshake?.id == id
        else {
            return
        }
        switch result {
        case .success:
            handshake?.phase = .awaitingRegistration
        case .failure:
            endHandshake(reporting: .injectionFailed)
        }
    }

    @MainActor
    private func handshakeDeadlineDidPass(attempt id: Int) {
        guard let attempt = handshake, attempt.id == id else {
            return
        }
        switch attempt.phase {
        case .awaitingTransport:
            endHandshake(reporting: .transportOccupied)
        case .injecting:
            endHandshake(reporting: .injectionUnresponsive)
        case .awaitingRegistration:
            endHandshake(reporting: .registrationMissing)
        }
    }

    @MainActor
    private func endHandshake(reporting failure: EPUBHandshakeFailure?) {
        guard let attempt = handshake else {
            return
        }
        attempt.timer.cancel()
        handshake = nil
        if let failure {
            onLocationTransportEvent?(.handshakeFailed(attempt.capability, failure))
        }
    }

    // Test-only: the number of frames currently registered as eligible command
    // targets. Lets an integration test await the capability-handshake round-trip
    // (`setFrameCapability` → JS echo → `didReceive` registration) before issuing
    // a command — the deterministic stand-in for a live spread's readiness gate.
    //
    // Compiled ONLY under `RENDER_FAITHFUL_NAV_TESTING` (see `Package.swift`).
    // `internal` is not a shipping-binary guarantee either — an internal symbol is
    // still compiled into the framework — so this hook is gated exactly like the
    // `@_spi(Testing)` ones. Phase-only: a count, never a frame or its contents.
    #if RENDER_FAITHFUL_NAV_TESTING
        var registeredFrameCountForTesting: Int {
            framesByID.count
        }
    #endif

    /// - Parameter deadline: the operation-wide deadline minted by the caller at
    ///   operation start. The command spends what remains of it; it never mints its
    ///   own, so a navigation that already hopped resources and waited for readiness
    ///   arrives here with correspondingly less time rather than a fresh allowance.
    func navigate(
        locatorJSON: String,
        targetHREF: AnyURL,
        animated: Bool,
        deadline: EPUBLocatorOperationDeadline
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(
            for: .navigation,
            budgetMilliseconds: deadline.remainingMilliseconds(at: clock.now())
        )

        guard !Task.isCancelled else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }

        let payload: EPUBLocatorCommandPayload
        do {
            payload = try EPUBLocatorCommandDecoder.decode(locatorJSON)
        } catch let rejection as EPUBLocatorCommandRejection {
            return EPUBLocatorCommandResult(
                token: token,
                outcome: .miss,
                reason: EPUBLocatorCommandReason(rawValue: rejection.rawValue) ?? .invalidResult
            )
        } catch {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidResult)
        }

        guard
            let targetURL = publicationBaseURL.resolve(targetHREF)?.url,
            let targetKey = frameKey(for: targetURL),
            locatorHREF(payload.href, targets: targetKey)
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidField)
        }

        let selectedID: String
        switch registry.select(href: targetKey, capability: currentFrameCapability) {
        case let .selected(id):
            selectedID = id
        case let .miss(reason):
            return EPUBLocatorCommandResult(
                token: token,
                outcome: .miss,
                reason: EPUBLocatorCommandReason(rawValue: reason.rawValue) ?? .invalidResult
            )
        }

        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let webView
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .staleDocument)
        }

        let command: [String: Any] = [
            "kind": "navigateLocator",
            "payload": locatorJSON,
            "animated": animated,
        ]

        // Record the suspended command so a superseding request's relay can
        // abort it in the exact frame it is running in. Cleared on every exit,
        // but only if a newer navigation has not already replaced it.
        inFlightNavigation = InFlightNavigation(token: token, frame: storedFrame.info)
        defer {
            if inFlightNavigation?.token == token {
                inFlightNavigation = nil
            }
        }

        // The command's own budget lives inside the script, which cannot enforce it
        // while the page is not running it. The watchdog is what makes the operation
        // deadline true at this boundary: it abandons a call that never returns
        // instead of suspending on it forever. Decoding happens inside the guarded
        // body because a task-group-free race can only carry a `Sendable` value out,
        // and `Any?` is not one.
        let decoded: EPUBLocatorCommandResult
        do {
            decoded = try await EPUBLocatorCommandWatchdog.run(
                until: deadline,
                clock: clock
            ) {
                let rawResult = try await webView.callAsyncJavaScript(
                    Self.commandScript,
                    arguments: ["command": command, "token": token.javascriptValue],
                    in: storedFrame.info,
                    contentWorld: Self.contentWorld
                )
                return Self.decodeResult(rawResult, expectedToken: token)
            }
        } catch {
            return Self.failure(for: error, token: token, isCurrent: isCurrent(token))
        }

        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        return decoded
    }

    /// Positively cancels the navigation command currently suspended inside
    /// `callAsyncJavaScript`, if any, by running the fixed-source
    /// `invalidate(token)` relay in the same frame and content world. The
    /// JavaScript aborts its `AbortController`, so the suspended command
    /// unwinds to `cancelled` promptly instead of after its frame timeout. A
    /// detached frame (the round-trip throws) means the predecessor is already
    /// being torn down, so there is nothing to cancel.
    ///
    /// - Parameter deadline: bounds the relay itself. The successor awaits this
    ///   round-trip BEFORE its own bounded predecessor acknowledgement, so an
    ///   unbounded relay into a wedged page would stall the successor indefinitely —
    ///   the acknowledgement bound below it cannot help, because the wait that
    ///   precedes it never returns.
    func cancelInFlightNavigation(deadline: EPUBLocatorOperationDeadline) async {
        guard let inFlight = inFlightNavigation, let webView else {
            return
        }
        _ = try? await EPUBLocatorCommandWatchdog.run(until: deadline, clock: clock) {
            _ = try await webView.callAsyncJavaScript(
                Self.invalidateScript,
                arguments: ["token": inFlight.token.javascriptValue],
                in: inFlight.frame,
                contentWorld: Self.contentWorld
            )
        }
    }

    /// - Parameter deadline: the deadline of the enclosing decoration operation —
    ///   one apply/rollback transaction, or one replay sweep — NOT of this single
    ///   resource. A decoration operation spans every affected resource, so minting
    ///   per command made the operation's worst case the per-command budget times
    ///   the number of preloaded resources it touched, and doubled again by
    ///   rollback. Sharing one deadline is what bounds the transaction itself.
    func replaceDecorations(
        _ decorations: [EPUBDecorationCommandItem],
        in groupID: String,
        targetHREF: AnyURL,
        activable: Bool,
        deadline: EPUBLocatorOperationDeadline
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(
            for: .decoration,
            groupID: groupID,
            budgetMilliseconds: deadline.remainingMilliseconds(at: clock.now())
        )

        guard !Task.isCancelled else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        guard
            groupID.utf16.count <= 4 * 1024,
            decorations.count <= 4096,
            Set(decorations.map(\.id)).count == decorations.count,
            let targetURL = publicationBaseURL.resolve(targetHREF)?.url,
            let targetKey = frameKey(for: targetURL)
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidField)
        }

        let validLayouts: Set = ["bounds", "boxes"]
        let validWidths: Set = ["wrap", "bounds", "viewport", "page"]
        var totalStringUnits = groupID.utf16.count
        for decoration in decorations {
            let payload: EPUBLocatorCommandPayload
            do {
                payload = try EPUBLocatorCommandDecoder.decode(decoration.locatorJSON)
            } catch let rejection as EPUBLocatorCommandRejection {
                return EPUBLocatorCommandResult(
                    token: token,
                    outcome: .miss,
                    reason: EPUBLocatorCommandReason(rawValue: rejection.rawValue) ?? .invalidResult
                )
            } catch {
                return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidResult)
            }

            let style = decoration.style
            guard
                decoration.id.utf16.count <= 4 * 1024,
                validLayouts.contains(style.layout),
                validWidths.contains(style.width),
                style.element.utf16.count <= 64 * 1024,
                style.stylesheet.utf16.count <= 64 * 1024,
                locatorHREF(payload.href, targets: targetKey)
            else {
                return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidField)
            }
            totalStringUnits += decoration.id.utf16.count
                + decoration.locatorJSON.utf16.count
                + style.element.utf16.count
                + style.stylesheet.utf16.count
            guard totalStringUnits <= 2 * 1024 * 1024 else {
                return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidField)
            }
        }

        let selectedID: String
        switch registry.select(href: targetKey, capability: currentFrameCapability) {
        case let .selected(id):
            selectedID = id
        case let .miss(reason):
            return EPUBLocatorCommandResult(
                token: token,
                outcome: .miss,
                reason: EPUBLocatorCommandReason(rawValue: reason.rawValue) ?? .invalidResult
            )
        }

        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let webView
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .staleDocument)
        }

        let command: [String: Any] = [
            "kind": "replaceDecorationGroup",
            "groupID": groupID,
            "decorations": decorations.map(\.javascriptValue),
            "activable": activable,
        ]
        let decoded: EPUBLocatorCommandResult
        do {
            decoded = try await EPUBLocatorCommandWatchdog.run(
                until: deadline,
                clock: clock
            ) {
                let rawResult = try await webView.callAsyncJavaScript(
                    Self.commandScript,
                    arguments: ["command": command, "token": token.javascriptValue],
                    in: storedFrame.info,
                    contentWorld: Self.contentWorld
                )
                return Self.decodeResult(rawResult, expectedToken: token)
            }
        } catch {
            return Self.failure(for: error, token: token, isCurrent: isCurrent(token))
        }

        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        let result = decoded
        if result.outcome == .applied {
            let key = DecorationActivationStateKey(frameID: selectedID, groupID: groupID)
            if activable {
                decorationActivationStates[key] = DecorationActivationState(
                    token: token,
                    identifiers: Set(decorations.map(\.id))
                )
            } else {
                decorationActivationStates[key] = nil
            }
        }
        return result
    }

    /// - Parameter deadline: the deadline of the enclosing uniqueness check. Owned by
    ///   the caller for the same reason navigation's is: the check is one step of a
    ///   larger operation (a citation landing that then decorates), and a step that
    ///   mints its own allowance is a step that can re-arm a spent budget.
    func validateUniqueTextMatch(
        locatorJSON: String,
        targetHREF: AnyURL,
        cssSelector: String?,
        deadline: EPUBLocatorOperationDeadline
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(
            for: .validation,
            budgetMilliseconds: deadline.remainingMilliseconds(at: clock.now())
        )

        guard !Task.isCancelled else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        let payload: EPUBLocatorCommandPayload
        do {
            payload = try EPUBLocatorCommandDecoder.decode(locatorJSON)
        } catch let rejection as EPUBLocatorCommandRejection {
            return EPUBLocatorCommandResult(
                token: token,
                outcome: .miss,
                reason: EPUBLocatorCommandReason(rawValue: rejection.rawValue) ?? .invalidResult
            )
        } catch {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidResult)
        }
        guard
            cssSelector?.utf16.count ?? 0 <= 8 * 1024,
            let targetURL = publicationBaseURL.resolve(targetHREF)?.url,
            let targetKey = frameKey(for: targetURL),
            locatorHREF(payload.href, targets: targetKey)
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .invalidField)
        }

        let selectedID: String
        switch registry.select(href: targetKey, capability: currentFrameCapability) {
        case let .selected(id):
            selectedID = id
        case let .miss(reason):
            return EPUBLocatorCommandResult(
                token: token,
                outcome: .miss,
                reason: EPUBLocatorCommandReason(rawValue: reason.rawValue) ?? .invalidResult
            )
        }
        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let webView
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .staleDocument)
        }

        var command: [String: Any] = [
            "kind": "validateUniqueTextMatch",
            "payload": locatorJSON,
        ]
        if let cssSelector {
            command["cssSelector"] = cssSelector
        }
        let decoded: EPUBLocatorCommandResult
        do {
            decoded = try await EPUBLocatorCommandWatchdog.run(
                until: deadline,
                clock: clock
            ) {
                let rawResult = try await webView.callAsyncJavaScript(
                    Self.commandScript,
                    arguments: ["command": command, "token": token.javascriptValue],
                    in: storedFrame.info,
                    contentWorld: Self.contentWorld
                )
                return Self.decodeResult(rawResult, expectedToken: token)
            }
        } catch {
            return Self.failure(for: error, token: token, isCurrent: isCurrent(token))
        }
        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        return decoded
    }

    /// - Parameter deadline: bounds the extraction. A read has no token to supersede
    ///   and no outcome to classify, so without a deadline a wedged page would suspend
    ///   the caller indefinitely on a call that reports nothing either way.
    func visibleText(
        targetHREF: AnyURL,
        maximumLength: Int,
        deadline: EPUBLocatorOperationDeadline
    ) async -> String? {
        guard
            (1 ... 4096).contains(maximumLength),
            let targetURL = publicationBaseURL.resolve(targetHREF)?.url,
            let targetKey = frameKey(for: targetURL)
        else {
            return nil
        }
        let selectedID: String
        switch registry.select(href: targetKey, capability: currentFrameCapability) {
        case let .selected(id):
            selectedID = id
        case .miss:
            return nil
        }
        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let webView
        else {
            return nil
        }
        let text: String?
        do {
            text = try await EPUBLocatorCommandWatchdog.run(
                until: deadline,
                clock: clock
            ) {
                let rawValue = try await webView.callAsyncJavaScript(
                    Self.visibleTextScript,
                    arguments: ["maximumLength": maximumLength],
                    in: storedFrame.info,
                    contentWorld: Self.contentWorld
                )
                return rawValue as? String
            }
        } catch {
            return nil
        }
        guard let text, text.utf16.count <= maximumLength else {
            return nil
        }
        return text
    }

    /// The budget one whole operation gets, taken from the frozen
    /// `locatorNavigationBudgets.totalCommandDeadlineMilliseconds` and pinned across
    /// manifest, Swift, and script by `check-locator-command-budget-agreement.sh`.
    ///
    /// It is the budget of an OPERATION, not of a command: a navigation spends it
    /// across the cross-resource hop, page identity, readiness, and the bridge run; a
    /// decoration transaction spends it across every affected resource plus rollback;
    /// a replay sweep spends it across the whole sweep. Every command path now takes
    /// its deadline from its caller, so no operation's cost can grow with the number
    /// of resources it happens to touch.
    static let totalCommandDeadlineMilliseconds = 5000

    /// The single place a failed command call is classified, so the precedence
    /// cannot drift between the command paths.
    ///
    /// Cancellation and receipt currency outrank every other classification: a
    /// superseded or torn-down command reports `.cancelled`, never a miss invented
    /// from how its abandoned call happened to fail. Below that, a call that never
    /// returned (`Expired`) stays distinct from one that returned an error.
    private static func failure(
        for error: any Error,
        token: EPUBLocatorCommandToken,
        isCurrent: Bool
    ) -> EPUBLocatorCommandResult {
        guard !Task.isCancelled, isCurrent, !(error is CancellationError) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        return EPUBLocatorCommandResult(
            token: token,
            outcome: .miss,
            reason: error is EPUBLocatorCommandWatchdog.Expired
                ? .commandUnresponsive
                : .webKitFailure
        )
    }

    private func nextToken(
        for operationKind: EPUBLocatorCommandOperationKind,
        groupID: String? = nil,
        budgetMilliseconds: Int
    ) -> EPUBLocatorCommandToken {
        let key = CommandSequenceKey(operationKind: operationKind, groupID: groupID)
        let sequence = (latestSequences[key] ?? 0) + 1
        latestSequences[key] = sequence
        return EPUBLocatorCommandToken(
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            operationKind: operationKind,
            sequence: sequence,
            groupID: groupID,
            budgetMilliseconds: max(0, budgetMilliseconds)
        )
    }

    private func isCurrent(_ token: EPUBLocatorCommandToken) -> Bool {
        guard
            token.webViewInstanceID == webViewInstanceID,
            token.documentEpoch == documentEpoch
        else {
            return false
        }
        let key = CommandSequenceKey(
            operationKind: token.operationKind,
            groupID: token.groupID
        )
        return latestSequences[key] == token.sequence
    }

    private func locatorHREF(_ href: String, targets targetKey: String) -> Bool {
        if href.isEmpty || href == "#" {
            return true
        }
        guard
            let locatorHREF = AnyURL(string: href),
            let locatorURL = publicationBaseURL.resolve(locatorHREF)?.url
        else {
            return false
        }
        return frameKey(for: locatorURL) == targetKey
    }

    private func frameKey(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private func validatedDecorationActivation(
        _ message: WKScriptMessage
    ) -> [String: Any]? {
        guard
            let body = message.body as? [String: Any],
            let groupID = body["group"] as? String,
            groupID.utf16.count <= 4 * 1024,
            let requestURL = message.frameInfo.request.url,
            publicationBaseURL.relativize(requestURL) != nil,
            let frameKey = frameKey(for: requestURL),
            case let .selected(selectedID) = registry.select(
                href: frameKey,
                capability: currentFrameCapability
            )
        else {
            return nil
        }

        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let state = decorationActivationStates[
                DecorationActivationStateKey(frameID: selectedID, groupID: groupID)
            ]
        else {
            return nil
        }
        return Self.validatedDecorationActivationBody(
            body,
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            expectedToken: state.token,
            identifiers: state.identifiers
        )
    }

    /// Validates the publisher-controlled activation payload against the native
    /// state created by the last successful activable decoration command.
    ///
    /// Kept pure so the authorization contract can be covered without fabricating
    /// a `WKScriptMessage`, whose frame-bound initializer WebKit does not expose.
    static func validatedDecorationActivationBody(
        _ body: [String: Any],
        webViewInstanceID: String,
        documentEpoch: Int,
        expectedToken: EPUBLocatorCommandToken,
        identifiers: Set<String>
    ) -> [String: Any]? {
        guard
            Set(body.keys) == ["id", "group", "token", "rect", "click"],
            let identifier = body["id"] as? String,
            identifier.utf16.count <= 4 * 1024,
            identifiers.contains(identifier),
            let groupID = body["group"] as? String,
            groupID.utf16.count <= 4 * 1024,
            let tokenValue = body["token"] as? [String: Any],
            let token = decodeToken(tokenValue),
            token.webViewInstanceID == webViewInstanceID,
            token.documentEpoch == documentEpoch,
            token.operationKind == .decoration,
            token.groupID == groupID,
            expectedToken.authorizationIdentity == token.authorizationIdentity,
            validActivationRect(body["rect"]),
            validActivationClick(body["click"])
        else {
            return nil
        }
        return body
    }

    private static func validActivationRect(_ value: Any?) -> Bool {
        guard
            let rect = value as? [String: Any],
            Set(rect.keys) == ["left", "top", "width", "height"],
            let left = boundedFiniteDouble(rect["left"]),
            let top = boundedFiniteDouble(rect["top"]),
            let width = boundedFiniteDouble(rect["width"]),
            let height = boundedFiniteDouble(rect["height"]),
            width >= 0,
            height >= 0
        else {
            return false
        }
        return abs(left) <= 10_000_000 && abs(top) <= 10_000_000
    }

    private static func validActivationClick(_ value: Any?) -> Bool {
        guard
            let click = value as? [String: Any],
            Set(click.keys) == ["defaultPrevented", "x", "y", "targetElement"],
            isBoolean(click["defaultPrevented"]),
            let x = boundedFiniteDouble(click["x"]),
            let y = boundedFiniteDouble(click["y"]),
            abs(x) <= 10_000_000,
            abs(y) <= 10_000_000,
            let targetElement = click["targetElement"] as? String,
            targetElement.utf16.count <= 4 * 1024
        else {
            return false
        }
        return true
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func boundedFiniteDouble(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, abs(double) <= 10_000_000 else { return nil }
        return double
    }

    private static func decodeResult(
        _ rawValue: Any?,
        expectedToken: EPUBLocatorCommandToken
    ) -> EPUBLocatorCommandResult {
        guard
            let value = rawValue as? [String: Any],
            let tokenValue = value["token"] as? [String: Any],
            let echoedToken = decodeToken(tokenValue),
            echoedToken == expectedToken,
            let outcomeValue = value["outcome"] as? String,
            let outcome = EPUBLocatorCommandOutcome(rawValue: outcomeValue),
            let reasonValue = value["reasonCode"] as? String,
            let reason = EPUBLocatorCommandReason(rawValue: reasonValue)
        else {
            return EPUBLocatorCommandResult(
                token: expectedToken,
                outcome: .miss,
                reason: .invalidResult
            )
        }
        return EPUBLocatorCommandResult(token: echoedToken, outcome: outcome, reason: reason)
    }

    private static func decodeToken(_ value: [String: Any]) -> EPUBLocatorCommandToken? {
        guard
            let webViewInstanceID = value["webViewInstanceID"] as? String,
            let documentEpoch = exactInteger(value["documentEpoch"]),
            let operationKindValue = value["operationKind"] as? String,
            let operationKind = EPUBLocatorCommandOperationKind(rawValue: operationKindValue),
            let sequence = exactInteger(value["sequence"])
        else {
            return nil
        }
        let groupID: String?
        if let rawGroupID = value["groupID"] {
            guard let decodedGroupID = rawGroupID as? String else {
                return nil
            }
            groupID = decodedGroupID
        } else {
            groupID = nil
        }
        return EPUBLocatorCommandToken(
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            operationKind: operationKind,
            sequence: sequence,
            groupID: groupID,
            // The script echoes the normalized token verbatim, so the budget
            // round-trips. Decoding it keeps an echoed token `==` to the minted
            // one; defaulting it would silently break that equality and with it
            // the relay's token-identity guards.
            budgetMilliseconds: exactInteger(value["budgetMilliseconds"]) ?? 0
        )
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= 0, double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }
}

extension EPUBLocatorCommandBridge {
    /// The parameters for registering a frame that passed the capability gate.
    struct FrameReadyRegistration: Equatable {
        let id: String
        let key: String
        let capability: EPUBSpreadFrameCapability
        let isSameOrigin: Bool
    }

    /// The capability gate for an incoming frame-ready announcement. Returns the
    /// registration parameters only when the announcement echoes the exact
    /// current capability for its own request URL; `nil` rejects it — no current
    /// capability (a delayed old document that never received one, or a spread
    /// torn down by `revokeFrameCapability()`), a stale or forged capability, an
    /// oversized or malformed href, or an href that does not match the frame's
    /// own request URL. No book prose crosses this seam: the href is a resource
    /// path and the capability is an opaque UUID string.
    func resolveFrameReady(
        announcedHREF: String?,
        announcedCapability: String?,
        requestURL: URL?,
        frameID: String
    ) -> FrameReadyRegistration? {
        guard
            let announcedHREF,
            announcedHREF.utf16.count <= 4 * 1024,
            let announcedURL = URL(string: announcedHREF),
            let requestURL,
            let announcedKey = frameKey(for: announcedURL),
            let requestKey = frameKey(for: requestURL),
            announcedKey == requestKey,
            let capability = currentFrameCapability,
            let announcedCapability,
            announcedCapability == capability.id.uuidString
        else {
            return nil
        }
        return FrameReadyRegistration(
            id: frameID,
            key: requestKey,
            capability: capability,
            isSameOrigin: publicationBaseURL.relativize(requestURL) != nil
        )
    }
}

extension EPUBLocatorCommandBridge: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == Self.decorationActivatedMessageName {
            if let activation = validatedDecorationActivation(message) {
                onDecorationActivated?(activation)
            }
            return
        }
        guard
            message.name == Self.frameReadyMessageName,
            let body = message.body as? [String: Any]
        else {
            return
        }

        let frameID = String(UInt(bitPattern: ObjectIdentifier(message.frameInfo)), radix: 16)
        guard let registration = resolveFrameReady(
            announcedHREF: body["href"] as? String,
            announcedCapability: body["capability"] as? String,
            requestURL: message.frameInfo.request.url,
            frameID: frameID
        ) else {
            return
        }

        let replaced = registry.register(
            id: registration.id,
            href: registration.key,
            capability: registration.capability,
            isMainFrame: message.frameInfo.isMainFrame,
            isSameOrigin: registration.isSameOrigin
        )
        for replacedID in replaced {
            framesByID[replacedID] = nil
        }
        framesByID[registration.id] = StoredFrame(
            info: message.frameInfo,
            capability: registration.capability
        )
        // A child frame holding the forwarded capability registers too; only
        // the frame commands and reads would select has completed the hand-off.
        guard
            registry.select(href: registration.key, capability: registration.capability)
            == .selected(registration.id)
        else {
            return
        }
        if handshake?.capability == registration.capability {
            endHandshake(reporting: nil)
        }
        onFrameRegistered?(registration.capability)
    }
}
