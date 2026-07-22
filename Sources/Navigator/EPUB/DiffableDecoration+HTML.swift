//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

extension Array where Element == DiffableDecoration {
    /// Converts a complete native decoration group into bounded, typed values
    /// for the isolated command world. A single invalid item rejects the whole
    /// group so native and rendered state cannot diverge through partial work.
    func commandItems(styles: [Decoration.Style.Id: HTMLDecorationTemplate]) -> [EPUBDecorationCommandItem]? {
        var items: [EPUBDecorationCommandItem] = []
        items.reserveCapacity(count)

        for value in self {
            let decoration = value.decoration
            guard let template = styles[decoration.style.id] else {
                EPUBNavigatorViewController.log(.error, "Decoration template unavailable")
                return nil
            }
            let locatorJSON: String
            do {
                locatorJSON = try decoration.locator.jsonString()
            } catch {
                EPUBNavigatorViewController.log(.error, "Decoration command encoding failed")
                return nil
            }
            items.append(EPUBDecorationCommandItem(
                id: decoration.id,
                locatorJSON: locatorJSON,
                style: EPUBDecorationCommandStyle(
                    layout: template.layout.rawValue,
                    width: template.width.rawValue,
                    element: template.element(decoration),
                    stylesheet: template.stylesheet ?? ""
                )
            ))
        }
        return items
    }
}
