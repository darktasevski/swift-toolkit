//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

#if canImport(NaturalLanguage)
@testable import ReadiumStreamer
import XCTest

@available(iOS 12.0, macOS 10.14, *)
class PDFResourceContentIteratorTests: XCTestCase {

    /// Tests that the full pipeline (normalize -> paragraphs -> sentences) works correctly.
    func testFullPipelineProducesProperSegments() {
        // Simulate PDF text with broken lines
        let pdfText = """
        This is a long sentence that
        wraps to the next line. Here is
        another sentence.

        This is a new paragraph with
        Dr. Smith's research on 3.14 pi.
        """

        // Normalize
        let normalized = PDFTextNormalizer.normalize(pdfText)

        // Extract paragraphs
        let paragraphs = SentenceExtractor.extractParagraphs(from: normalized)
        XCTAssertEqual(paragraphs.count, 2)

        // Extract sentences from first paragraph
        let firstParaSentences = SentenceExtractor.extractSentences(from: paragraphs[0])
        XCTAssertEqual(firstParaSentences.count, 2)
        XCTAssertEqual(firstParaSentences[0], "This is a long sentence that wraps to the next line.")
        XCTAssertEqual(firstParaSentences[1], "Here is another sentence.")

        // Extract sentences from second paragraph - should handle Dr. and 3.14
        let secondParaSentences = SentenceExtractor.extractSentences(from: paragraphs[1])
        XCTAssertEqual(secondParaSentences.count, 1) // "Dr." shouldn't split
        XCTAssertTrue(secondParaSentences[0].contains("Dr. Smith"))
        XCTAssertTrue(secondParaSentences[0].contains("3.14"))
    }

    func testHyphenatedWordsAreJoined() {
        let pdfText = """
        The imple-
        mentation of this fea-
        ture is complete.
        """

        let normalized = PDFTextNormalizer.normalize(pdfText)

        XCTAssertTrue(normalized.contains("implementation"))
        XCTAssertTrue(normalized.contains("feature"))
        XCTAssertFalse(normalized.contains("imple-"))
    }

    func testMultipleParagraphsWithSentences() {
        let pdfText = """
        First paragraph. It has two sentences.

        Second paragraph here. Also two sentences.

        Third paragraph is short.
        """

        let normalized = PDFTextNormalizer.normalize(pdfText)
        let paragraphs = SentenceExtractor.extractParagraphs(from: normalized)

        XCTAssertEqual(paragraphs.count, 3)

        let firstSentences = SentenceExtractor.extractSentences(from: paragraphs[0])
        XCTAssertEqual(firstSentences.count, 2)

        let secondSentences = SentenceExtractor.extractSentences(from: paragraphs[1])
        XCTAssertEqual(secondSentences.count, 2)

        let thirdSentences = SentenceExtractor.extractSentences(from: paragraphs[2])
        XCTAssertEqual(thirdSentences.count, 1)
    }

    func testComplexAbbreviations() {
        let text = "Mr. Jones and Mrs. Smith met Dr. Brown at 3:00 p.m. They discussed the U.S. economy."

        let sentences = SentenceExtractor.extractSentences(from: text)

        // NLTokenizer should handle these abbreviations correctly
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("Mr. Jones"))
        XCTAssertTrue(sentences[0].contains("Mrs. Smith"))
        XCTAssertTrue(sentences[0].contains("Dr. Brown"))
    }
}
#endif
