//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import WebKit

/// Converts a trusted gesture into a request to present the navigator's menu. The book
/// cannot post into this world, choose a menu item, or supply image bytes through it.
@MainActor
final class EPUBImageMenuBridge: NSObject, WKScriptMessageHandler {
    private static let world = WKContentWorld.world(name: "ReadiumImageMenu")
    private static let name = "readiumImageMenu"
    private weak var controller: WKUserContentController?
    private var enabled = false

    var onRequest: ((URL, CGPoint) -> Void)?
    var onLinkRequest: ((URL, CGPoint) -> Void)?

    func install(in controller: WKUserContentController) {
        self.controller = controller
        controller.addUserScript(WKUserScript(
            source: Self.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: Self.world
        ))
        enableMessageHandler()
    }

    func enableMessageHandler() {
        guard !enabled, let controller else { return }
        controller.add(self, contentWorld: Self.world, name: Self.name)
        enabled = true
    }

    func disableMessageHandler() {
        guard enabled, let controller else { return }
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: Self.world)
        enabled = false
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            enabled, controller === self.controller, message.world == Self.world, message.name == Self.name,
            let body = message.body as? [String: Any],
            let kind = body["kind"] as? String,
            let rawURL = body["url"] as? String,
            let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
            !["data", "blob", "javascript"].contains(scheme),
            let x = body["x"] as? Double, let y = body["y"] as? Double,
            (0 ... 1).contains(x), (0 ... 1).contains(y)
        else { return }
        let point = CGPoint(x: x, y: y)
        switch kind {
        case "image": onRequest?(url, point)
        case "link": onLinkRequest?(url, point)
        default: break
        }
    }

    private static let source = EPUBSpreadView.loadScript(named: "readium-image-menu")
}
