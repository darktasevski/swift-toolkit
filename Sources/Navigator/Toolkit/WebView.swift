//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import WebKit

/// A custom web view which:
///  - Forwards copy: menu action to an EditingActionsController.
///  - Routes configured custom editing actions to the responder chain.
final class WebView: WKWebView {
    private let editingActions: EditingActionsController

    convenience init(editingActions: EditingActionsController) {
        self.init(editingActions: editingActions, configuration: WKWebViewConfiguration())
    }

    init(editingActions: EditingActionsController, configuration: WKWebViewConfiguration) {
        self.editingActions = editingActions

        super.init(frame: .zero, configuration: configuration)

        #if DEBUG && swift(>=5.8)
            if #available(macOS 13.3, iOS 16.4, *) {
                isInspectable = true
            }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clearSelection() {
        evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        editingActions.buildMenu(with: builder)

        // Don't call super as it is the only way to remove the
        // "Copy Link with Highlight" menu item.
        // See https://github.com/readium/swift-toolkit/issues/509
//        super.buildMenu(with: builder)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if editingActions.handlesAction(action) {
            return editingActions.canPerformAction(action)
        }

        return super.canPerformAction(action, withSender: sender)
            && editingActions.canPerformAction(action)
    }

    override func copy(_ sender: Any?) {
        Task {
            await editingActions.copy()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setupDragAndDrop()
    }

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        guard editingActions.handlesAction(action) else {
            return super.target(forAction: action, withSender: sender)
        }

        var responder = next
        while let currentResponder = responder {
            if currentResponder.responds(to: action) {
                return currentResponder
            }
            responder = currentResponder.next
        }

        return super.target(forAction: action, withSender: sender)
    }

    private func setupDragAndDrop() {
        if !editingActions.canCopy {
            guard
                let webScrollView = subviews.first(where: { $0 is UIScrollView }),
                let contentView = webScrollView.subviews.first(where: { $0.interactions.count > 1 }),
                let dragInteraction = contentView.interactions.first(where: { $0 is UIDragInteraction })
            else {
                return
            }
            contentView.removeInteraction(dragInteraction)
        }
    }
}
