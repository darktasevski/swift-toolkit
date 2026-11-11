//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

/// A spread presents its own actions because WebKit's image Copy bypasses publication rights.
@MainActor
final class EPUBPublicationMenu {
    enum ImageAction {
        case copy, save, share

        var title: String {
            switch self {
            case .copy: return ReadiumNavigatorLocalizedString("ImageContextMenu.copy")
            case .save: return ReadiumNavigatorLocalizedString("ImageContextMenu.save")
            case .share: return ReadiumNavigatorLocalizedString("EditingAction.share")
            }
        }
    }

    private weak var sheet: UIAlertController?

    func present(_ sheet: UIAlertController, in spread: EPUBSpreadView, at rect: CGRect) {
        guard spread.window != nil, self.sheet?.presentingViewController == nil else { return }
        self.sheet = sheet
        sheet.popoverPresentationController?.sourceView = spread
        sheet.popoverPresentationController?.sourceRect = rect
        sheet.addAction(UIAlertAction(title: ReadiumNavigatorLocalizedString("ImageContextMenu.cancel"), style: .cancel))
        spread.delegate?.spreadView(spread, present: sheet)
    }

    func dismiss() {
        sheet?.dismiss(animated: false)
        sheet = nil
    }
}

extension EPUBSpreadView {
    func configurePublicationMenu() {
        imageMenuBridge.onRequest = { [weak self] url, point in
            guard let self, let sheet = imageMenu(for: url, at: point) else { return }
            publicationMenu.present(sheet, in: self, at: menuAnchor(point))
        }
        imageMenuBridge.onLinkRequest = { [weak self] url, point in
            guard let self, let link = Self.outboundLinkURL(for: url, publicationBaseURL: viewModel.publicationBaseURL) else { return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            let generation = readiness.generation
            sheet.addAction(UIAlertAction(title: Self.outboundLinkMenuTitle, style: .default) { [weak self] _ in
                guard let self, window != nil, generation == readiness.generation else { return }
                openOutboundLink(link)
            })
            publicationMenu.present(sheet, in: self, at: menuAnchor(point))
        }
    }

    private func menuAnchor(_ normalized: CGPoint) -> CGRect {
        CGRect(x: bounds.width * normalized.x, y: bounds.height * normalized.y, width: 1, height: 1)
    }

    private var imageCopySink: (@MainActor @Sendable (Data) -> Void)? {
        viewModel.publication.isProtected ? nil : viewModel.config.copyImage
    }

    func imageMenu(for url: URL, at point: CGPoint) -> UIAlertController? {
        guard let image = EPUBMenuImage.resolve(url, publication: viewModel.publication, baseURL: viewModel.publicationBaseURL) else { return nil }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let rect = menuAnchor(point)
        let generation = readiness.generation
        let actions: [EPUBPublicationMenu.ImageAction] = imageCopySink == nil ? [.save, .share] : [.copy, .save, .share]
        for action in actions {
            let item = UIAlertAction(title: action.title, style: .default) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.performImageAction(action, image: image, at: rect, generation: generation)
                }
            }
            if action == .copy {
                item.accessibilityIdentifier = "org.readium.navigator.image.copy"
            }
            sheet.addAction(item)
        }
        return sheet
    }

    func performImageAction(
        _ action: EPUBPublicationMenu.ImageAction,
        image: EPUBMenuImage,
        at rect: CGRect,
        generation: EPUBSpreadReadiness.Generation
    ) async {
        @MainActor func isCurrent() -> Bool {
            window != nil && readiness.generation == generation
        }
        guard isCurrent(), action != .copy || imageCopySink != nil else { return }
        guard let contents = await image.read() else {
            if isCurrent() {
                presentImageActionError()
            }
            return
        }
        guard isCurrent() else { return }
        switch action {
        case .copy:
            guard imageCopySink != nil else { return }
            guard let png = await contents.pngData() else {
                if isCurrent() {
                    presentImageActionError()
                }
                return
            }
            guard isCurrent(), let sink = imageCopySink else { return }
            sink(png)
        case .save:
            do {
                try await EPUBMenuImage.save(contents)
            } catch {
                if isCurrent() {
                    presentImageActionError()
                }
            }
        case .share:
            delegate?.spreadView(self, present: EPUBMenuImage.share(contents, sourceView: self, sourceRect: rect))
        }
    }

    private func presentImageActionError() {
        let alert = UIAlertController(title: ReadiumNavigatorLocalizedString("ImageContextMenu.unavailable"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ReadiumNavigatorLocalizedString("ImageContextMenu.ok"), style: .default))
        delegate?.spreadView(self, present: alert)
    }
}
