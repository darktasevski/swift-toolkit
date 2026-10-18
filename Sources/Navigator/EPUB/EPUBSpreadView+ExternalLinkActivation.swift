//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

extension EPUBSpreadView {
    /// Called from `external-link-activation.js` when a link leaving the publication is clicked. The
    /// script cancelled the click so WebKit opens no connection to the target, which also means no
    /// navigation reaches `webView(_:decidePolicyFor:decisionHandler:)`: this is the link's only
    /// report. The script judges "leaving" by scheme and host; the publication base decides here,
    /// as the navigation policy would, so a link the script misjudged still opens inside the book.
    func didActivateExternalLink(_ body: Any) {
        guard let url = Self.externalLinkURL(from: body) else {
            EPUBPageWorldLog.report(.malformedLinkActivationBody, withholding: body)
            return
        }
        if let relativeURL = viewModel.publicationBaseURL.relativize(url) {
            delegate?.spreadView(self, didTapOnInternalLink: relativeURL.string, clickEvent: nil)
            return
        }
        delegate?.spreadView(self, didTapOnExternalURL: url)
    }

    /// The URL an `externalLinkActivated` body carries, or `nil` when it carries none.
    static func externalLinkURL(from body: Any) -> URL? {
        guard
            let data = body as? [String: Any],
            let href = data["href"] as? String
        else {
            return nil
        }
        return URL(string: href)
    }
}
