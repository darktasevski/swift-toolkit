//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

final class EPUBLocatorCommandDecoderTests: XCTestCase {
    func test_validRenderFaithfulLocator_isAccepted() throws {
        let payload = try decode(
            """
            {
              "href":"chapter.xhtml",
              "type":"application/xhtml+xml",
              "locations":{
                "progression":0.25,
                "cssSelector":"#chapter",
                "domRange":{
                  "start":{"cssSelector":"#start","textNodeIndex":0,"charOffset":1},
                  "end":{"cssSelector":"#end","textNodeIndex":1,"charOffset":4}
                }
              },
              "text":{"before":"before","highlight":"selected text","after":"after"}
            }
            """
        )

        XCTAssertEqual(payload.href, "chapter.xhtml")
        XCTAssertNotNil(payload.locator.object)
    }

    func test_payloadOver64KiB_isRejectedBeforeParsing() {
        let json = "{\"href\":\"chapter.xhtml\",\"title\":\"\(String(repeating: "a", count: 65536))\"}"
        assertRejected(json, as: .payloadTooLarge)
    }

    func test_nestingOverSixLevels_isRejected() {
        assertRejected("[[[[[[[]]]]]]]", as: .nestingTooDeep)
    }

    func test_duplicateFieldIncludingEscapedSpelling_isRejected() {
        assertRejected("{\"href\":\"a\",\"h\\u0072ef\":\"b\"}", as: .duplicateField)
    }

    func test_unknownField_isRejected() {
        assertRejected("{\"href\":\"chapter.xhtml\",\"publisherPayload\":true}", as: .unknownField)
    }

    func test_presentFieldsWithWrongJSONTypes_areRejectedAsInvalid() {
        assertRejected("{\"href\":42}", as: .invalidField)
        assertRejected("{\"href\":\"chapter.xhtml\",\"type\":false}", as: .invalidField)
        assertRejected("{\"href\":\"chapter.xhtml\",\"locations\":[]}", as: .invalidField)
        assertRejected("{\"href\":\"chapter.xhtml\",\"locations\":{\"fragments\":[1]}}", as: .invalidField)
        assertRejected("{\"href\":\"chapter.xhtml\",\"text\":[]}", as: .invalidField)
    }

    func test_hrefAndTitleCaps_countUTF16CodeUnits() throws {
        _ = try decode(locator(href: String(repeating: "a", count: 4096)))
        assertRejected(locator(href: String(repeating: "a", count: 4097)), as: .stringTooLong)

        _ = try decode(locator(title: String(repeating: "🚀", count: 2048)))
        assertRejected(locator(title: String(repeating: "🚀", count: 2049)), as: .stringTooLong)
    }

    func test_generalStringCap_countsUTF16CodeUnits() throws {
        _ = try decode(locator(type: String(repeating: "🚀", count: 8192)))
        assertRejected(locator(type: String(repeating: "🚀", count: 8193)), as: .stringTooLong)
    }

    func test_selectorCap_countsUTF16CodeUnits() throws {
        _ = try decode(locator(cssSelector: String(repeating: "a", count: 8192)))
        assertRejected(locator(cssSelector: String(repeating: "a", count: 8193)), as: .selectorTooLong)
    }

    func test_quoteContextCaps_countUTF16CodeUnits() throws {
        // `selection.js` persists up to 200 UTF-16 code units on each side of a selection.
        // The command decoder must accept that producer contract so newly-created and existing
        // EPUB highlights can reach the isolated decoration renderer.
        _ = try decode(locator(before: String(repeating: "🚀", count: 100), after: String(repeating: "a", count: 200)))
        assertRejected(locator(before: String(repeating: "🚀", count: 101)), as: .quoteContextTooLong)
        assertRejected(locator(after: String(repeating: "a", count: 201)), as: .quoteContextTooLong)
    }

    func test_highlightCap_countsUTF16CodeUnits() throws {
        _ = try decode(locator(highlight: String(repeating: "🚀", count: 8192)))
        assertRejected(locator(highlight: String(repeating: "🚀", count: 8193)), as: .highlightTooLong)
    }

    func test_progressionMustBeFiniteAndInRange() throws {
        _ = try decode(locator(progression: 0))
        _ = try decode(locator(progression: 1))
        assertRejected(locator(progression: -0.001), as: .invalidNumber)
        assertRejected(locator(progression: 1.001), as: .invalidNumber)
    }

    func test_indexesAndOffsetsMustBeNonnegativeIntegers() {
        assertRejected(locator(textNodeIndex: -1), as: .invalidInteger)
        assertRejected(locator(textNodeIndexLiteral: "0.5"), as: .invalidInteger)
        assertRejected(locator(charOffset: -1), as: .invalidInteger)
        assertRejected(locator(charOffsetLiteral: "1.5"), as: .invalidInteger)
    }

    func test_domRangeRequiresExactlyStartAndEndPoints() {
        assertRejected(
            "{\"href\":\"chapter.xhtml\",\"locations\":{\"domRange\":{\"start\":{\"cssSelector\":\"p\",\"textNodeIndex\":0,\"charOffset\":0}}}}",
            as: .invalidDOMRange
        )
        assertRejected(
            "{\"href\":\"chapter.xhtml\",\"locations\":{\"domRange\":{\"start\":{\"cssSelector\":\"p\",\"textNodeIndex\":0},\"end\":{\"cssSelector\":\"p\",\"textNodeIndex\":0},\"third\":{}}}}",
            as: .unknownField
        )
    }

    func test_malformedAndNonObjectJSON_areRejectedWithClosedReasons() {
        assertRejected("{", as: .malformed)
        assertRejected("[]", as: .invalidRoot)
        assertRejected("{\"title\":\"missing href\"}", as: .missingRequiredField)
    }

    private func decode(_ json: String) throws -> EPUBLocatorCommandPayload {
        try EPUBLocatorCommandDecoder.decode(json)
    }

    private func assertRejected(
        _ json: String,
        as expected: EPUBLocatorCommandRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            XCTAssertEqual(error as? EPUBLocatorCommandRejection, expected, file: file, line: line)
        }
    }

    private func locator(
        href: String = "chapter.xhtml",
        type: String? = nil,
        title: String? = nil,
        progression: Double? = nil,
        cssSelector: String? = nil,
        before: String? = nil,
        highlight: String? = nil,
        after: String? = nil,
        textNodeIndex: Int? = nil,
        textNodeIndexLiteral: String? = nil,
        charOffset: Int? = nil,
        charOffsetLiteral: String? = nil
    ) -> String {
        var fields = ["\"href\":\"\(href)\""]
        if let type {
            fields.append("\"type\":\"\(type)\"")
        }
        if let title {
            fields.append("\"title\":\"\(title)\"")
        }

        var locations: [String] = []
        if let progression {
            locations.append("\"progression\":\(progression)")
        }
        if let cssSelector {
            locations.append("\"cssSelector\":\"\(cssSelector)\"")
        }
        if textNodeIndex != nil || textNodeIndexLiteral != nil || charOffset != nil || charOffsetLiteral != nil {
            let index = textNodeIndexLiteral ?? textNodeIndex.map(String.init) ?? "0"
            let offset = charOffsetLiteral ?? charOffset.map(String.init) ?? "0"
            let point = "{\"cssSelector\":\"p\",\"textNodeIndex\":\(index),\"charOffset\":\(offset)}"
            locations.append("\"domRange\":{\"start\":\(point),\"end\":\(point)}")
        }
        if !locations.isEmpty {
            fields.append("\"locations\":{\(locations.joined(separator: ","))}")
        }

        var text: [String] = []
        if let before {
            text.append("\"before\":\"\(before)\"")
        }
        if let highlight {
            text.append("\"highlight\":\"\(highlight)\"")
        }
        if let after {
            text.append("\"after\":\"\(after)\"")
        }
        if !text.isEmpty {
            fields.append("\"text\":{\(text.joined(separator: ","))}")
        }

        return "{\(fields.joined(separator: ","))}"
    }
}
