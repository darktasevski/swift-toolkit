//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

extension EPUBViewportAndLocationCalculator {
    /// The locator of the reading-order resource at `index` with `progression`
    /// of it at the start of the view, derived from its positions as
    /// `compute` derives the locator of a spread's first resource: the
    /// position the progression reaches, the progression itself, and the
    /// total progression interpolated across the publication. Synchronous, as
    /// the positions are loaded before any spread exists. `nil` when the
    /// resource has no positions.
    static func locator(
        ofResourceAt index: ReadingOrder.Index,
        progression: Double,
        readingOrder: [Link],
        positionsByReadingOrder: [[Locator]],
        title: String?
    ) -> Locator? {
        guard
            let link = readingOrder.getOrNil(index),
            let positions = positionsByReadingOrder.getOrNil(index),
            !positions.isEmpty
        else {
            return nil
        }
        let progression = min(max(progression, 0), 1)
        let positionIndex = Int(ceil(progression * Double(positions.count - 1)))
        let resource = (href: link.url(), progression: progression ... progression)
        let totalProgression = ViewportProgressionCalculator.totalProgressionRange(
            firstResource: resource,
            lastResource: resource,
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder
        )?.lowerBound ?? progression
        return positions[positionIndex].copy(
            title: title,
            locations: {
                $0.progression = progression
                $0.totalProgression = totalProgression
            }
        )
    }
}
