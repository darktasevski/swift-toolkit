//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumStreamer
import XCTest

class PDFTextNormalizerTests: XCTestCase {

    func testJoinsLinesWithinParagraph() {
        let input = """
        This is a long sentence that
        wraps to the next line in the
        original PDF document.
        """

        let result = PDFTextNormalizer.normalize(input)

        XCTAssertEqual(
            result,
            "This is a long sentence that wraps to the next line in the original PDF document."
        )
    }

    func testPreservesParagraphBreaks() {
        let input = """
        First paragraph with some text.

        Second paragraph with more text.
        """

        let result = PDFTextNormalizer.normalize(input)

        XCTAssertEqual(
            result,
            "First paragraph with some text.\n\nSecond paragraph with more text."
        )
    }

    func testHandlesHyphenatedWords() {
        let input = """
        This is a hyphen-
        ated word.
        """

        let result = PDFTextNormalizer.normalize(input)

        XCTAssertEqual(result, "This is a hyphenated word.")
    }

    func testHandlesMultipleBlankLines() {
        let input = """
        First paragraph.


        Second paragraph.
        """

        let result = PDFTextNormalizer.normalize(input)

        XCTAssertEqual(result, "First paragraph.\n\nSecond paragraph.")
    }

    func testHandlesEmptyInput() {
        let result = PDFTextNormalizer.normalize("")
        XCTAssertEqual(result, "")
    }

    func testHandlesSingleLine() {
        let result = PDFTextNormalizer.normalize("Single line of text.")
        XCTAssertEqual(result, "Single line of text.")
    }
}
