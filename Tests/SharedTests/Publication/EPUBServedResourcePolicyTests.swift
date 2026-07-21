//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumShared
import XCTest

final class EPUBServedResourcePolicyTests: XCTestCase {
    func testManifestDeclarationTakesPrecedence() {
        let resolution = EPUBServedResourcePolicy.resolve(
            manifestMediaType: .xhtml,
            resourceMediaType: .html,
            sniffedMediaType: .pdf
        )

        XCTAssertEqual(resolution.mediaType, .xhtml)
        XCTAssertEqual(resolution.documentKind, .xhtml)
    }

    func testResourcePropertiesTakePrecedenceOverHrefSniff() {
        let resolution = EPUBServedResourcePolicy.resolve(
            manifestMediaType: nil,
            resourceMediaType: .html,
            sniffedMediaType: .pdf
        )

        XCTAssertEqual(resolution.mediaType, .html)
        XCTAssertEqual(resolution.documentKind, .html)
    }

    func testHrefSniffIsUsedWhenDeclarationsAreAbsent() {
        let resolution = EPUBServedResourcePolicy.resolve(
            manifestMediaType: nil,
            resourceMediaType: nil,
            sniffedMediaType: .xhtml
        )

        XCTAssertEqual(resolution.mediaType, .xhtml)
        XCTAssertEqual(resolution.documentKind, .xhtml)
    }

    func testBinaryIsTheFinalFallback() {
        let resolution = EPUBServedResourcePolicy.resolve(
            manifestMediaType: nil,
            resourceMediaType: nil,
            sniffedMediaType: nil
        )

        XCTAssertEqual(resolution.mediaType, .binary)
        XCTAssertEqual(resolution.documentKind, .binary)
    }

    func testOnlyHTMLKindsRequireCanonicalRepair() {
        XCTAssertTrue(EPUBServedDocumentKind.xhtml.requiresCanonicalRepair)
        XCTAssertTrue(EPUBServedDocumentKind.html.requiresCanonicalRepair)
        XCTAssertFalse(EPUBServedDocumentKind.binary.requiresCanonicalRepair)
    }

    func testCurrentRecipeFingerprintGolden() {
        let golden = String(
            decoding: Fixtures().data(at: "epub-served-resource-recipe-v1.txt"),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(EPUBServedResourceRecipe.current.version, 1)
        XCTAssertEqual(EPUBServedResourceRecipe.current.fingerprint, golden)
    }

    func testAsyncManifestDeclarationSkipsResourcePropertiesAndHrefSniff() async {
        let resource = ServedResourcePolicySpyResource(mediaType: .html)
        let formatSniffer = ServedResourcePolicySpyFormatSniffer(mediaType: .pdf)

        let resolution = await EPUBServedResourcePolicy.resolve(
            manifestMediaType: .xhtml,
            resource: resource,
            at: AnyURL(string: "chapter.xhtml")!,
            formatSniffer: formatSniffer
        )

        XCTAssertEqual(resolution.mediaType, .xhtml)
        let propertiesCallCount = await resource.propertiesCallCount
        XCTAssertEqual(propertiesCallCount, 0)
        XCTAssertEqual(formatSniffer.callCount, 0)
    }

    func testAsyncResourcePropertiesSkipHrefSniff() async {
        let resource = ServedResourcePolicySpyResource(mediaType: .html)
        let formatSniffer = ServedResourcePolicySpyFormatSniffer(mediaType: .pdf)

        let resolution = await EPUBServedResourcePolicy.resolve(
            manifestMediaType: nil,
            resource: resource,
            at: AnyURL(string: "chapter.xhtml")!,
            formatSniffer: formatSniffer
        )

        XCTAssertEqual(resolution.mediaType, .html)
        let propertiesCallCount = await resource.propertiesCallCount
        XCTAssertEqual(propertiesCallCount, 1)
        XCTAssertEqual(formatSniffer.callCount, 0)
    }

    func testAsyncHrefSniffRunsWhenDeclarationsAreAbsent() async {
        let resource = ServedResourcePolicySpyResource(mediaType: nil)
        let formatSniffer = ServedResourcePolicySpyFormatSniffer(mediaType: .xhtml)

        let resolution = await EPUBServedResourcePolicy.resolve(
            manifestMediaType: nil,
            resource: resource,
            at: AnyURL(string: "chapter.xhtml")!,
            formatSniffer: formatSniffer
        )

        XCTAssertEqual(resolution.mediaType, .xhtml)
        let propertiesCallCount = await resource.propertiesCallCount
        XCTAssertEqual(propertiesCallCount, 1)
        XCTAssertEqual(formatSniffer.callCount, 1)
    }
}

private actor ServedResourcePolicySpyResource: Resource {
    nonisolated let sourceURL: AbsoluteURL? = nil

    private let mediaType: MediaType?
    private(set) var propertiesCallCount = 0

    init(mediaType: MediaType?) {
        self.mediaType = mediaType
    }

    func estimatedLength() async -> ReadResult<UInt64?> {
        .success(0)
    }

    func properties() async -> ReadResult<ResourceProperties> {
        propertiesCallCount += 1
        return .success(ResourceProperties { $0.mediaType = mediaType })
    }

    func stream(
        range: Range<UInt64>?,
        consume: @escaping (Data) -> Void
    ) async -> ReadResult<Void> {
        .success(())
    }
}

private final class ServedResourcePolicySpyFormatSniffer: HintsFormatSniffer, @unchecked Sendable {
    private let lock = NSLock()
    private let mediaType: MediaType?
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    init(mediaType: MediaType?) {
        self.mediaType = mediaType
    }

    func sniffHints(_ hints: FormatHints) -> Format? {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return mediaType.map { Format(mediaType: $0) }
    }
}
