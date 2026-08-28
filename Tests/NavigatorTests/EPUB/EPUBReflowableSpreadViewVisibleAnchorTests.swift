//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@_spi(Testing) @testable import ReadiumNavigator
import XCTest

final class EPUBReflowableSpreadViewVisibleAnchorTests: XCTestCase {
    func test_decode_validBody_returnsAnchorId() {
        XCTAssertEqual(
            EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": "title3"]),
            "title3"
        )
    }

    func test_decode_emptyAnchorId_returnsNil() {
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": ""]))
    }

    func test_decode_oversizedAnchorId_returnsNil() {
        let oversized = String(repeating: "a", count: 4097)
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": oversized]))
    }

    func test_decode_anchorIdAtCap_returnsAnchorId() {
        let atCap = String(repeating: "a", count: 4096)
        XCTAssertEqual(
            EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": atCap]),
            atCap
        )
    }

    func test_decode_nonStringPayload_returnsNil() {
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": 42]))
    }

    func test_decode_missingKey_returnsNil() {
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody(["other": "x"]))
    }

    func test_decode_nonDictionaryPayload_returnsNil() {
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody("title3" as Any))
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody([1, 2, 3] as Any))
    }

    func test_decode_multibyteAnchorIdUnderCap_returnsAnchorId() {
        // Multi-byte UTF-8 chars must count utf8.count, not String.count.
        // 4-byte emoji × 1024 = 4096 bytes (at cap).
        let emoji = String(repeating: "🚀", count: 1024)
        XCTAssertEqual(emoji.utf8.count, 4096)
        XCTAssertEqual(
            EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": emoji]),
            emoji
        )
    }

    func test_decode_multibyteAnchorIdOverCap_returnsNil() {
        // 4-byte emoji × 1025 = 4100 bytes (over cap).
        let emoji = String(repeating: "🚀", count: 1025)
        XCTAssertGreaterThan(emoji.utf8.count, 4096)
        XCTAssertNil(EPUBReflowableSpreadView.decodeVisibleAnchorBody(["anchorId": emoji]))
    }
}
