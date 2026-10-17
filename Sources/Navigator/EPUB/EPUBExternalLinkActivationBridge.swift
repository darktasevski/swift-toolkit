//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import WebKit

/// Runs `external-link-activation.js` in its own content world and receives its
/// `externalLinkActivated` messages. In the page world a publication script could redefine the
/// globals the script calls at click time, or post the message itself; here it can do neither.
@MainActor
final class EPUBExternalLinkActivationBridge: NSObject, Loggable {
    static let contentWorld = WKContentWorld.world(name: "ReadiumExternalLinkActivation")
    static let messageName = "externalLinkActivated"

    private static let source: String? = {
        guard let url = Bundle.module.url(
            forResource: "readium-external-link-activation",
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

    private weak var userContentController: WKUserContentController?
    private var isMessageHandlerEnabled = false
    var onActivation: ((Any) -> Void)?

    func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        userContentController = controller
        guard let source = Self.source else {
            log(.error, "External link activation bundle unavailable")
            return
        }
        controller.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.contentWorld
        ))
        enableMessageHandler()
    }

    func enableMessageHandler() {
        guard !isMessageHandlerEnabled, let userContentController else {
            return
        }
        userContentController.add(self, contentWorld: Self.contentWorld, name: Self.messageName)
        isMessageHandlerEnabled = true
    }

    func disableMessageHandler() {
        guard isMessageHandlerEnabled, let userContentController else {
            return
        }
        userContentController.removeScriptMessageHandler(forName: Self.messageName, contentWorld: Self.contentWorld)
        isMessageHandlerEnabled = false
    }
}

extension EPUBExternalLinkActivationBridge: WKScriptMessageHandler {
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        onActivation?(message.body)
    }
}
