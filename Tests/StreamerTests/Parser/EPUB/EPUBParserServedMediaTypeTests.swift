//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
@testable import ReadiumStreamer
import XCTest

final class EPUBParserServedMediaTypeTests: XCTestCase {
    func testBuiltPublicationLinksContainEffectiveHrefSniffedMediaType() async throws {
        let fixtures = Fixtures()
        let container = FileContainer(files: [
            RelativeURL(path: "META-INF/container.xml")!: fixtures.url(for: "Container/container.xml"),
            RelativeURL(path: "EPUB/content.opf")!: fixtures.url(for: "OPF/minimal.opf"),
            RelativeURL(path: "EPUB/titlepage.xhtml")!: fixtures.url(for: "Navigation Documents/nav.xhtml"),
        ])
        let asset = Asset.container(ContainerAsset(
            container: container,
            format: Format(specifications: .epub, mediaType: .epub, fileExtension: "epub")
        ))

        let publication = try await EPUBParser()
            .parse(asset: asset, warnings: nil)
            .get()
            .build()

        XCTAssertEqual(publication.readingOrder.count, 1)
        XCTAssertEqual(publication.readingOrder.first?.href, "EPUB/titlepage.xhtml")
        XCTAssertEqual(publication.readingOrder.first?.mediaType, .xhtml)
    }

    func testAuxiliaryResourceContainsEffectiveHrefSniffedMediaType() async throws {
        let fixtures = Fixtures()
        let container = FileContainer(files: [
            RelativeURL(path: "META-INF/container.xml")!: fixtures.url(for: "Container/container.xml"),
            RelativeURL(path: "EPUB/content.opf")!: fixtures.url(for: "OPF/minimal.opf"),
            RelativeURL(path: "EPUB/titlepage.xhtml")!: fixtures.url(for: "Navigation Documents/nav.xhtml"),
            RelativeURL(path: "EPUB/styles/book.css")!: fixtures.url(for: "OPF/book.css"),
        ])
        let asset = Asset.container(ContainerAsset(
            container: container,
            format: Format(specifications: .epub, mediaType: .epub, fileExtension: "epub")
        ))

        let publication = try await EPUBParser()
            .parse(asset: asset, warnings: nil)
            .get()
            .build()

        let stylesheet = try XCTUnwrap(
            publication.resources.first { $0.href == "EPUB/styles/book.css" }
        )
        XCTAssertEqual(stylesheet.mediaType, .css)
    }
}
