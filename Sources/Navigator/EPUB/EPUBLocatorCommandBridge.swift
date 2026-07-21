//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

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
        let documentEpoch: Int
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
        documentEpoch: Int,
        isMainFrame: Bool,
        isSameOrigin: Bool
    ) {
        entriesByID[id] = Entry(
            id: id,
            href: href,
            documentEpoch: documentEpoch,
            isMainFrame: isMainFrame,
            isSameOrigin: isSameOrigin
        )
    }

    mutating func removeAll() {
        entriesByID.removeAll(keepingCapacity: true)
    }

    func select(href: String, documentEpoch: Int) -> EPUBLocatorFrameSelection {
        let matchingHref = entriesByID.values.filter { $0.href == href }
        guard !matchingHref.isEmpty else {
            return .miss(.frameMissing)
        }

        let current = matchingHref.filter { $0.documentEpoch == documentEpoch }
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
}

struct EPUBLocatorCommandToken: Equatable, Sendable {
    let webViewInstanceID: String
    let documentEpoch: Int
    let operationKind: EPUBLocatorCommandOperationKind
    let sequence: Int
    let groupID: String?

    var javascriptValue: [String: Any] {
        var value: [String: Any] = [
            "webViewInstanceID": webViewInstanceID,
            "documentEpoch": documentEpoch,
            "operationKind": operationKind.rawValue,
            "sequence": sequence,
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
    case paintTimeout
    case notScrollable
    case internalError
    case invalidResult
    case webKitFailure
}

struct EPUBLocatorCommandResult: Sendable {
    let token: EPUBLocatorCommandToken
    let outcome: EPUBLocatorCommandOutcome
    let reason: EPUBLocatorCommandReason
}

@MainActor
final class EPUBLocatorCommandBridge: NSObject {
    private struct StoredFrame {
        let info: WKFrameInfo
        let documentEpoch: Int
    }

    static let contentWorld = WKContentWorld.world(name: "ReaderLocatorCommands")
    private static let frameReadyMessageName = "readerLocatorFrameReady"
    private static let commandScript = "return await readerLocatorCommands.execute(command, token);"
    private static let commandSource: String = Bundle.module
        .url(
            forResource: "readium-reader-locator-commands",
            withExtension: "js",
            subdirectory: "Assets/Static/scripts"
        )
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }!

    private let publicationBaseURL: AbsoluteURL
    private let webViewInstanceID = UUID().uuidString
    private var registry: EPUBLocatorFrameRegistry
    private var framesByID: [String: StoredFrame] = [:]
    private var latestSequences: [String: Int] = [:]
    private(set) var documentEpoch = 0
    private weak var webView: WKWebView?
    private weak var userContentController: WKUserContentController?
    private var isMessageHandlerEnabled = false

    init(layout: EPUBLocatorFrameLayout, publicationBaseURL: AbsoluteURL) {
        self.publicationBaseURL = publicationBaseURL
        registry = EPUBLocatorFrameRegistry(layout: layout)
        super.init()
    }

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.commandSource,
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
        isMessageHandlerEnabled = false
    }

    func beginDocument() {
        documentEpoch += 1
        framesByID.removeAll(keepingCapacity: true)
        registry.removeAll()
        latestSequences.removeAll(keepingCapacity: true)
    }

    func invalidateDocument() {
        beginDocument()
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
        switch registry.select(href: targetKey, documentEpoch: token.documentEpoch) {
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
            storedFrame.documentEpoch == token.documentEpoch,
            let webView
        else {
            return EPUBLocatorCommandResult(token: token, outcome: .miss, reason: .staleDocument)
        }

        let command: [String: Any] = [
            "kind": "navigateLocator",
            "payload": locatorJSON,
            "animated": animated,
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
        return Self.decodeResult(rawResult, expectedToken: token)
    }

    private func nextToken(
        for operationKind: EPUBLocatorCommandOperationKind,
        groupID: String? = nil
    ) -> EPUBLocatorCommandToken {
        let key = "\(operationKind.rawValue):\(groupID ?? "")"
        let sequence = (latestSequences[key] ?? 0) + 1
        latestSequences[key] = sequence
        return EPUBLocatorCommandToken(
            webViewInstanceID: webViewInstanceID,
            documentEpoch: documentEpoch,
            operationKind: operationKind,
            sequence: sequence,
            groupID: groupID
        )
    }

    private func isCurrent(_ token: EPUBLocatorCommandToken) -> Bool {
        guard
            token.webViewInstanceID == webViewInstanceID,
            token.documentEpoch == documentEpoch
        else {
            return false
        }
        let key = "\(token.operationKind.rawValue):\(token.groupID ?? "")"
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
            groupID: groupID
        )
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= 0, double <= Double(Int.max) else {
            return nil
        }
        return Int(double)
    }
}

extension EPUBLocatorCommandBridge: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == Self.frameReadyMessageName,
            let body = message.body as? [String: Any],
            let announcedHREF = body["href"] as? String,
            announcedHREF.utf16.count <= 4 * 1024,
            let announcedURL = URL(string: announcedHREF),
            let requestURL = message.frameInfo.request.url,
            frameKey(for: announcedURL) == frameKey(for: requestURL),
            let key = frameKey(for: requestURL)
        else {
            return
        }

        let id = String(UInt(bitPattern: ObjectIdentifier(message.frameInfo)), radix: 16)
        let isSameOrigin = publicationBaseURL.relativize(requestURL) != nil
        framesByID[id] = StoredFrame(info: message.frameInfo, documentEpoch: documentEpoch)
        registry.register(
            id: id,
            href: key,
            documentEpoch: documentEpoch,
            isMainFrame: message.frameInfo.isMainFrame,
            isSameOrigin: isSameOrigin
        )
    }
}
