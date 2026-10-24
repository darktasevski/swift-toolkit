//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

extension EPUBNavigatorViewController {
    /// Where a selection `spreadView` reported in the resource at `resource`
    /// lies.
    ///
    /// The resource must be one the spread shows: the page names it, and a
    /// page script could name any other. Where the spread measured that
    /// resource, the locator is derived from the measurement as a publication
    /// derives one, so it never waits on a calculation that has not committed
    /// yet. Where it measured nothing, the published location stands in if it
    /// names that resource, and otherwise the resource alone does, without a
    /// progression: the selection is kept, and never named after another
    /// resource.
    func selectionLocation(of resource: ReadingOrder.Index, in spreadView: EPUBSpreadView) -> Locator? {
        guard
            spreadView.spread.contains(index: resource),
            let link = readingOrder.getOrNil(resource)
        else {
            return nil
        }
        let mediaType = link.mediaType ?? .xhtml
        guard let progression = spreadView.measuredProgression(of: resource) else {
            if let published = currentLocation, readingOrder.firstIndexWithHREF(published.href) == resource {
                return published
            }
            return Locator(href: link.url(), mediaType: mediaType)
        }
        return EPUBViewportAndLocationCalculator.locator(
            ofResourceAt: resource,
            progression: progression,
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder,
            title: loadedTableOfContentsTitleByHref?[link.url()]
        ) ?? Locator(
            href: link.url(),
            mediaType: mediaType,
            locations: Locator.Locations(progression: progression)
        )
    }
}
