//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
@testable import ReadiumShared
import XCTest

/// A click on a link leaving the publication reaches the navigator as an `externalLinkActivated`
/// message, because the page script cancels the click before WebKit can connect to the host. The
/// message body carries the link's absolute URL, as the page's `URL` parser serialized it.
@MainActor
final class EPUBSpreadViewExternalLinkActivationTests: XCTestCase {
    private var logger: CapturingLogger!
    private var priorLogger: LoggerType?
    private var priorMinimumSeverityLevel: SeverityLevel?

    override func setUp() {
        super.setUp()
        // Snapshot rather than reset: the framework default is no logger at all.
        priorLogger = Logger.sharedInstance.activeLogger
        priorMinimumSeverityLevel = Logger.sharedInstance.minimumSeverityLevel
        logger = CapturingLogger()
        Logger.sharedInstance.activeLogger = logger
        Logger.sharedInstance.minimumSeverityLevel = .trace
    }

    override func tearDown() {
        Logger.sharedInstance.activeLogger = priorLogger
        Logger.sharedInstance.minimumSeverityLevel = priorMinimumSeverityLevel
        logger = nil
        super.tearDown()
    }

    func testTheBodyCarriesTheLinksURL() throws {
        let url = try XCTUnwrap(EPUBSpreadView.externalLinkURL(from: ["href": "https://example.com/a?t=1"]))
        XCTAssertEqual(url.absoluteString, "https://example.com/a?t=1")
    }

    func testABodyWithoutAnHrefCarriesNoURL() {
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: ["src": "https://example.com/"]))
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: "https://example.com/"))
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: ["href": 42]))
        XCTAssertNil(EPUBSpreadView.externalLinkURL(from: ["href": ""]))
    }

    /// The page's parser leaves `|` unescaped in a path; refusing it would make the tap do nothing.
    func testAnHrefTheWebParserLeavesUnescapedStillCarriesAURL() throws {
        let url = try XCTUnwrap(EPUBSpreadView.externalLinkURL(from: ["href": "https://example.com/a|b"]))
        XCTAssertEqual(url.host, "example.com")
        XCTAssertEqual(url.path, "/a|b")
    }

    func testPunycodeAndIPv6HostsArriveAsSerialized() throws {
        let idn = try XCTUnwrap(EPUBSpreadView.externalLinkURL(from: ["href": "https://xn--bcher-kva.example/"]))
        XCTAssertEqual(idn.absoluteString, "https://xn--bcher-kva.example/")
        let ipv6 = try XCTUnwrap(EPUBSpreadView.externalLinkURL(from: ["href": "https://[::1]:8443/p"]))
        XCTAssertEqual(ipv6.absoluteString, "https://[::1]:8443/p")
    }

    func testAnActivationHandsTheURLToTheDelegate() throws {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: "<!doctype html><html><body>Chapter</body></html>")
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate

        spreadView.didActivateExternalLink(["href": "https://example.com/a"])

        XCTAssertEqual(delegate.externalURLs, [try XCTUnwrap(URL(string: "https://example.com/a"))])
        XCTAssertFalse(logger.captured.contains { $0.contains("reason=malformed_link_activation_body") })
    }

    func testAMalformedActivationIsReportedAndHandsOverNothing() {
        let spreadView = EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: "<!doctype html><html><body>Chapter</body></html>")
        let delegate = RecordingSpreadDelegate()
        spreadView.delegate = delegate

        spreadView.didActivateExternalLink(["src": "https://example.com/a"])

        XCTAssertEqual(delegate.externalURLs, [])
        XCTAssertTrue(logger.captured.contains { $0.contains("reason=malformed_link_activation_body") })
    }
}
