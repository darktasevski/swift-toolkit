//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

extension EPUBSpreadView {
    /// Where this spread measured it shows, as much as a rebuild positions by:
    /// its first resource, at the start of the range a reflowable spread
    /// measured there, or at the start of a fixed-layout resource. `nil` while
    /// the spread has nothing it could publish.
    func measuredPosition() -> Locator? {
        let resource = spread.first
        guard let progression = measuredProgression(of: resource.index) else {
            return nil
        }
        return Locator(
            href: resource.link.url(),
            // A rebuild never reads the media type; a manifest item may omit it.
            mediaType: resource.link.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: progression)
        )
    }

    /// The progression, clamped to 0...1, at the start of what this spread
    /// measured it shows of the resource at `index`: a reflowable spread's
    /// measured range, or the start of a fixed-layout resource. `nil` while
    /// the spread has nothing it could publish, or does not show that
    /// resource.
    func measuredProgression(of index: ReadingOrder.Index) -> Double? {
        publicationInput()?.progressions[index].map { min(max($0.lowerBound, 0), 1) }
    }
}
