//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@_spi(Testing) @testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor final class EPUBNavigatorViewModelServedResourceTests: XCTestCase {
    func testServingUsesClosedDocumentKindForRepairAndReturnsResolvedMediaType() async throws {
        let xhtmlHREF = RelativeURL(path: "chapter.xhtml")!
        let htmlHREF = RelativeURL(path: "chapter.html")!
        let binaryHREF = RelativeURL(path: "resource.unknown")!
        let links = [
            Link(href: xhtmlHREF.string, mediaType: .xhtml),
            Link(href: htmlHREF.string),
            Link(href: binaryHREF.string),
        ]
        let container = CompositeContainer([
            SingleResourceContainer(
                resource: DataResource(string: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head></head><body>XHTML</body></html>"),
                at: xhtmlHREF.anyURL
            ),
            SingleResourceContainer(
                resource: DataResource(string: "<!doctype html><html><head></head><body>HTML</body></html>"),
                at: htmlHREF.anyURL
            ),
            SingleResourceContainer(
                resource: DataResource(data: Data([0x00, 0x01, 0x02])),
                at: binaryHREF.anyURL
            ),
        ])
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Served resource policy test"),
                readingOrder: links
            ),
            container: container
        )
        let repairSpy = NavigatorRepairSpy()
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: links,
            config: .init(xhtmlRepairTransform: { href, data in
                await repairSpy.repair(href: href, data: data)
            })
        )

        let optionalXHTMLResponse = await viewModel.serve(href: xhtmlHREF)
        let xhtmlResponse = try XCTUnwrap(optionalXHTMLResponse)
        XCTAssertEqual(xhtmlResponse.1, .xhtml)
        _ = try await xhtmlResponse.0.read().get()

        let optionalHTMLResponse = await viewModel.serve(href: htmlHREF)
        let htmlResponse = try XCTUnwrap(optionalHTMLResponse)
        XCTAssertEqual(htmlResponse.1, .html)
        _ = try await htmlResponse.0.read().get()

        let optionalBinaryResponse = await viewModel.serve(href: binaryHREF)
        let binaryResponse = try XCTUnwrap(optionalBinaryResponse)
        XCTAssertEqual(binaryResponse.1, .binary)
        _ = try await binaryResponse.0.read().get()

        let repairedHREFs = await repairSpy.repairedHREFs
        XCTAssertEqual(repairedHREFs, [xhtmlHREF, htmlHREF])
    }
}

private actor NavigatorRepairSpy {
    private(set) var repairedHREFs: [RelativeURL] = []

    func repair(href: RelativeURL, data: Data) -> Data {
        repairedHREFs.append(href)
        return data
    }
}
