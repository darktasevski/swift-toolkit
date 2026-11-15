//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumShared
import Testing
import UIKit

enum PDFResourceContentIteratorTests {
    struct Navigation {
        @Test func iterateFromStartToFinish() async throws {
            let iter = makeIterator()
            for expected in try await sampleElements() {
                let result = try await iter.next()
                #expect(result?.equatable() == expected)
            }
            let result = try await iter.next()
            #expect(result == nil)
        }

        @Test func previousIsNullFromTheBeginning() async throws {
            let result = try await makeIterator().previous()
            #expect(result == nil)
        }

        @Test func nextReturnsTheFirstElementFromTheBeginning() async throws {
            let result = try await makeIterator().next()
            #expect(try await result?.equatable() == sampleElements()[0])
        }

        @Test func nextThenPreviousReturnsNull() async throws {
            let iter = makeIterator()
            let first = try await iter.next()
            #expect(try await first?.equatable() == sampleElements()[0])
            let back = try await iter.previous()
            #expect(back == nil)
        }

        @Test func nextTwiceThenPreviousReturnsTheFirstElement() async throws {
            let iter = makeIterator()
            let samples = try await sampleElements()
            let first = try await iter.next()
            #expect(first?.equatable() == samples[0])
            let second = try await iter.next()
            #expect(second?.equatable() == samples[1])
            let back = try await iter.previous()
            #expect(back?.equatable() == samples[0])
        }

        @Test func iterateFullyBackwardFromEnd() async throws {
            let iter = makeIterator(start: makeLocator(progression: 1.0))
            _ = try await iter.next() // Position at last element

            var backwardElements: [AnyEquatableContentElement] = []
            while let element = try await iter.previous() {
                backwardElements.append(element.equatable())
            }

            #expect(try await backwardElements == sampleElements().dropLast().reversed())
        }
    }

    struct StartingPosition {
        @Test func startingFromPosition() async throws {
            let result = try await makeIterator(start: makeLocator(position: 5)).next()
            #expect(try await result?.equatable() == sampleElement(pageNumber: 5))
        }

        @Test func startingFromPageFragment() async throws {
            // page=5 fragment should land on the same element as position 5.
            let result = try await makeIterator(start: makeLocator(pageFragment: 5)).next()
            #expect(try await result?.equatable() == sampleElement(pageNumber: 5))
        }

        @Test func startingFromProgression() async throws {
            // progression=0.4, pageCount=9 → startPage = min(Int(0.4*9),8) = 3 (page 4).
            let result = try await makeIterator(start: makeLocator(progression: 0.4)).next()
            #expect(try await result?.equatable() == sampleElement(pageNumber: 4))
        }

        @Test func startingFromEndProgression() async throws {
            let iter = makeIterator(start: makeLocator(progression: 1.0))
            let first = try await iter.next()
            #expect(try await first?.equatable() == sampleElement(pageNumber: 9))
            let second = try await iter.next()
            #expect(second == nil)
        }
    }

    struct ContentCorrectness {
        @Test func zeroPagesReturnsNil() async throws {
            let mock = MockPDFDocument(texts: [])
            let iter = makeIteratorFromMock(mock)

            #expect(try await iter.next() == nil)
            #expect(try await iter.previous() == nil)
        }

        @Test func emptyPagesAreSkipped() async throws {
            let iter = makeIterator()
            var pageNumbers: [Int] = []
            while let element = try await iter.next() {
                pageNumbers.append(element.locator.locations.page ?? 0)
            }
            #expect(pageNumbers == [2, 3, 4, 5, 6, 7, 8, 9])
        }

        @Test func allEmptyPagesReturnsNil() async throws {
            let mock = MockPDFDocument(texts: [nil, "", "   ", "\n\t"])
            let iter = makeIteratorFromMock(mock)
            #expect(try await iter.next() == nil)
        }

        @Test func elementLocatorHasCorrectPagePosition() async throws {
            let iter = makeIterator()
            let expectedPageNumbers = [2, 3, 4, 5, 6, 7, 8, 9]
            for expected in expectedPageNumbers {
                let element = try await iter.next()
                #expect(element?.locator.locations.position == expected)
            }
        }

        @Test func elementLocatorHasPageFragment() async throws {
            let iter = makeIterator()
            let expectedPageNumbers = [2, 3, 4, 5, 6, 7, 8, 9]
            for expected in expectedPageNumbers {
                let element = try await iter.next()
                #expect(element?.locator.locations.fragments == ["page=\(expected)"])
            }
        }

        @Test func elementLocatorHasProgression() async throws {
            let iter = makeIterator()
            for i in 0 ..< 8 {
                let element = try await iter.next()
                #expect(element?.locator.locations.progression == Double(i + 1) / 9.0)
            }
        }

        @Test func highlightIsFullPageText() async throws {
            let iter = makeIterator()
            let pageFull = try await pageTexts()
            for expected in pageFull {
                let element = try await iter.next()
                #expect(element?.locator.text.highlight == expected)
            }
        }

        @Test func segmentTextMatchesFullPageText() async throws {
            let iter = makeIterator()
            let pageFull = try await pageTexts()
            for expected in pageFull {
                let element = try await iter.next() as? TextContentElement
                #expect(element?.text == expected)
            }
        }
    }

    struct TotalProgression {
        @Test func totalProgressionIsAdjustedWithRange() async throws {
            let range: ClosedRange<Double> = 0.25 ... 0.75
            let iter = makeIterator(totalProgressionRange: range)
            for i in 0 ..< 8 {
                let element = try await iter.next()
                let expected = range.lowerBound + Double(i + 1) / 9.0 * (range.upperBound - range.lowerBound)
                #expect(element?.locator.locations.totalProgression == expected)
            }
        }

        @Test func totalProgressionIsNullWithoutRange() async throws {
            let iter = makeIterator()
            for _ in 0 ..< 8 {
                let element = try await iter.next()
                #expect(element?.locator.locations.totalProgression == nil)
            }
        }
    }

    struct PositionOffset {
        @Test func positionsAreOffsetByPositionOffset() async throws {
            // offset 10: pages 1–9 of the PDF map to global positions 11–19
            let iter = makeIterator(positionOffset: 10)
            let expectedPositions = [12, 13, 14, 15, 16, 17, 18, 19]
            for expected in expectedPositions {
                let element = try await iter.next()
                #expect(element?.locator.locations.position == expected)
            }
        }

        @Test func startingFromGlobalPositionWithOffset() async throws {
            // position 12 with offset 10 = page 2 of the PDF = sampleElements[0] (first non-empty page)
            let iter = makeIterator(
                start: makeLocator(position: 12),
                positionOffset: 10
            )
            let first = try await iter.next()
            // position 12 maps to the element with position 12 (pageNumber=2, offset=10 → 12)
            #expect(first?.locator.locations.position == 12)
        }

        @Test func pageFragmentStartStillWorksWithOffset() async throws {
            // page=5 fragment should still land on the element for page 5, regardless of offset
            let iter = makeIterator(
                start: makeLocator(pageFragment: 5),
                positionOffset: 10
            )
            let first = try await iter.next()
            #expect(first?.locator.locations.fragments == ["page=5"])
        }
    }

    struct ErrorHandling {
        @Test func openDocumentErrorPropagates() async throws {
            struct TestError: Error {}
            let iter = PDFResourceContentIterator(
                openDocument: { throw TestError() },
                resourceInfo: { PDFResourceContentIterator.ResourceInfo(positionOffset: 0, totalProgressionRange: nil) },
                locator: Locator(href: "mock.pdf", mediaType: .pdf)
            )
            await #expect(throws: TestError.self) {
                _ = try await iter.next()
            }
        }

        @Test func documentWithoutTextSupportProducesNoElements() async throws {
            let iter = PDFResourceContentIterator(
                openDocument: { MockNonTextPDFDocument() },
                resourceInfo: { PDFResourceContentIterator.ResourceInfo(positionOffset: 0, totalProgressionRange: nil) },
                locator: Locator(href: "mock.pdf", mediaType: .pdf)
            )
            let result = try await iter.next()
            #expect(result == nil)
        }
    }
}

// MARK: - Helpers

private let baseLocator = Locator(href: "daisy-truncated.pdf", mediaType: .pdf)

/// The pages of the fixture that carry text; page 1 has none.
private let textPageNumbers = Array(2 ... 9)

/// Each text page's content as PDFKit extracts it. The iterator passes that text through
/// unchanged, and PDFKit's spacing of tracked letters differs between SDK releases, so the
/// expected text comes from the same extraction rather than from recorded strings.
private func pageTexts() async throws -> [String] {
    let document = try #require(try await openFixture() as? PDFDocumentTextProviding)
    var texts: [String] = []
    for pageNumber in textPageNumbers {
        let text = try #require(try await document.pageText(at: pageNumber - 1))
        try #require(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        texts.append(text)
    }
    return texts
}

private func sampleElements() async throws -> [AnyEquatableContentElement] {
    let texts = try await pageTexts()
    return zip(textPageNumbers, texts).map { makeElement(pageNumber: $0, text: $1) }
}

private func sampleElement(pageNumber: Int) async throws -> AnyEquatableContentElement {
    try await sampleElements()[pageNumber - textPageNumbers[0]]
}

private func makeElement(
    pageNumber: Int,
    text: String
) -> AnyEquatableContentElement {
    let progression = Double(pageNumber - 1) / 9.0
    let loc = makeLocator(
        position: pageNumber,
        progression: progression,
        highlight: text
    ).copy(locations: { $0.fragments = ["page=\(pageNumber)"] })
    return TextContentElement(
        locator: loc,
        role: .body,
        segments: [TextContentElement.Segment(locator: loc, text: text)]
    ).equatable()
}

private func makeLocator(
    position: Int? = nil,
    pageFragment: Int? = nil,
    progression: Double? = nil,
    highlight: String? = nil
) -> Locator {
    baseLocator.copy(
        locations: {
            $0.position = position
            $0.progression = progression
            if let page = pageFragment {
                $0.fragments = ["page=\(page)"]
            }
        },
        text: {
            $0.highlight = highlight
        }
    )
}

private func openFixture() async throws -> PDFDocument {
    let data = Fixtures(path: "Publication/Services").data(at: "daisy-truncated.pdf")
    return try await DefaultPDFDocumentFactory().open(resource: DataResource(data: data), at: baseLocator.href, password: nil)
}

private func makeIterator(
    start startLocator: Locator? = nil,
    positionOffset: Int = 0,
    totalProgressionRange: ClosedRange<Double>? = nil
) -> PDFResourceContentIterator {
    PDFResourceContentIterator(
        openDocument: { try await openFixture() },
        resourceInfo: { PDFResourceContentIterator.ResourceInfo(positionOffset: positionOffset, totalProgressionRange: totalProgressionRange) },
        locator: startLocator ?? baseLocator
    )
}

// MARK: - Mock PDF Documents

private class MockPDFDocument: PDFDocumentTextProviding {
    private let texts: [String?]
    private(set) var requestedPageIndices: [Int] = []

    init(texts: [String?]) {
        self.texts = texts
    }

    func resetTracking() {
        requestedPageIndices = []
    }

    func identifier() async throws -> String? {
        nil
    }

    func pageCount() async throws -> Int {
        texts.count
    }

    func cover() async throws -> UIImage? {
        nil
    }

    func readingProgression() async throws -> ReadingProgression? {
        nil
    }

    func title() async throws -> String? {
        nil
    }

    func author() async throws -> String? {
        nil
    }

    func subject() async throws -> String? {
        nil
    }

    func keywords() async throws -> [String] {
        []
    }

    func tableOfContents() async throws -> [PDFOutlineNode] {
        []
    }

    func pageText(at pageIndex: Int) async throws -> String? {
        requestedPageIndices.append(pageIndex)
        return texts.getOrNil(pageIndex) ?? nil
    }
}

private class MockNonTextPDFDocument: PDFDocument {
    func identifier() async throws -> String? {
        nil
    }

    func pageCount() async throws -> Int {
        5
    }

    func cover() async throws -> UIImage? {
        nil
    }

    func readingProgression() async throws -> ReadingProgression? {
        nil
    }

    func title() async throws -> String? {
        nil
    }

    func author() async throws -> String? {
        nil
    }

    func subject() async throws -> String? {
        nil
    }

    func keywords() async throws -> [String] {
        []
    }

    func tableOfContents() async throws -> [PDFOutlineNode] {
        []
    }
}

private func makeIteratorFromMock(
    _ mock: MockPDFDocument,
    startLocator: Locator? = nil
) -> PDFResourceContentIterator {
    PDFResourceContentIterator(
        openDocument: { mock },
        resourceInfo: { PDFResourceContentIterator.ResourceInfo(positionOffset: 0, totalProgressionRange: nil) },
        locator: startLocator ?? Locator(href: "mock.pdf", mediaType: .pdf)
    )
}
