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

    mutating func register(
        id: String,
        href: String,
        capability: EPUBSpreadFrameCapability,
        isMainFrame: Bool,
        isSameOrigin: Bool
    ) {
        entriesByID[id] = Entry(
            id: id,
            href: href,
            capability: capability,
            isMainFrame: isMainFrame,
            isSameOrigin: isSameOrigin
        )
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

    init(layout: EPUBLocatorFrameLayout, publicationBaseURL: AbsoluteURL) {
        self.publicationBaseURL = publicationBaseURL
        registry = EPUBLocatorFrameRegistry(layout: layout)
        super.init()
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

    func beginDocument() {
        documentEpoch += 1
        currentFrameCapability = nil
        framesByID.removeAll(keepingCapacity: true)
        registry.removeAll()
        latestSequences.removeAll(keepingCapacity: true)
        decorationActivationStates.removeAll(keepingCapacity: true)
        inFlightNavigation = nil
    }

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
    func revokeFrameCapability() {
        currentFrameCapability = nil
        framesByID.removeAll(keepingCapacity: true)
        registry.removeAll()
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
    func setFrameCapability(_ capability: EPUBSpreadFrameCapability) {
        currentFrameCapability = capability
        guard let webView else {
            return
        }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                Self.acceptFrameCapabilityScript,
                arguments: ["capability": capability.id.uuidString],
                in: nil,
                contentWorld: Self.contentWorld
            )
        }
    }

    /// Test-only: the number of frames currently registered as eligible command
    /// targets. Lets an integration test await the capability-handshake round-trip
    /// (`setFrameCapability` → JS echo → `didReceive` registration) before issuing
    /// a command — the deterministic stand-in for a live spread's readiness gate.
    var registeredFrameCountForTesting: Int {
        framesByID.count
    }

    func navigate(
        locatorJSON: String,
        targetHREF: AnyURL,
        animated: Bool
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(for: .navigation)

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

        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.commandScript,
                arguments: ["command": command, "token": token.javascriptValue],
                in: storedFrame.info,
                contentWorld: Self.contentWorld
            )
        } catch {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .webKitFailure)
        }

        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        return Self.decodeResult(rawResult, expectedToken: token)
    }

    /// Positively cancels the navigation command currently suspended inside
    /// `callAsyncJavaScript`, if any, by running the fixed-source
    /// `invalidate(token)` relay in the same frame and content world. The
    /// JavaScript aborts its `AbortController`, so the suspended command
    /// unwinds to `cancelled` promptly instead of after its frame timeout. A
    /// detached frame (the round-trip throws) means the predecessor is already
    /// being torn down, so there is nothing to cancel.
    func cancelInFlightNavigation() async {
        guard let inFlight = inFlightNavigation, let webView else {
            return
        }
        _ = try? await webView.callAsyncJavaScript(
            Self.invalidateScript,
            arguments: ["token": inFlight.token.javascriptValue],
            in: inFlight.frame,
            contentWorld: Self.contentWorld
        )
    }

    func replaceDecorations(
        _ decorations: [EPUBDecorationCommandItem],
        in groupID: String,
        targetHREF: AnyURL,
        activable: Bool
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(for: .decoration, groupID: groupID)

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
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.commandScript,
                arguments: ["command": command, "token": token.javascriptValue],
                in: storedFrame.info,
                contentWorld: Self.contentWorld
            )
        } catch {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .webKitFailure)
        }

        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        let result = Self.decodeResult(rawResult, expectedToken: token)
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

    func validateUniqueTextMatch(
        locatorJSON: String,
        targetHREF: AnyURL,
        cssSelector: String?
    ) async -> EPUBLocatorCommandResult {
        let token = nextToken(for: .validation)

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
        let rawResult: Any?
        do {
            rawResult = try await webView.callAsyncJavaScript(
                Self.commandScript,
                arguments: ["command": command, "token": token.javascriptValue],
                in: storedFrame.info,
                contentWorld: Self.contentWorld
            )
        } catch {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .webKitFailure)
        }
        guard !Task.isCancelled, isCurrent(token) else {
            return EPUBLocatorCommandResult(token: token, outcome: .cancelled, reason: .staleToken)
        }
        return Self.decodeResult(rawResult, expectedToken: token)
    }

    func visibleText(targetHREF: AnyURL, maximumLength: Int) async -> String? {
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
        let rawValue: Any?
        do {
            rawValue = try await webView.callAsyncJavaScript(
                Self.visibleTextScript,
                arguments: ["maximumLength": maximumLength],
                in: storedFrame.info,
                contentWorld: Self.contentWorld
            )
        } catch {
            return nil
        }
        guard let text = rawValue as? String, text.utf16.count <= maximumLength else {
            return nil
        }
        return text
    }

    /// Remaining budget handed to a command whose caller has not yet supplied an
    /// operation-wide deadline, taken from the frozen
    /// `locatorNavigationBudgets.totalCommandDeadlineMilliseconds`.
    ///
    /// This is the per-command floor of the contract, not its finished form: a
    /// caller that spans several commands (a cross-resource hop followed by its
    /// landing) must mint ONE deadline at operation start and pass the remainder
    /// into each command, otherwise the budget still restarts per resource.
    /// Threading that caller-owned deadline down from the navigator and the
    /// navigation queue is the remaining half of the single-deadline contract.
    static let totalCommandDeadlineMilliseconds = 5000

    private func nextToken(
        for operationKind: EPUBLocatorCommandOperationKind,
        groupID: String? = nil,
        budgetMilliseconds: Int = EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds
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
            Set(body.keys) == ["id", "group", "token", "rect", "click"],
            let identifier = body["id"] as? String,
            identifier.utf16.count <= 4 * 1024,
            let groupID = body["group"] as? String,
            groupID.utf16.count <= 4 * 1024,
            let tokenValue = body["token"] as? [String: Any],
            let token = Self.decodeToken(tokenValue),
            token.webViewInstanceID == webViewInstanceID,
            token.documentEpoch == documentEpoch,
            token.operationKind == .decoration,
            token.groupID == groupID,
            let requestURL = message.frameInfo.request.url,
            publicationBaseURL.relativize(requestURL) != nil,
            let frameKey = frameKey(for: requestURL),
            case let .selected(selectedID) = registry.select(
                href: frameKey,
                capability: currentFrameCapability
            ),
            Self.validActivationRect(body["rect"]),
            Self.validActivationClick(body["click"])
        else {
            return nil
        }

        guard
            let storedFrame = framesByID[selectedID],
            storedFrame.capability == currentFrameCapability,
            let state = decorationActivationStates[
                DecorationActivationStateKey(frameID: selectedID, groupID: groupID)
            ],
            state.token == token,
            state.identifiers.contains(identifier)
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

        framesByID[registration.id] = StoredFrame(
            info: message.frameInfo,
            capability: registration.capability
        )
        registry.register(
            id: registration.id,
            href: registration.key,
            capability: registration.capability,
            isMainFrame: message.frameInfo.isMainFrame,
            isSameOrigin: registration.isSameOrigin
        )
    }
}
