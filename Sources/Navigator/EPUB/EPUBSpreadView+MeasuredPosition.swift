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
        guard let input = publicationInput() else {
            return nil
        }
        let resource = spread.first
        let progression = input.progressions[resource.index]?.lowerBound ?? 0
        return Locator(
            href: resource.link.url(),
            // A rebuild never reads the media type; a manifest item may omit it.
            mediaType: resource.link.mediaType ?? .xhtml,
            locations: Locator.Locations(progression: min(max(progression, 0), 1))
        )
    }
}
