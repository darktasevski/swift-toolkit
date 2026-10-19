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

A long-press on a link that leaves the publication showed WebKit's link menu, whose preview fetched the destination and whose "Open Link" went to Safari without consulting the navigation policy, so a host app that confirms outbound links (Reader app #3016) was bypassed. Returning `nil` from the UI delegate does not suppress it for an `http(s)` link: WebKit falls back to DataDetectors' URL menu. The spread view returns its own configuration instead: no preview, and one item that takes the tap path (`spreadView(_:didTapOnExternalURL:)`). Links inside the publication and `javascript:` links get `nil`. An image keeps WebKit's menu unless it is inside an outbound link, where it gets this one, without Save, Copy or Share. Design record: [ADR-0186 in the host repository](../../docs/ADR/0186-converted-container-link-disposition.md).

For an upstream PR, three things would surprise: the item reads "Open Link…" with a `safari` image although upstream's default hand-off opens at once (and `mailto:` opens Mail); WebKit's Copy Link and Share are gone; and for a publication served over `http(s)` every internal link is `http(s)`, so returning `nil` for it still gets DataDetectors' menu — unreachable for a publication served from the custom scheme, as the host app's are.

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/EPUBSpreadView+LinkContextMenu.swift` | `EPUBSpreadView` answers `WKUIDelegate`'s `webView(_:contextMenuConfigurationForElement:completionHandler:)` through `linkContextMenuConfiguration(forLinkURL:)`. A link the publication base (`relativize`) does not hold, and that is not `javascript:`, gets the menu; its item calls `openOutboundLink(_:)`. The title is `ReadiumNavigator.LinkContextMenu.openLink`, which a host overrides from its main bundle. | Yes — upstream has the same bypass. |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/Resources/en.lproj/Localizable.strings` | Adds `ReadiumNavigator.LinkContextMenu.openLink` = "Open Link…". | Yes. |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewLinkContextMenuTests.swift` | 12 tests: internal, outbound, `mailto:`, `javascript:` and no-link classification; the one-item menu, its default title, and its item taking the tap path; the spread view answering WebKit's selector; and the hook's configuration for an outbound, an internal and no link. That the menu replaces WebKit's on a device, with no preview request, is measured in the host app. |

## Outbound link clicks open no connection

A click on a link in a reflowable EPUB started a main-frame navigation, and WebKit connected to the target's host while it handled the click, before `webView(_:decidePolicyFor:decisionHandler:)` could cancel the navigation: the reader reached the host before a host app that confirms outbound links (Reader app #3016) had asked. Measured with a loopback listener: an accept at the tap, no bytes, the real request only on Open. A fixed-layout EPUB (its page is an iframe) and the PDF navigator did not connect.

`external-link-activation.js` now cancels the click of a link whose scheme or host differs from the document's, after posting its URL. It runs in its own content world, so a publication script can neither redefine what it calls nor post its message, and its listeners go on the window in the capture phase as it runs at document start, before any publication script. Two consequences follow, accepted: a publication script that handles an outbound link itself (cancels the click and shows something) now also raises the host's confirmation, and its handlers find the click already cancelled, so one that ignores cancelled clicks never runs for an outbound link. If the message cannot be posted the click is left to WebKit, so the navigation policy still asks. The policy also stays the path for what the script cannot see — a link inside a closed shadow root, a link an SVG `<use>` instances, a frame that may not run script — and for scripted navigation; those connect before the policy asks. The Swift side has the last word on "internal": a posted URL the publication base holds opens inside the book. Design record: [ADR-0186 in the host repository](../../docs/ADR/0186-converted-container-link-disposition.md).

### New files

| Path | Purpose | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/Scripts/src/external-link-activation.js` | Built into its own bundle, `readium-external-link-activation.js`. Cancels a click or `auxclick` — any button but the right one, as WebKit activates links with — on a link leaving the publication, after posting `externalLinkActivated` with its URL. A link is what WebKit treats as one: an HTML `a`/`area` with an `href`, an SVG `a` with `href` or `xlink:href`, a MathML element with `href`; the search walks `composedPath()` outward past an `a` with no `href`, so a link in an open shadow root counts. Leaves alone a `javascript:` link and one on the document's own scheme and host; "own" is the document's `location`, never a `<base href>`, and for an `about:srcdoc` or `about:blank` frame its embedder's. | Yes. |
| `Sources/Navigator/EPUB/EPUBExternalLinkActivationBridge.swift` | Installs the bundle as a document-start user script in the `ReadiumExternalLinkActivation` content world and registers `externalLinkActivated` in that world only. | Yes. |
| `Sources/Navigator/EPUB/EPUBSpreadView+ExternalLinkActivation.swift` | Handles the message: a URL the publication base holds goes to `spreadView(_:didTapOnInternalLink:clickEvent:)`, any other to `spreadView(_:didTapOnExternalURL:)`; a body without a usable `href` is reported as `malformedLinkActivationBody` to `EPUBPageWorldLog`. | No — it reports to the fork-only `EPUBPageWorldLog`; upstream would need its own logging in its place. |

### Modified upstream files

| Path | Change | Upstream-PR-ready? |
| --- | --- | --- |
| `Sources/Navigator/EPUB/EPUBSpreadView.swift` | Holds the bridge and installs it with the configuration; wires its activations to `didActivateExternalLink(_:)`; enables and disables its handler beside the locator bridge's. | Yes. |
| `Sources/Navigator/EPUB/Scripts/webpack.config.js` | One entry, `external-link-activation`. `index.js`, `gestures.js` and the reflowable and fixed bundles are unchanged. | Yes. |

### Modified fork files

| Path | Change |
| --- | --- |
| `Sources/Navigator/EPUB/EPUBPageWorldLog.swift` | Adds the `malformedLinkActivationBody` reason, at `.warning`. The file is fork-only (absent from `3.11.0`). |

### Tests

| Path | Coverage |
| --- | --- |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewExternalLinkClickTests.swift` | 4 hosted tests in a loaded web view. Reflowable and fixed layout's iframe: which clicks are already cancelled when they reach the link and are handed over exactly once (`https`, an element inside a link, an `a` without `href` inside an outbound link, `mailto:`, SVG `href` and `xlink:href`, MathML `href`, an image-map `area`, an open shadow root, a `srcdoc` frame, middle- and fourth-button `auxclick`s, a link the publication's own capture listener stops, a `<base href>` on the link's host, a page that replaced `URL` and `composedPath`), and which are left to WebKit and opened inside the book by its policy (another resource, a fragment, a MathML `href` in the book, another resource from a `srcdoc` frame) or do nothing (`javascript:`, no `href`, an HTML `a` with only `xlink:href`, a right-button `auxclick`). A page-world script cannot see the handler; a click the script cannot post is left to the policy. That no connection opens on a device is measured in the host app. |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewExternalLinkActivationTests.swift` | 7 tests: a body's `href` becomes the URL, including a `|` the web parser leaves unescaped and punycode and IPv6 hosts; a body without a usable `href` yields none; an activation reaches the delegate, one inside the publication opens inside it; a malformed one is reported and hands over nothing. |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewHosting.swift` | Test support: builds (with a frame), hosts and waits for real spread views. The load waits and their #1693 earned-skip rule moved here from `EPUBSpreadViewCommandOutcomeTests`, which now calls them; `waitUntil` reports at its caller. |
| `Tests/NavigatorTests/EPUB/CapturingLogger.swift` | Test support: the capturing logger, moved out of `EPUBPageWorldLogTests.swift`. |
| `Tests/NavigatorTests/EPUB/EPUBPageWorldLogTests.swift` | The new reason joins the level table and the warning-floor count. The log-interpolation scan covers every `*SpreadView*.swift` source, listed from the directory, so both `EPUBSpreadView+*.swift` extensions are in it. |
| `Tests/NavigatorTests/EPUB/EPUBSpreadViewCommandOutcomeTests.swift` | Calls the shared helpers instead of its private copies. |

## Upstream-rebase guidance

The fork follows upstream release tags, not `develop` (owner, 2026-10-18): it takes 3.x releases and hotfixes as they ship, and adopting Readium 4.0 is its own piece of work at 4.0.0. When merging an upstream release tag into `fork-extensions`:

1. Conflicts in `EPUBNavigatorViewController.swift` are most likely — the file has multiple modification points. Resolve by preserving the `VisibleAnchorObservingNavigator` conformance and the new orchestrator method.
2. Conflicts in `EPUBReflowableSpreadView.swift` — preserve the `registerJSMessages` second registration and the `spreadDidLoad` cancellation checkpoints + anchor-tracking init block. Upstream may rework `spreadDidLoad` independently; the cancellation checkpoints are themselves a defensive improvement worth keeping even if the rest of the body changes.
3. Conflicts in `EPUBSpreadView.swift` — preserve the new protocol method + default-impl extension.
4. After merge, regenerate the JS bundle (`pnpm run bundle` from `Sources/Navigator/EPUB/Scripts/`) — all four `Assets/Static/scripts/*.js` files will need re-staging due to the chunk-id shift.
5. Run the fork-side test suite: `xcodebuild test -scheme Readium-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ReadiumNavigatorTests/EPUBReflowableSpreadViewVisibleAnchorTests` should pass 9/9.
6. In `PDFParser.swift`, preserve the `NormalizingPDFContentIterator.Factory(wrapping:)` wrapper around the content-iterator factory; the two `Sources/Streamer/Parser/PDF/` files (`PDFTextNormalizer.swift`, `NormalizingPDFContentIterator.swift`) are fork-only — keep both. If upstream adopts a normalizing pass on `PDFResourceContentIterator` directly, the decorator + `PDFTextNormalizer` can be deleted and the host app's `DatabaseRebuilder+PDF` reuse re-pointed at upstream's symbol.

7. `EPUBSpreadView.swift` keeps its empty `extension EPUBSpreadView: WKUIDelegate {}` and `webView.uiDelegate = self`; `EPUBSpreadView+LinkContextMenu.swift` relies on both. If upstream implements the context-menu delegate method itself, delete the fork's file rather than merging two implementations.
8. Keep the bridge wiring in `EPUBSpreadView.swift` (the stored bridge, its install, and its enable and disable beside the locator bridge's) and the `external-link-activation` webpack entry, then rebuild the bundles. If upstream starts cancelling outbound clicks itself, keep one path: two would report the link twice.

If upstream introduces a `VisibleAnchorObservingNavigator`-equivalent API, this fork's protocol can be deleted and the class conformance can switch to upstream's. The host app's `Coordinator` already speaks via `(@MainActor @Sendable (String, String) -> Void)?` closures so the wire shape is upstream-agnostic.
