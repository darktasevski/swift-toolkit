//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
@testable import ReadiumStreamer
import Testing

struct NormalizingPDFContentIteratorTests {
    /// Returns a single-page `TextContentElement` carrying `text` as both its
    /// segment text and locator highlight, mirroring the shape emitted by
    /// `PDFResourceContentIterator`.
    private func pageElement(text: String, page: Int = 1) -> TextContentElement {
        let locator = Locator(href: "book.pdf", mediaType: .pdf).copy(
            locations: {
                $0.position = page
                $0.progression = 0.0
                $0.fragments = ["page=\(page)"]
            },
            text: { $0.highlight = text }
        )
        return TextContentElement(
            locator: locator,
            role: .body,
            segments: [TextContentElement.Segment(locator: locator, text: text)]
        )
    }

    @Test func rejoinsColumnBrokenLinesInSegmentAndHighlight() async throws {
        let raw = "The quick brown\nfox jumps over\nthe lazy dog."
        let normalized = "The quick brown fox jumps over the lazy dog."
        let iterator = NormalizingPDFContentIterator(
            wrapping: StubContentIterator([pageElement(text: raw)])
        )

        let element = try await iterator.next() as? TextContentElement
        #expect(element?.text == normalized)
        #expect(element?.segments.first?.text == normalized)
        #expect(element?.segments.first?.locator.text.highlight == normalized)
        #expect(element?.locator.text.highlight == normalized)
    }

    @Test func rejoinsHyphenatedWordsAcrossLines() async throws {
        let iterator = NormalizingPDFContentIterator(
            wrapping: StubContentIterator([pageElement(text: "particu-\nlarly comfortable")])
        )
        let element = try await iterator.next() as? TextContentElement
        #expect(element?.text == "particularly comfortable")
    }

    @Test func preservesLocatorPositionAndFragments() async throws {
        let iterator = NormalizingPDFContentIterator(
            wrapping: StubContentIterator([pageElement(text: "A line\nbroken", page: 7)])
        )
        let element = try await iterator.next()
        #expect(element?.locator.locations.position == 7)
        #expect(element?.locator.locations.fragments == ["page=7"])
    }

    @Test func forwardsEndOfIterationAsNil() async throws {
        let iterator = NormalizingPDFContentIterator(wrapping: StubContentIterator([]))
        #expect(try await iterator.next() == nil)
        #expect(try await iterator.previous() == nil)
    }

    @Test func passesThroughNonTextElementsUnchanged() async throws {
        let image = ImageContentElement(
            locator: Locator(href: "image.png", mediaType: .png),
            embeddedLink: Link(href: "image.png"),
            caption: "a caption"
        )
        let iterator = NormalizingPDFContentIterator(wrapping: StubContentIterator([image]))

        let element = try await iterator.next()
        #expect(element as? ImageContentElement == image)
    }

    @Test func normalizesElementsReturnedByPrevious() async throws {
        let iterator = NormalizingPDFContentIterator(
            wrapping: StubContentIterator([
                pageElement(text: "first\nline", page: 1),
                pageElement(text: "second\nline", page: 2),
            ])
        )

        _ = try await iterator.next() // page 1
        _ = try await iterator.next() // page 2
        let back = try await iterator.previous() as? TextContentElement

        #expect(back?.text == "first line", "previous() must normalize like next()")
        #expect(back?.locator.locations.position == 1)
    }
}

/// Stub `ContentIterator` returning a fixed sequence of elements, advancing a
/// cursor on `next()`/`previous()`.
private final class StubContentIterator: ContentIterator {
    private let elements: [ContentElement]
    private var index = -1

    init(_ elements: [ContentElement]) {
        self.elements = elements
    }

    func next() async throws -> ContentElement? {
        let target = index + 1
        guard elements.indices.contains(target) else { return nil }
        index = target
        return elements[index]
    }

    func previous() async throws -> ContentElement? {
        let target = index - 1
        guard elements.indices.contains(target) else { return nil }
        index = target
        return elements[index]
    }
}
