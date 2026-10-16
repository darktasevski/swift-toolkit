# Fork extensions (`fork-extensions` branch)

This document inventories the fork-only changes carried on the `fork-extensions` branch atop upstream Readium swift-toolkit. Maintainers doing upstream rebase work should preserve these across merges; the goal is for the fork to be a thin sidecar that can become a one-line bridge if upstream adopts an equivalent API.

For the design rationale + downstream consumer (Reader app), see [ADR-0106 in the host repository](../../docs/ADR/0106-readium-visible-anchor-tracking.md). The host repo's path is the canonical source for the design — this file is the rebase manifest.

## Visible-anchor tracking (ADR-0106)

Adds an IntersectionObserver-driven "topmost visible anchor" reporter so omnibus EPUBs (one spine resource carrying multiple NCX-anchored chapters) can resolve the chapter heading to display in the reader UI without relying on the lossy progression-derived heuristic the host app previously used.

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/Viewport/VisibleAnchorObservingNavigator.swift` | Sibling protocol mirroring upstream's `ViewportObservingNavigator` shape. Exposes `VisibleAnchorObservingNavigator` (marker, no requirements) + `@MainActor VisibleAnchorObservingNavigatorDelegate` (`navigator(_:didChangeVisibleAnchor:)` with empty default impl) + `VisibleAnchor { href, fragmentId }` payload struct. | Yes (matches upstream pattern). |
| `Sources/Navigator/EPUB/AnchorTrackingLimits.swift` | Defence-in-depth caps (`maxAnchorIdsPerResource = 256`, `maxAnchorIdByteLength = 4_096`) hoisted to a single chokepoint so the four call sites stay in lockstep. | Yes. |
| `Sources/Navigator/EPUB/Scripts/src/anchor-tracking.js` | JS module: `window.readium.initAnchorTracking(anchorIds)` installs an IntersectionObserver with `rootMargin: "0px"` (full viewport) tracking every visible anchor, scrollend-debounced, pagehide-cleaned, charset-filtered. The IO callback selects the LARGEST document-order anchor in the visible set — i.e. the most recently-passed heading — so iPad two-column spreads land on the right-column chapter (the one the user has progressed into) rather than the left-column predecessor. `emitInitialAnchorIfApplicable` reverse-iterates `trackedAnchorIds` to pick the largest-order anchor whose rect overlaps the viewport. Direction-neutral: document order encodes reading order regardless of writing mode. Imported from `index-reflowable.js`. | Yes. |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/EPUBNavigatorViewController.swift` | (1) `EPUBNavigatorDelegate` inheritance list adds `VisibleAnchorObservingNavigatorDelegate`. (2) Public class declaration adds `VisibleAnchorObservingNavigator` conformance. (3) New `visibleAnchorTargets:` init parameter (defaulted, source-compatible). (4) New `public func updateVisibleAnchorTargets(_:) async` orchestrator with `withTaskGroup` fan-out + `private func reinjectAnchorTracking(into:)` helper. (5) `EPUBSpreadViewDelegate.spreadView(_:visibleAnchorDidChange:)` impl bubbles to the navigator delegate. | Yes. |
| `Sources/Navigator/EPUB/EPUBNavigatorViewModel.swift` | New `private var visibleAnchorTargets: [String: [String]]` cache + `func anchorIds(forResourceAt:)` accessor + `func updateVisibleAnchorTargets(_:)` mutator with cap enforcement. Both accessor and mutator route keys through `@_spi(Testing) public nonisolated static func pathOnlyKey(from:)` — strips `scheme://authority/` so the conformer can populate the cache using manifest-relative hrefs (the form `Chapter.startCfi`-equivalent state carries) while the fork's spread-load lookup uses `link.url(relativeTo: viewModel.publicationBaseURL)` (absolute `readium://…` URLs). Without symmetric stripping the lookup misses, `initAnchorTracking` is called with an empty list, and the IntersectionObserver never installs. Mirrors the host's `ReaderFeature.State.normalizedBaseKey(_:)`; the two implementations MUST stay byte-for-byte compatible. | Yes. |
| `Sources/Navigator/EPUB/EPUBSpreadView.swift` | New `EPUBSpreadViewDelegate.spreadView(_:visibleAnchorDidChange:)` requirement + default no-op extension. | Yes. |
| `Sources/Navigator/EPUB/EPUBReflowableSpreadView.swift` | (1) `registerJSMessages()` registers `visibleAnchorChanged`. (2) `private func visibleAnchorDidChange(_:Any)` decodes payload (delegating to `@_spi(Testing) public static decodeVisibleAnchorBody`). (3) `spreadDidLoad()` issues `readium.initAnchorTracking(anchorIds)` via `callAsyncJavaScript` after pagination-settle delay; three `Task.isCancelled` checkpoints between sleep / go / sleep phases. | Yes. |
| `Sources/Navigator/EPUB/Scripts/src/index-reflowable.js` | One-line `import "./anchor-tracking";`. | Yes. |
| `Sources/Navigator/EPUB/Assets/Static/scripts/readium-{reflowable,fixed,fixed-wrapper-one,fixed-wrapper-two}.js` | Webpack-regenerated bundles. The fixed variants regenerate even though they don't import anchor-tracking — webpack's module-id counter is global. (See `docs/solutions/patterns/webpack-chunk-id-shift-sibling-bundles-20260508.md` in the host repo.) | Yes (build artifacts). |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/NavigatorTests/EPUB/EPUBReflowableSpreadViewVisibleAnchorTests.swift` | 9 tests covering `decodeVisibleAnchorBody`: valid, empty, oversized (4097 bytes), at-cap (4096), non-string, missing key, non-dictionary, multi-byte UTF-8 under-cap and over-cap. |
| `Tests/NavigatorTests/EPUB/EPUBNavigatorViewModelPathOnlyKeyTests.swift` | 7 tests pinning `EPUBNavigatorViewModel.pathOnlyKey(from:)`: relative input returned unchanged, absolute `readium://` and `https://` URLs strip scheme+authority, percent-encoding preserved (string-slicing, not `AnyURL.path` decode), relative/absolute idempotent collapse to the same key, malformed inputs (empty path after authority, no path separator) return `""` without crashing. |

### Pre-existing-bug fix carried alongside

| Commit | Path | Fix |
| --- | --- | --- |
| `3f3dd8bc` | `Tests/SharedTests/Publication/LocatorTests.swift` | `try Locator.Locations(json:)` returns optional; the test was subscripting the optional directly without unwrapping. Switched to `try XCTUnwrap`. Pre-existed before this fork branch; surfaced when D5's new tests forced a full test-target build. Worth submitting upstream as a one-line PR. |

## PDF content normalization

Carried since the v3.9.0 sync. Upstream #792 added the official `PDFResourceContentIterator` (one `TextContentElement` per page) and `ContentSearchService`. The fork's earlier duplicate PDF iterator + sentence extractor were deleted in favour of upstream's; the only retained fork value is column-break rejoin + de-hyphenation, applied as a thin decorator at the content-iterator seam so it benefits both TTS and PDF search.

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Streamer/Parser/PDF/PDFTextNormalizer.swift` | `public enum` pure-function normalizer: rejoins lines broken at PDF column width, preserves paragraph breaks, de-hyphenates words split at a line ending. `public` so the host app's own PDFKit-based search-indexing path can reuse the exact rules. | Yes — would complement the upstream Content API; worth pitching upstream (their 3.9.0 note flags sentence segmentation as still-unrefined). |
| `Sources/Streamer/Parser/PDF/NormalizingPDFContentIterator.swift` | `ContentIterator` decorator (+ nested `Factory: ResourceContentIteratorFactory`) wrapping `PDFResourceContentIterator`; rewrites each `TextContentElement`'s segment text + highlight through `PDFTextNormalizer`, preserving locator positions/fragments/progressions. | Yes (matches upstream decorator/factory shape). |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Streamer/Parser/PDF/PDFParser.swift` | Wraps the content-iterator factory: `NormalizingPDFContentIterator.Factory(wrapping: PDFResourceContentIterator.Factory())`. The sibling `search: ContentSearchService.makeFactory()` and `content:`/`positions:` wiring are upstream #792's. | Decorator wiring is fork-only; the rest is upstream. |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/StreamerTests/Parser/PDF/PDFTextNormalizerTests.swift` | 6 tests: within-paragraph join, paragraph-break preservation, hyphenation, multiple blank lines, empty, single-line. |
| `Tests/StreamerTests/Parser/PDF/NormalizingPDFContentIteratorTests.swift` | 6 tests: segment+highlight rejoin, hyphenation, locator preservation, end-of-iteration nil, non-text pass-through, `previous()` normalization. |

## Owned link context menu

A long-press on a link that leaves the publication showed WebKit's link menu, whose preview fetched the destination and whose "Open Link" went to Safari without consulting the navigation policy, so a host app that confirms outbound links (Reader app #3016) was bypassed. Returning `nil` from the UI delegate does not suppress it for an `http(s)` link: WebKit falls back to DataDetectors' URL menu. The spread view returns its own configuration instead: no preview, and one item that takes the tap path (`spreadView(_:didTapOnExternalURL:)`). Links inside the publication get `nil`; images keep WebKit's menu. Design record: [ADR-0186 in the host repository](../../docs/ADR/0186-converted-container-link-disposition.md).

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/EPUBSpreadView+LinkContextMenu.swift` | `EPUBSpreadView` answers `WKUIDelegate`'s `webView(_:contextMenuConfigurationForElement:completionHandler:)` through `linkContextMenuConfiguration(forLinkURL:)`. A long-press's outbound test is the navigation policy's (`publicationBaseURL.relativize`); a tap is classified first, in the page, by `external-link-activation.js` (below). The item's title is `ReadiumNavigator.LinkContextMenu.openLink`, which a host overrides from its main bundle. | Yes — upstream has the same bypass. |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/Resources/en.lproj/Localizable.strings` | Adds `ReadiumNavigator.LinkContextMenu.openLink` = "Open Link…". | Yes. |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewLinkContextMenuTests.swift` | 11 tests: internal, outbound, `mailto:`, no-link and no-base classification; the one-item menu and its default title; the spread view answering WebKit's selector; and the hook's configuration for an outbound, an internal and no link. That the menu replaces WebKit's on a device, with no preview request, is measured in the host app. |

## Outbound link clicks open no connection

A click on a link in a reflowable EPUB started a main-frame navigation, and WebKit connected to the target's host while it handled the click, before `webView(_:decidePolicyFor:decisionHandler:)` could cancel the navigation: the reader reached the host before a host app that confirms outbound links (Reader app #3016) had asked. Measured with a loopback listener: an accept at the tap, no bytes, the real request only on Open. A fixed-layout EPUB (its page is an iframe) and the PDF navigator did not connect. The page script now cancels the click of a link whose scheme or host differs from the document's and posts its URL. Its listeners go on the window, in the capture phase, as the bundle runs at document start, so no publication script's handler sees the click first. The navigation policy stays the path for anything the script does not see: a link inside a closed shadow root, and scripted navigation. A publication script can post the same message, so a book can raise the host's confirmation for a URL of its choosing; it cannot open anything by it. Design record: [ADR-0186 in the host repository](../../docs/ADR/0186-converted-container-link-disposition.md).

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/Scripts/src/external-link-activation.js` | Cancels a click — or a middle-button `auxclick` — on a link leaving the publication and posts `externalLinkActivated` with its URL. Finds the link through `composedPath()`, so a link in an open shadow root counts; reads `href`, or SVG's `xlink:href`; leaves alone a `javascript:` link and one on the document's own scheme and host. "Own" is the document's `location`, never a `<base href>`, and for an `about:srcdoc` or `about:blank` frame its embedder's. | Yes. |
| `Sources/Navigator/EPUB/EPUBSpreadView+ExternalLinkActivation.swift` | Handles the `externalLinkActivated` message: hands its `href` to `spreadView(_:didTapOnExternalURL:)`, or reports `malformedLinkActivationBody` to `EPUBPageWorldLog`. | No — it reports to the fork-only `EPUBPageWorldLog`; upstream would need its own logging in its place. |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/Scripts/src/index.js` | One line: imports `./external-link-activation`, so both the reflowable and the fixed-layout bundle carry it. The rebuilt `readium-reflowable.js` and `readium-fixed.js` are regenerated output. | Yes. |
| `Sources/Navigator/EPUB/EPUBSpreadView.swift` | Registers the `externalLinkActivated` message (one line beside `imageActivated`). | Yes. |

### Modified fork files

| Path | Change |
| --- | --- |
| `Sources/Navigator/EPUB/EPUBPageWorldLog.swift` | Adds the `malformedLinkActivationBody` reason, at `.warning`. The file is fork-only (absent from `3.11.0`). |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewExternalLinkClickTests.swift` | 2 hosted tests that drive the real bundles in a loaded web view, reflowable and fixed layout's iframe: which clicks are already cancelled when they reach the link and are handed over exactly once — `https`, an element inside a link, `mailto:`, SVG `href` and `xlink:href`, an image-map `area`, an open shadow root, a `srcdoc` frame, a middle-button `auxclick`, a link the publication's own capture listener stops, a `<base href>` on the link's host — and which are left to WebKit: another resource, a fragment, `javascript:`, no `href`, a right-button `auxclick`, another resource from a `srcdoc` frame. That no connection opens on a device, and that the confirmation still appears, is measured in the host app. |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewExternalLinkActivationTests.swift` | 6 tests: a body's `href` becomes the URL, including a `|` the web parser leaves unescaped and punycode and IPv6 hosts; a body without a usable `href` yields none; an activation reaches the delegate; a malformed one is reported and hands over nothing. |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewHosting.swift` | Test support: builds, hosts and waits for real spread views. The load waits and their #1693 earned-skip rule moved here unchanged from `EPUBSpreadViewCommandOutcomeTests`, so both suites share one copy. |
| `Tests/NavigatorTests/EPUB/EPUBPageWorldLogTests.swift` | The new reason joins the level table and the warning-floor count. The log-interpolation scan covers every `*SpreadView*.swift` source, listed from the directory, so both `EPUBSpreadView+*.swift` extensions are in it. |

## Upstream-rebase guidance

When merging upstream `develop` into `fork-extensions`:

1. Conflicts in `EPUBNavigatorViewController.swift` are most likely — the file has multiple modification points. Resolve by preserving the `VisibleAnchorObservingNavigator` conformance and the new orchestrator method.
2. Conflicts in `EPUBReflowableSpreadView.swift` — preserve the `registerJSMessages` second registration and the `spreadDidLoad` cancellation checkpoints + anchor-tracking init block. Upstream may rework `spreadDidLoad` independently; the cancellation checkpoints are themselves a defensive improvement worth keeping even if the rest of the body changes.
3. Conflicts in `EPUBSpreadView.swift` — preserve the new protocol method + default-impl extension.
4. After merge, regenerate the JS bundle (`pnpm run bundle` from `Sources/Navigator/EPUB/Scripts/`) — all four `Assets/Static/scripts/*.js` files will need re-staging due to the chunk-id shift.
5. Run the fork-side test suite: `xcodebuild test -scheme Readium-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ReadiumNavigatorTests/EPUBReflowableSpreadViewVisibleAnchorTests` should pass 9/9.
6. In `PDFParser.swift`, preserve the `NormalizingPDFContentIterator.Factory(wrapping:)` wrapper around the content-iterator factory; the two `Sources/Streamer/Parser/PDF/` files (`PDFTextNormalizer.swift`, `NormalizingPDFContentIterator.swift`) are fork-only — keep both. If upstream adopts a normalizing pass on `PDFResourceContentIterator` directly, the decorator + `PDFTextNormalizer` can be deleted and the host app's `DatabaseRebuilder+PDF` reuse re-pointed at upstream's symbol.

7. `EPUBSpreadView.swift` keeps its empty `extension EPUBSpreadView: WKUIDelegate {}` and `webView.uiDelegate = self`; `EPUBSpreadView+LinkContextMenu.swift` relies on both. If upstream implements the context-menu delegate method itself, delete the fork's file rather than merging two implementations.
8. Keep the `externalLinkActivated` registration in `EPUBSpreadView.swift` and the `./external-link-activation` import in `index.js`, then rebuild the bundles. If upstream starts cancelling outbound clicks itself, keep one path: two would report the link twice.

If upstream introduces a `VisibleAnchorObservingNavigator`-equivalent API, this fork's protocol can be deleted and the class conformance can switch to upstream's. The host app's `Coordinator` already speaks via `(@MainActor @Sendable (String, String) -> Void)?` closures so the wire shape is upstream-agnostic.
