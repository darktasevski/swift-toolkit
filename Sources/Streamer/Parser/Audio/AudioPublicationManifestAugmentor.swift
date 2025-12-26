//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared
import UIKit

/// Implements a strategy to augment a `Manifest` of an audio publication with additional metadata and
/// cover, for example by looking into the audio files metadata.
public protocol AudioPublicationManifestAugmentor {
    func augment(_ baseManifest: Manifest, using container: Container) async -> AudioPublicationAugmentedManifest
}

public struct AudioPublicationAugmentedManifest {
    public var manifest: Manifest
    public var cover: UIImage?

    public init(manifest: Manifest, cover: UIImage? = nil) {
        self.manifest = manifest
        self.cover = cover
    }
}

/// An `AudioPublicationManifestAugmentor` using AVFoundation to retrieve the audio metadata.
///
/// It will only work for local publications (file://).
public final class AVAudioPublicationManifestAugmentor: AudioPublicationManifestAugmentor {
    public init() {}

    public func augment(_ manifest: Manifest, using container: Container) async -> AudioPublicationAugmentedManifest {
        let avAssets = manifest.readingOrder.map { link in
            container[link.url()]?.sourceURL?.fileURL
                .map { AVURLAsset(url: $0.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        }
        var manifest = manifest
        manifest.readingOrder = zip(manifest.readingOrder, avAssets).map { link, avAsset in
            guard let avAsset = avAsset else { return link }
            var link = link
            link.title = avAsset.metadata.filter([.commonIdentifierTitle]).first(where: { $0.stringValue })
            link.duration = avAsset.duration.seconds
            return link
        }
        let avMetadata = avAssets.compactMap { $0?.metadata }.reduce([], +)
        var metadata = manifest.metadata
        metadata.localizedTitle = avMetadata.filter([.commonIdentifierTitle, .id3MetadataAlbumTitle]).first(where: { $0.stringValue })?.localizedString ?? manifest.metadata.localizedTitle
        metadata.localizedSubtitle = avMetadata.filter([.id3MetadataSubTitle, .iTunesMetadataTrackSubTitle]).first(where: { $0.stringValue })?.localizedString
        metadata.modified = avMetadata.filter([.commonIdentifierLastModifiedDate]).first(where: { $0.dateValue })
        metadata.published = avMetadata.filter([.commonIdentifierCreationDate, .id3MetadataDate]).first(where: { $0.dateValue })
        metadata.languages = avMetadata.filter([.commonIdentifierLanguage, .id3MetadataLanguage]).compactMap(\.stringValue).removingDuplicates()
        metadata.subjects = avMetadata.filter([.commonIdentifierSubject]).compactMap(\.stringValue).removingDuplicates().map { Subject(name: $0) }
        metadata.authors = avMetadata.filter([.commonIdentifierAuthor, .iTunesMetadataAuthor]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.artists = avMetadata.filter([.commonIdentifierArtist, .id3MetadataOriginalArtist, .iTunesMetadataArtist, .iTunesMetadataOriginalArtist]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.illustrators = avMetadata.filter([.iTunesMetadataAlbumArtist]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.contributors = avMetadata.filter([.commonIdentifierContributor]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.publishers = avMetadata.filter([.commonIdentifierPublisher, .id3MetadataPublisher, .iTunesMetadataPublisher]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.description = avMetadata.filter([.commonIdentifierDescription, .iTunesMetadataDescription]).first?.stringValue
        metadata.duration = avAssets.reduce(0) { duration, avAsset in
            guard let duration = duration, let avAsset = avAsset else { return nil }
            return duration + avAsset.duration.seconds
        }
        manifest.metadata = metadata

        // Extract QuickTime chapters from M4B/M4A files
        // Only extract if we have a single audio file (typical M4B audiobook)
        if manifest.tableOfContents.isEmpty, avAssets.count == 1, let avAsset = avAssets.first {
            manifest.tableOfContents = await extractChapters(from: avAsset, readingOrderLink: manifest.readingOrder.first)
        }

        let cover = avMetadata.filter([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]).first(where: { $0.dataValue.flatMap(UIImage.init(data:)) })
        return .init(manifest: manifest, cover: cover)
    }

    /// Extracts QuickTime chapter metadata from an AVAsset.
    ///
    /// M4B and M4A files can contain embedded chapter markers as QuickTime chapter atoms.
    /// This method extracts them and converts them to Readium Link objects for the table of contents.
    private func extractChapters(from avAsset: AVURLAsset?, readingOrderLink: Link?) async -> [Link] {
        guard let avAsset = avAsset else { return [] }

        // Get available chapter locales
        let locales: [Locale]
        if #available(iOS 15, macOS 12, *) {
            guard let loadedLocales = try? await avAsset.load(.availableChapterLocales), !loadedLocales.isEmpty else {
                return []
            }
            locales = loadedLocales
        } else {
            // Fallback for iOS < 15: use synchronous API
            locales = avAsset.availableChapterLocales
            guard !locales.isEmpty else { return [] }
        }

        // Prefer user's locale, fallback to first available
        let preferredLocale = locales.first { $0.identifier == Locale.current.identifier } ?? locales[0]

        // Load chapter metadata groups
        let chapterGroups: [AVTimedMetadataGroup]
        if #available(iOS 15, macOS 12, *) {
            guard let loadedGroups = try? await avAsset.loadChapterMetadataGroups(
                withTitleLocale: preferredLocale,
                containingItemsWithCommonKeys: [.commonKeyTitle]
            ), !loadedGroups.isEmpty else {
                return []
            }
            chapterGroups = loadedGroups
        } else {
            // Fallback for iOS < 15: use synchronous API
            chapterGroups = avAsset.chapterMetadataGroups(
                withTitleLocale: preferredLocale,
                containingItemsWithCommonKeys: [AVMetadataKey.commonKeyTitle]
            )
            guard !chapterGroups.isEmpty else { return [] }
        }

        // Get the base href from the reading order link
        let baseHref = readingOrderLink?.url().string ?? ""

        return chapterGroups.enumerated().compactMap { index, group in
            // Extract chapter title from metadata
            let titleItems = AVMetadataItem.metadataItems(
                from: group.items,
                filteredByIdentifier: .commonIdentifierTitle
            )
            let title = titleItems.first?.stringValue ?? "Chapter \(index + 1)"

            // Calculate start time in seconds
            // Validate CMTime to prevent NaN/Inf from creating malformed hrefs
            guard group.timeRange.start.isNumeric else {
                // Fallback: return a link without time fragment
                return Link(
                    href: baseHref,
                    mediaType: readingOrderLink?.mediaType,
                    title: title
                )
            }
            let startTime = group.timeRange.start.seconds

            // Create a link with time fragment for navigation
            // Format: "file.m4b#t=123.456" following Media Fragments URI spec
            let href = baseHref.isEmpty ? "#t=\(startTime)" : "\(baseHref)#t=\(startTime)"

            return Link(
                href: href,
                mediaType: readingOrderLink?.mediaType,
                title: title
            )
        }
    }
}

private extension [AVMetadataItem] {
    func filter(_ identifiers: [AVMetadataIdentifier]) -> [AVMetadataItem] {
        identifiers.flatMap { AVMetadataItem.metadataItems(from: self, filteredByIdentifier: $0) }
    }
}
