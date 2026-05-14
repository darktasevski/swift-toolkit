//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@_spi(Testing) @testable import ReadiumNavigator
import XCTest

/// Pins the producer/consumer key-parity contract for visible-anchor
/// tracking. The host app populates `visibleAnchorTargets` using manifest-
/// relative hrefs (e.g. `OEBPS/c02.html` — the form `Chapter.startCfi`
/// carries), while the fork looks up using absolute `readium://…` URLs
/// built via `link.url(relativeTo: publicationBaseURL)`. Both must collapse
/// to the same path-only key or the observer never installs.
///
/// Mirror of the host-side normaliser
/// `ReaderFeature.State.normalizedBaseKey(_:)`. The two implementations
/// MUST agree byte-for-byte; if either diverges, the dispatch silently
/// fails and `visibleAnchorChanged` events never reach the reducer.
final class EPUBNavigatorViewModelPathOnlyKeyTests: XCTestCase {
    func test_relativeInput_returnedUnchanged() {
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(from: "OEBPS/c02.html"),
            "OEBPS/c02.html"
        )
    }

    func test_absoluteReadiumURL_stripsSchemeAndAuthority() {
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(
                from: "readium://example-uuid/OEBPS/c02.html"
            ),
            "OEBPS/c02.html"
        )
    }

    func test_absoluteHTTPURL_stripsSchemeAndAuthority() {
        // Generic scheme handling — the strip works for any URL with
        // `scheme://authority/path` shape, not just `readium://`.
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(
                from: "https://example.com/OEBPS/c02.html"
            ),
            "OEBPS/c02.html"
        )
    }

    func test_percentEncodedPath_preservedNotDecoded() {
        // Producer side may store keys with percent-encoded paths (e.g.
        // spaces, non-ASCII). String-level slicing must NOT decode; both
        // sides must agree on the same encoded form.
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(
                from: "readium://uuid/OEBPS/has%20space.html"
            ),
            "OEBPS/has%20space.html"
        )
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(from: "OEBPS/has%20space.html"),
            "OEBPS/has%20space.html"
        )
    }

    func test_idempotent_relativeAndAbsoluteCollapseToSameKey() {
        // The defining contract: producer-side relative hrefs and
        // consumer-side absolute hrefs MUST yield the same key.
        let relative = EPUBNavigatorViewModel.pathOnlyKey(
            from: "OEBPS/c02.html"
        )
        let absolute = EPUBNavigatorViewModel.pathOnlyKey(
            from: "readium://uuid/OEBPS/c02.html"
        )
        XCTAssertEqual(relative, absolute)

        // Idempotence: re-applying the strip to an already-stripped key
        // returns the same value. Guards against double-normalisation bugs.
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(from: absolute),
            absolute
        )
    }

    func test_absoluteURL_emptyPathAfterAuthority_returnsEmptyString() {
        // `readium://host/` — authority present, path is just `/`.
        // afterAuthority = "/", firstIndex(of: "/") = startIndex,
        // index(after:) = endIndex, slice = "".
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(from: "readium://host/"),
            ""
        )
    }

    func test_absoluteURL_noPathAtAll_returnsEmptyString() {
        // `readium://host` — no path separator after authority.
        // Per the guard, returns `""`. Real EPUB hrefs always carry a
        // path, but the helper must not crash on malformed input.
        XCTAssertEqual(
            EPUBNavigatorViewModel.pathOnlyKey(from: "readium://host"),
            ""
        )
    }
}
