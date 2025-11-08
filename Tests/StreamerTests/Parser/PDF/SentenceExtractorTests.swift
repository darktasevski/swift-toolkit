//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

#if canImport(NaturalLanguage)
@testable import ReadiumStreamer
import XCTest

@available(iOS 12.0, macOS 10.14, *)
class SentenceExtractorTests: XCTestCase {

    func testExtractsSentences() {
        let input = "First sentence. Second sentence. Third sentence."

        let sentences = SentenceExtractor.extractSentences(from: input)

        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[0], "First sentence.")
        XCTAssertEqual(sentences[1], "Second sentence.")
        XCTAssertEqual(sentences[2], "Third sentence.")
    }

    func testHandlesAbbreviations() {
        let input = "Dr. Smith went to the store. He bought apples."

        let sentences = SentenceExtractor.extractSentences(from: input)

        // NLTokenizer should NOT split on "Dr."
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0], "Dr. Smith went to the store.")
        XCTAssertEqual(sentences[1], "He bought apples.")
    }

    func testHandlesDecimalNumbers() {
        let input = "The value is 3.14 and that's pi. Another sentence."

        let sentences = SentenceExtractor.extractSentences(from: input)

        // NLTokenizer should NOT split on "3.14"
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("3.14"))
    }

    func testExtractsParagraphs() {
        let input = "First paragraph.\n\nSecond paragraph."

        let paragraphs = SentenceExtractor.extractParagraphs(from: input)

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0], "First paragraph.")
        XCTAssertEqual(paragraphs[1], "Second paragraph.")
    }

    func testHandlesEmptyInput() {
        let sentences = SentenceExtractor.extractSentences(from: "")
        XCTAssertTrue(sentences.isEmpty)

        let paragraphs = SentenceExtractor.extractParagraphs(from: "")
        XCTAssertTrue(paragraphs.isEmpty)
    }

    func testHandlesSingleSentence() {
        let input = "Just one sentence without ending punctuation"

        let sentences = SentenceExtractor.extractSentences(from: input)

        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0], input)
    }
}
#endif
