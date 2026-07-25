//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
private final class CSSSettingsDelegateSpy: EPUBNavigatorViewModelDelegate {
    var capturedScripts: [String] = []

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, applyCSSSettings script: String) {
        capturedScripts.append(script)
    }

    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {}

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {}
}

@MainActor
final class EPUBNavigatorViewModelCSSSettingsTests: XCTestCase {
    private func makeViewModel(delegate: EPUBNavigatorViewModelDelegate) -> EPUBNavigatorViewModel {
        let href = RelativeURL(path: "chapter.xhtml")!
        let links = [Link(href: href.string, mediaType: .xhtml)]
        let container = CompositeContainer([
            SingleResourceContainer(
                resource: DataResource(
                    string: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head></head><body>Body</body></html>"
                ),
                at: href.anyURL
            ),
        ])
        let publication = Publication(
            manifest: Manifest(
                metadata: Metadata(title: "CSS settings test"),
                readingOrder: links
            ),
            container: container
        )
        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: links,
            config: .init()
        )
        viewModel.delegate = delegate
        return viewModel
    }

    /// A runtime settings change must emit the FULL property snapshot (both the
    /// `--RS__*` reading-system bucket and the `--USER__*` user bucket), not
    /// just the bucket that changed. The spread coalesces settings changes
    /// newest-wins, so a snapshot that omitted the unchanged bucket could drop
    /// an earlier change's properties when a later one superseded it.
    func testSettingsChangeEmitsFullPropertySnapshotAcrossBothBuckets() throws {
        let delegate = CSSSettingsDelegateSpy()
        let viewModel = makeViewModel(delegate: delegate)

        // A font-size change touches the user bucket but does not invalidate
        // pagination, so it commits a CSS change immediately.
        viewModel.submitPreferences(EPUBPreferences(fontSize: 1.5))

        let script = try XCTUnwrap(delegate.capturedScripts.last)
        XCTAssertTrue(
            script.contains("--USER__"),
            "The snapshot must carry the user-property bucket"
        )
        XCTAssertTrue(
            script.contains("--RS__"),
            "The snapshot must carry the reading-system bucket even though only a user property changed"
        )
    }
}
