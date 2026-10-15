//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// A click on a link leaving the publication reaches the navigator as an `externalLinkActivated`
/// message, because the page script cancels the click before WebKit can connect to the host. The
/// message body carries the link's absolute URL.
@MainActor
final class EPUBSpreadViewExternalLinkActivationTests: XCTestCase {
    func testTheBodyCarriesTheLinksURL() throws {
        let url = try XCTUnwrap(EPUBSpreadView.externalLinkURL(from: ["href": "https://example.com/a?t=1"]))
        XCTAssertEqual(url.absoluteString, "https://example.com/a?t=1")
    }

    func testABodyWithoutAnHrefCarriesNoURL() {
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: ["src": "https://example.com/"]))
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: "https://example.com/"))
    }
}
