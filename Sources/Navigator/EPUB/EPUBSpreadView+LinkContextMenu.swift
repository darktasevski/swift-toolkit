//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit
import WebKit

extension EPUBSpreadView {
    /// The link a long-press menu is offered for: one that leaves the publication. A URL the
    /// publication base relativizes is internal and gets no menu — the test a tap ends in. A
    /// `javascript:` link runs script rather than leaving, so it gets none either, as a tap on it
    /// is left alone by `external-link-activation.js`.
    static func outboundLinkURL(for linkURL: URL?, publicationBaseURL: AbsoluteURL) -> URL? {
        guard
            let linkURL,
            linkURL.scheme?.lowercased() != "javascript",
            publicationBaseURL.relativize(linkURL) == nil
        else {
            return nil
        }
        return linkURL
    }

    /// The item's title. An app supplies its own by defining
    /// `ReadiumNavigator.LinkContextMenu.openLink` in its main bundle, which
    /// `ReadiumLocalizedString` consults first.
    static var outboundLinkMenuTitle: String {
        ReadiumNavigatorLocalizedString("LinkContextMenu.openLink")
    }

    /// The menu for a link that leaves the publication: one action.
    static func outboundLinkMenu(title: String, open: @escaping () -> Void) -> UIMenu {
        UIMenu(children: [
            UIAction(title: title, image: UIImage(systemName: "safari")) { _ in open() },
        ])
    }

    /// What the hook hands WebKit for `linkURL`: `nil` for a link inside the publication or for no
    /// link, otherwise a configuration with no preview whose one item takes the same path as a tap.
    func linkContextMenuConfiguration(forLinkURL linkURL: URL?) -> UIContextMenuConfiguration? {
        guard let url = Self.outboundLinkURL(
            for: linkURL,
            publicationBaseURL: viewModel.publicationBaseURL
        ) else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            Self.outboundLinkMenu(title: Self.outboundLinkMenuTitle) {
                self?.openOutboundLink(url)
            }
        }
    }

    /// What the menu's one item does: the same as a tap on the link.
    func openOutboundLink(_ url: URL) {
        delegate?.spreadView(self, didTapOnExternalURL: url)
    }

    /// Replaces WebKit's link context menu. Returning `nil` would not suppress it for an `http(s)`
    /// link: WebKit's source falls back to DataDetectors' URL menu, whose preview loads the
    /// destination and whose "Open Link" hands it to Safari without consulting the navigation
    /// policy. A non-`nil` configuration with no `previewProvider` skips that fallback and loads
    /// nothing.
    func webView(
        _: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(linkContextMenuConfiguration(forLinkURL: elementInfo.linkURL))
    }
}
