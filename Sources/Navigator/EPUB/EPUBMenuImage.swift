//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ImageIO
import ReadiumShared
import UIKit
import UniformTypeIdentifiers

/// A packaged raster image offered by the EPUB image menu.
struct EPUBMenuImage {
    private static let byteLimit = 16 * 1024 * 1024
    private static let pixelLimit = 8 * 1024 * 1024
    private static let dimensionLimit = 8192
    /// The EPUB core raster media types, so ImageIO never parses a rarer format on a
    /// book's behalf.
    private static let admittedTypes: Set<UTType> = [.jpeg, .png, .gif, .webP]

    private let resource: Resource
    let fileStem: String

    static func resolve(_ url: URL, publication: Publication, baseURL: AbsoluteURL) -> Self? {
        guard
            publication.baseURL == nil, baseURL.scheme.rawValue == "readium",
            url.host == baseURL.host, let href = baseURL.relativize(url),
            let link = publication.linkWithHREF(href), !link.templated, link.url().relativeURL != nil,
            let mediaType = link.mediaType, mediaType.isBitmap,
            let resource = publication.get(link),
            resource.sourceURL == nil || resource.sourceURL?.scheme == .file
        else { return nil }

        return Self(resource: resource, fileStem: fileStem(for: url))
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
        return Contents(bytes: bytes)
    }

    struct Contents: Sendable {
        fileprivate let bytes: Data
        /// The encoded type, which Save and Share declare. Manifests often mislabel
        /// images, so the bytes decide it rather than the declared media type.
        let type: UTType
        private let longestSide: Int

        fileprivate init?(bytes: Data) {
            guard
                let source = Self.imageSource(bytes),
                let identifier = CGImageSourceGetType(source) as String?,
                let type = UTType(identifier), EPUBMenuImage.admittedTypes.contains(type),
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

    /// The name the exported file takes: the resource's own, without characters a
    /// file system reserves.
    private static func fileStem(for url: URL) -> String {
        let reserved = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let stem = url.deletingPathExtension().lastPathComponent
            .components(separatedBy: reserved).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))
        return stem.isEmpty ? "image" : String(stem.prefix(80))
    }
}

/// A temporary copy of a menu image for the Files export sheet: a save panel on Mac Catalyst,
/// the Files browser on iOS. The sheet copies the file to the folder the user picks, so Save
/// Image needs no Photos access. The temporary copy is removed when the sheet finishes.
@MainActor
final class EPUBImageExport: NSObject, UIDocumentPickerDelegate {
    let picker: UIDocumentPickerViewController
    let file: URL
    var onFinish: (() -> Void)?
    private let directory: URL

    init(_ contents: EPUBMenuImage.Contents, of image: EPUBMenuImage) throws {
        let fileManager = FileManager.default
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("ReadiumImageExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = directory.appendingPathComponent(image.fileStem)
            .appendingPathExtension(contents.type.preferredFilenameExtension ?? "image")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try contents.bytes.write(to: file, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        super.init()
        picker.delegate = self
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt _: [URL]) {
        finish()
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        finish()
    }

    func finish() {
        try? FileManager.default.removeItem(at: directory)
        onFinish?()
        onFinish = nil
    }
}
