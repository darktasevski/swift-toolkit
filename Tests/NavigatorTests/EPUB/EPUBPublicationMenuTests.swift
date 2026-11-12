//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

@MainActor
final class EPUBPublicationMenuTests: XCTestCase {
    func testUnlockedProtectedPublicationOffersNoImageMenu() {
        XCTAssertNil(imageMenu(protected: true, hasCopySink: true))
    }

    func testUnprotectedPublicationWithCopySinkOffersCopySaveAndShare() throws {
        let menu = try XCTUnwrap(imageMenu(protected: false, hasCopySink: true))
        XCTAssertEqual(menu.actions.map(\.title), titles([.copy, .save, .share]))
    }

    func testUnprotectedPublicationWithoutCopySinkOffersSaveAndShare() throws {
        let menu = try XCTUnwrap(imageMenu(protected: false, hasCopySink: false))
        XCTAssertEqual(menu.actions.map(\.title), titles([.save, .share]))
    }

    func testBothSpreadLayoutsConstructWebViewsWithLinkPreviewDisabled() {
        let chapter = "<html><body>Chapter</body></html>"
        let spreads: [EPUBSpreadView] = [
            EPUBSpreadViewHosting.makeReflowableSpreadView(chapter: chapter),
            EPUBSpreadViewHosting.makeFixedSpreadView(chapter: chapter),
        ]
        for spread in spreads {
            XCTAssertFalse(spread.webView.allowsLinkPreview)
            spread.webView.allowsLinkPreview = true
            XCTAssertFalse(spread.webView.allowsLinkPreview)
        }
    }

    func testPerformingCopyDeliversAPNGOnlyForAnUnprotectedPublication() async throws {
        for protected in [true, false] {
            var writes = [Data]()
            let (spread, url) = makeFixture(protected: protected) { writes.append($0) }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.addSubview(spread)
            defer { spread.removeFromSuperview() }
            let image = try XCTUnwrap(EPUBMenuImage.resolve(url, publication: spread.viewModel.publication, baseURL: spread.viewModel.publicationBaseURL))

            await spread.performImageAction(.copy, image: image, at: .zero, generation: spread.readiness.generation)

            if protected {
                XCTAssertTrue(writes.isEmpty)
            } else {
                XCTAssertEqual(writes.count, 1)
                let data = try XCTUnwrap(writes.first)
                XCTAssertTrue(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
                XCTAssertNotNil(UIImage(data: data))
            }
            withExtendedLifetime(window) {}
        }
    }

    private func titles(_ actions: [EPUBPublicationMenu.ImageAction]) -> [String?] {
        actions.map(\.title)
    }

    private func imageMenu(protected: Bool, hasCopySink: Bool) -> UIAlertController? {
        let sink: (@MainActor @Sendable (Data) -> Void)?
        if hasCopySink {
            sink = { _ in XCTFail("Opening the menu performed Copy") }
        } else {
            sink = nil
        }
        let (spread, url) = makeFixture(protected: protected, copySink: sink)
        return spread.imageMenu(for: url, at: .zero)
    }

    private func makeFixture(protected: Bool, copySink: (@MainActor @Sendable (Data) -> Void)?) -> (EPUBReflowableSpreadView, URL) {
        let chapter = Link(href: "chapter.xhtml", mediaType: .xhtml)
        let image = Link(href: "figure.png", mediaType: .png)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        let container = CompositeContainer(
            SingleResourceContainer(resource: DataResource(string: "<html><body><img src='figure.png' /></body></html>"), at: chapter.url()),
            SingleResourceContainer(resource: DataResource(data: png), at: image.url())
        )
        var services = PublicationServicesBuilder()
        if protected {
            services.setContentProtectionServiceFactory { _ in UnlockedProtection() }
        }
        let publication = Publication(
            manifest: Manifest(metadata: Metadata(title: "Fixture"), readingOrder: [chapter], resources: [image]),
            container: container, servicesBuilder: services
        )
        var config = EPUBNavigatorViewController.Configuration()
        config.copyImage = copySink
        let model = EPUBNavigatorViewModel(publication: publication, readingOrder: [chapter], config: config)
        let spread = EPUBReflowableSpreadView(
            viewModel: model, spread: .single(EPUBSingleSpread(resource: EPUBSpreadResource(index: 0, link: chapter))),
            scripts: [], animatedLoad: false
        )
        let url = model.publicationBaseURL.url.appendingPathComponent(image.href)
        return (spread, url)
    }

    /// An unlocked DRM book can permit text copy. The navigator lacks an image-copy grant for it.
    private struct UnlockedProtection: ContentProtectionService {
        let scheme = ContentProtectionScheme.lcp
        let isRestricted = false
        let error: Error? = nil
    }
}
