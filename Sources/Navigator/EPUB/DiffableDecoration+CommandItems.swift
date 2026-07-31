//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

// This file replaces upstream's `DiffableDecoration+HTML.swift`, whose two extensions —
// `Array<DecorationChange>.javascript(forGroup:styles:)` and `DecorationChange.javascript(styles:)`
// — cannot be kept. Both are forbidden by `scripts/check-webview-bridge.sh`: the first reaches the
// publisher page's own decoration-group API, which the isolated command world exists to replace,
// and the second logs publisher-derived decoration JSON. Restoring them, even unused, reintroduces
// a content-leak path into the binary and fails the gate.
//
// It carries its own name rather than shadowing the upstream one so the divergence reads as a
// deliberate replacement instead of a file that happens to share a path and nothing else.

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
