//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

enum EPUBLocatorFrameLayout: Sendable {
    case reflowable
    case fixed
}

enum EPUBLocatorFrameMissReason: String, Equatable, Sendable {
    case frameMissing
    case staleDocument
    case crossOriginFrame
    case fixedLayoutIneligible
    case duplicateFrame
}

enum EPUBLocatorFrameSelection: Equatable, Sendable {
    case selected(String)
    case miss(EPUBLocatorFrameMissReason)
}

/// A content-free model of the frames that announced readiness from the
/// isolated locator command world.
///
/// `WKFrameInfo` is deliberately kept out of this type. The WebKit-facing
/// bridge owns those objects on the main actor and uses the selected opaque ID
/// to retrieve one frame only after this policy has failed closed.
struct EPUBLocatorFrameRegistry: Sendable {
    private struct Entry: Sendable {
        let id: String
        let href: String
        let documentEpoch: Int
        let isMainFrame: Bool
        let isSameOrigin: Bool
    }

    let layout: EPUBLocatorFrameLayout
    private var entriesByID: [String: Entry] = [:]

    init(layout: EPUBLocatorFrameLayout) {
        self.layout = layout
    }

    mutating func register(
        id: String,
        href: String,
        documentEpoch: Int,
        isMainFrame: Bool,
        isSameOrigin: Bool
    ) {
        entriesByID[id] = Entry(
            id: id,
            href: href,
            documentEpoch: documentEpoch,
            isMainFrame: isMainFrame,
            isSameOrigin: isSameOrigin
        )
    }

    mutating func removeAll() {
        entriesByID.removeAll(keepingCapacity: true)
    }

    func select(href: String, documentEpoch: Int) -> EPUBLocatorFrameSelection {
        let matchingHref = entriesByID.values.filter { $0.href == href }
        guard !matchingHref.isEmpty else {
            return .miss(.frameMissing)
        }

        let current = matchingHref.filter { $0.documentEpoch == documentEpoch }
        guard !current.isEmpty else {
            return .miss(.staleDocument)
        }

        let sameOrigin = current.filter(\.isSameOrigin)
        guard !sameOrigin.isEmpty else {
            return .miss(.crossOriginFrame)
        }

        let eligible: [Entry]
        switch layout {
        case .reflowable:
            eligible = sameOrigin.filter(\.isMainFrame)
        case .fixed:
            eligible = sameOrigin.filter { !$0.isMainFrame }
        }

        guard !eligible.isEmpty else {
            return .miss(.fixedLayoutIneligible)
        }
        guard eligible.count == 1, let selected = eligible.first else {
            return .miss(.duplicateFrame)
        }
        return .selected(selected.id)
    }
}
