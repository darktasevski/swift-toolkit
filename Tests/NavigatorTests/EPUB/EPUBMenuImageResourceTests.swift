//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ImageIO
@testable import ReadiumNavigator
import ReadiumShared
import UniformTypeIdentifiers
import XCTest

final class EPUBMenuImageResourceTests: XCTestCase {
    func testPackagedJPEGConvertsToPNG() async throws {
        let jpeg = try imageData(type: .jpeg, width: 2, height: 3)
        let image = try XCTUnwrap(resolve(data: jpeg, mediaType: .jpeg))
        let contents = await image.read()
        let local = try XCTUnwrap(contents)
        let data = await local.pngData()
        let png = try XCTUnwrap(data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.height, 3)
    }

    func testOnlyCurrentPackagedBitmapResourcesAreAdmitted() {
        XCTAssertNotNil(resolve())
        XCTAssertNil(resolve(location: "https://example.org/image.png"))
        XCTAssertNil(resolve(location: "readium://other/image.png"))
        XCTAssertNil(resolve(location: "readium://book/missing.png"))
        XCTAssertNil(resolve(mediaType: .svg))
        XCTAssertNil(resolve(sourceURL: AnyURL(string: "https://example.org/image.png")?.absoluteURL))
    }

    func testWrongEncodedTypeIsRejected() async throws {
        let png = try imageData(type: .png, width: 2, height: 3)
        let image = try XCTUnwrap(resolve(data: png, mediaType: .jpeg))
        let content = await image.read()
        XCTAssertNil(content)
    }

    func testByteLimitHoldsWithoutLengthMetadata() async throws {
        var png = try imageData(type: .png, width: 1, height: 1)
        png.append(Data(count: 16 * 1024 * 1024))
        let image = try XCTUnwrap(resolve(data: png))
        let content = await image.read()
        XCTAssertNil(content)
    }

    func testCompressedImageAboveDecodedPixelBudgetIsRejected() async throws {
        let png = try imageData(type: .png, width: 4096, height: 2049)
        let image = try XCTUnwrap(resolve(data: png))
        let content = await image.read()
        XCTAssertNil(content)
    }

    private func resolve(
        data: Data = Data(),
        location: String = "readium://book/image.png",
        mediaType: MediaType = .png,
        sourceURL: AbsoluteURL? = nil
    ) -> EPUBMenuImage? {
        let href = RelativeURL(path: "image.png")!
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Fixture"), readingOrder: [],
                resources: [Link(href: href.string, mediaType: mediaType)]
            ),
            container: SingleResourceContainer(resource: DataResource(data: data, sourceURL: sourceURL), at: href.anyURL)
        )
        return EPUBMenuImage.resolve(
            URL(string: location)!, publication: publication,
            baseURL: AnyURL(string: "readium://book/")!.absoluteURL!
        )
    }

    private func imageData(type: UTType, width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
