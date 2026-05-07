//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

/// A navigator that reports the most recently NCX-anchored chapter heading
/// the user has scrolled into, for shared-spine (omnibus) EPUBs where a
/// single spine resource carries multiple chapters distinguished by `[id]`
/// anchors referenced from the NCX.
///
/// This is a fork-only sibling of upstream's ``ViewportObservingNavigator``
/// (Readium 3.8.0). The composition shape — a sibling protocol that
/// `EPUBNavigatorDelegate` also inherits from — mirrors the upstream
/// pattern so a future upstream PR can be a one-line bridge instead of a
/// refactor.
public protocol VisibleAnchorObservingNavigator: VisualNavigator {
    /// The anchor list is supplied at navigator construction; the navigator
    /// has no other state to expose (per-spread observation is JS-side).
}

/// Delegate for receiving visible-anchor updates from any
/// ``VisibleAnchorObservingNavigator``.
@MainActor public protocol VisibleAnchorObservingNavigatorDelegate: AnyObject {
    /// Called when the IntersectionObserver in the spread's WebView reports
    /// a new anchor crossing the viewport top.
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
