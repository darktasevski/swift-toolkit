//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// Wraps a PDF `ContentIterator` to normalize the extracted page text before it
/// reaches Content API consumers (TTS and search).
///
/// The underlying `PDFResourceContentIterator` emits one `TextContentElement`
/// per page carrying the raw extracted text, which contains hard line breaks at
/// column boundaries. This decorator rewrites each text element's segments and
/// highlight through `PDFTextNormalizer`, rejoining those lines. Locator
/// positions, fragments, and progressions are preserved untouched, so
/// navigation is unaffected.
///
/// Decorating at the iterator level (rather than the PDF document or the
/// individual services) fixes every consumer at once, because both
/// `DefaultContentService` and `ContentSearchService` read through the same
/// content iterators.
final class NormalizingPDFContentIterator: ContentIterator {
    /// Factory that wraps another `ResourceContentIteratorFactory` and decorates
    /// the iterators it produces with text normalization.
    final class Factory: ResourceContentIteratorFactory {
        private let base: ResourceContentIteratorFactory

        init(wrapping base: ResourceContentIteratorFactory) {
            self.base = base
        }

        func make(
            publication: Publication,
            readingOrderIndex: Int,
            resource: Resource,
            locator: Locator
        ) -> ContentIterator? {
            base.make(
                publication: publication,
                readingOrderIndex: readingOrderIndex,
                resource: resource,
                locator: locator
            )
            .map { NormalizingPDFContentIterator(wrapping: $0) }
        }
    }

    private let base: ContentIterator

    init(wrapping base: ContentIterator) {
        self.base = base
    }

    func next() async throws -> ContentElement? {
        try await base.next().map(Self.normalize)
    }

    func previous() async throws -> ContentElement? {
        try await base.previous().map(Self.normalize)
    }

    /// Returns a copy of `element` with its text normalized, or the element
    /// unchanged when it carries no text.
    private static func normalize(_ element: ContentElement) -> ContentElement {
        guard var text = element as? TextContentElement else {
            return element
        }

        text.segments = text.segments.map { segment in
            var segment = segment
            let normalized = PDFTextNormalizer.normalize(segment.text)
            segment.text = normalized
            // Mutate only `highlight` in place so any other `Locator.Text` field
            // (before/after, and anything upstream adds later) survives untouched.
            segment.locator = segment.locator.copy(text: { $0.highlight = normalized })
            return segment
        }

        let highlight = text.locator.text.highlight.map(PDFTextNormalizer.normalize)
        text.locator = text.locator.copy(text: { $0.highlight = highlight })

        return text
    }
}
