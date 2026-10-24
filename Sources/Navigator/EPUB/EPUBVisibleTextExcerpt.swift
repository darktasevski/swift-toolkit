//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

/// A bounded excerpt of the text an EPUB spread shows, and the reading-order
/// resource it was read from.
public struct EPUBVisibleTextExcerpt: Sendable, Equatable {
    /// The resource the text was read from, as its reading-order link names it.
    public let href: AnyURL
    /// Publisher content: for the local caller only, never logged.
    public let text: String

    public init(href: AnyURL, text: String) {
        self.href = href
        self.text = text
    }
}
