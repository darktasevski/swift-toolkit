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
    /// publication base relativizes is internal and gets no menu — the navigation policy's test.
    /// A tap is classified first in the page, by `external-link-activation.js`, against the
    /// document's own scheme and host; the policy sees only what that script lets through. With no
    /// base yet, the link is treated as leaving, which routes it to the app rather than to WebKit.
    static func outboundLinkURL(for linkURL: URL?, publicationBaseURL: AbsoluteURL?) -> URL? {
        guard let linkURL else {
            return nil
        }
        if let publicationBaseURL, publicationBaseURL.relativize(linkURL) != nil {
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
                guard let self else {
                    return
                }
                self.delegate?.spreadView(self, didTapOnExternalURL: url)
            }
        }
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
