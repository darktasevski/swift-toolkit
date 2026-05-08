//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

/// A navigator that reports the most recently observed anchor (an element
/// `id` within a spine resource) the user has scrolled past, for
/// publications where a single spine resource carries multiple logical
/// sections distinguished by `[id]` anchors. The classic case is an EPUB
/// with NCX-driven omnibus chapters, but the protocol contract is neutral
/// to the anchor source: the conformer is responsible for nominating the
/// anchor list, and the protocol exposes no state of its own (the anchor
/// list is supplied at construction; per-spread observation is conformer-
/// internal).
///
/// This is a fork-only sibling of upstream's ``ViewportObservingNavigator``
/// (Readium 3.8.0). The composition shape — a sibling protocol that
/// `EPUBNavigatorDelegate` also inherits from — mirrors the upstream
/// pattern so a future upstream PR can be a one-line bridge instead of a
/// refactor.
public protocol VisibleAnchorObservingNavigator: VisualNavigator {}

/// Delegate for receiving visible-anchor updates from any
/// ``VisibleAnchorObservingNavigator``.
@MainActor public protocol VisibleAnchorObservingNavigatorDelegate: AnyObject {
    /// Called when the visible anchor changes — i.e., the most-recently-
    /// crossed anchor in the conformer's configured anchor list updates.
    /// The EPUB navigator drives this from an IntersectionObserver in the
    /// spread's WebView; conformers for other formats (PDF, FXL) would
    /// drive it from format-appropriate signals.
    func navigator(
        _ navigator: any VisibleAnchorObservingNavigator,
        didChangeVisibleAnchor anchor: VisibleAnchor
    )
}

public extension VisibleAnchorObservingNavigatorDelegate {
    func navigator(
        _ navigator: any VisibleAnchorObservingNavigator,
        didChangeVisibleAnchor anchor: VisibleAnchor
    ) {}
}

/// Information about the anchor most recently observed crossing the
/// viewport top.
public struct VisibleAnchor: Hashable, Sendable {
    /// HREF of the spine resource the anchor lives in.
    public let href: AnyURL

    /// HTML element id the IntersectionObserver reported as crossing top.
    public let fragmentId: String

    public init(href: AnyURL, fragmentId: String) {
        self.href = href
        self.fragmentId = fragmentId
    }
}
