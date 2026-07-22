//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// The parser contract used for a resource after applying EPUB media-type
/// precedence. HTML kinds intrinsically require the canonical repair recipe.
public enum EPUBServedDocumentKind: Sendable, Equatable {
    case xhtml
    case html
    case binary

    public var requiresCanonicalRepair: Bool {
        switch self {
        case .xhtml, .html:
            true
        case .binary:
            false
        }
    }

    fileprivate init(mediaType: MediaType) {
        if mediaType.matches(.xhtml) {
            self = .xhtml
        } else if mediaType.matches(.html) {
            self = .html
        } else {
            self = .binary
        }
    }
}

/// Immutable identity of the transforms and parsing rules used to serve and
/// index EPUB resources.
public struct EPUBServedResourceRecipe: Sendable, Equatable {
    public static let current = EPUBServedResourceRecipe(
        version: 1,
        fingerprint: "epub-served-resource-recipe/v1;mime=manifest>resource>href>binary;repair=xhtml-well-formedness/v1;parser=xhtml-xml+html-html5ever-scripting;projection=rendered-text/v1;normalization=unicode-scalar-nfc-whitespace/v1;selector=raw-quote+full-dom-range/v1;chunk=unicode-scalar-4chars-overlap/v1"
    )

    public let version: UInt32
    public let fingerprint: String

    private init(version: UInt32, fingerprint: String) {
        self.version = version
        self.fingerprint = fingerprint
    }
}

/// The effective media type and corresponding closed document kind.
public struct EPUBServedResourceResolution: Sendable, Equatable {
    public let mediaType: MediaType
    public let documentKind: EPUBServedDocumentKind
    public let recipe: EPUBServedResourceRecipe

    fileprivate init(mediaType: MediaType) {
        self.mediaType = mediaType
        documentKind = EPUBServedDocumentKind(mediaType: mediaType)
        recipe = .current
    }
}

/// Single authority for EPUB serving and indexing media-type classification.
public enum EPUBServedResourcePolicy {
    /// Resolves the effective media type using the normative precedence:
    /// manifest declaration, resource properties, href sniff, then binary.
    public static func resolve(
        manifestMediaType: MediaType?,
        resourceMediaType: MediaType?,
        sniffedMediaType: MediaType?
    ) -> EPUBServedResourceResolution {
        EPUBServedResourceResolution(
            mediaType: manifestMediaType ?? resourceMediaType ?? sniffedMediaType ?? .binary
        )
    }

    /// Resolves a publication resource without reading its content bytes.
    public static func resolve(
        manifestMediaType: MediaType?,
        resource: Resource,
        at href: AnyURL,
        formatSniffer: HintsFormatSniffer
    ) async -> EPUBServedResourceResolution {
        if let manifestMediaType {
            return EPUBServedResourceResolution(mediaType: manifestMediaType)
        }
        if let resourceMediaType = await resource.properties().getOrNil()?.mediaType {
            return EPUBServedResourceResolution(mediaType: resourceMediaType)
        }
        if
            let fileExtension = href.pathExtension,
            let sniffedMediaType = formatSniffer
            .sniffHints(.init(fileExtension: fileExtension))?
            .mediaType
        {
            return EPUBServedResourceResolution(mediaType: sniffedMediaType)
        }
        return EPUBServedResourceResolution(mediaType: .binary)
    }
}
