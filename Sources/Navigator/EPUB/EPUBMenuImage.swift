//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ImageIO
import Photos
import ReadiumShared
import UIKit
import UniformTypeIdentifiers

/// A packaged raster image offered by the EPUB image menu.
struct EPUBMenuImage {
    private static let byteLimit = 16 * 1024 * 1024
    private static let pixelLimit = 8 * 1024 * 1024
    private static let dimensionLimit = 8192
    private static let decodableTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    private let resource: Resource
    private let type: UTType

    static func resolve(_ url: URL, publication: Publication, baseURL: AbsoluteURL) -> Self? {
        guard
            publication.baseURL == nil, baseURL.scheme.rawValue == "readium",
            url.host == baseURL.host, let href = baseURL.relativize(url),
            let link = publication.linkWithHREF(href), !link.templated, link.url().relativeURL != nil,
            let mediaType = link.mediaType, mediaType.isBitmap,
            let type = UTType(mimeType: mediaType.string), decodableTypes.contains(type.identifier),
            let resource = publication.get(link),
            resource.sourceURL == nil || resource.sourceURL?.scheme == .file
        else { return nil }

        return Self(resource: resource, type: type)
    }

    func read() async -> Contents? {
        guard !Task.isCancelled, case let .success(length) = await resource.estimatedLength(),
              length.map({ $0 <= Self.byteLimit }) ?? true
        else { return nil }

        // The estimate is a hint. Request one extra byte to distinguish an oversized
        // entry, and cap the accumulator even if a resource returns a larger chunk.
        var bytes = Data()
        var oversized = false
        let result = await resource.stream(range: 0 ..< UInt64(Self.byteLimit + 1)) { chunk in
            guard !oversized, !Task.isCancelled else { return }
            guard chunk.count <= Self.byteLimit - bytes.count else {
                oversized = true
                return
            }
            bytes.append(chunk)
        }
        guard case .success = result, !oversized, !Task.isCancelled else { return nil }
        return Contents(bytes: bytes, type: type)
    }

    struct Contents: Sendable {
        fileprivate let bytes: Data
        fileprivate let type: UTType
        private let longestSide: Int

        fileprivate init?(bytes: Data, type: UTType) {
            guard
                let source = Self.imageSource(bytes),
                CGImageSourceGetType(source) as String? == type.identifier,
                CGImageSourceGetStatus(source) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= dimensionLimit, height <= dimensionLimit,
                width <= pixelLimit / height
            else { return nil }
            self.bytes = bytes
            self.type = type
            longestSide = max(width, height)
        }

        /// The first frame, oriented as displayed, without the source container's metadata.
        func pngData() async -> Data? {
            guard !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longestSide,
            ]
            let png = NSMutableData()
            guard
                let source = Self.imageSource(bytes),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return png as Data
        }

        private static func imageSource(_ bytes: Data) -> CGImageSource? {
            CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
    }

    static func save(_ contents: Contents) async throws {
        guard let reason = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String,
              !reason.isEmpty
        else { throw PHPhotosError(.accessRestricted) }
        try Task.checkCancellation()
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PHPhotosError(.accessUserDenied)
        }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = contents.type.identifier
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: contents.bytes, options: options)
        }
    }

    @MainActor static func share(_ contents: Contents, sourceView: UIView, sourceRect: CGRect) -> UIActivityViewController {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: contents.type, visibility: .all) { completion in
            completion(contents.bytes, nil)
            return nil
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.excludedActivityTypes = [.copyToPasteboard]
        controller.popoverPresentationController?.sourceView = sourceView
        controller.popoverPresentationController?.sourceRect = sourceRect
        return controller
    }
}
