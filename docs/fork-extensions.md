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

## Upstream-rebase guidance

When merging upstream `develop` into `fork-extensions`:

1. Conflicts in `EPUBNavigatorViewController.swift` are most likely — the file has multiple modification points. Resolve by preserving the `VisibleAnchorObservingNavigator` conformance and the new orchestrator method.
2. Conflicts in `EPUBReflowableSpreadView.swift` — preserve the `registerJSMessages` second registration and the `spreadDidLoad` cancellation checkpoints + anchor-tracking init block. Upstream may rework `spreadDidLoad` independently; the cancellation checkpoints are themselves a defensive improvement worth keeping even if the rest of the body changes.
3. Conflicts in `EPUBSpreadView.swift` — preserve the new protocol method + default-impl extension.
4. After merge, regenerate the JS bundle (`pnpm run bundle` from `Sources/Navigator/EPUB/Scripts/`) — all four `Assets/Static/scripts/*.js` files will need re-staging due to the chunk-id shift.
5. Run the fork-side test suite: `xcodebuild test -scheme Readium-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ReadiumNavigatorTests/EPUBReflowableSpreadViewVisibleAnchorTests` should pass 9/9.

If upstream introduces a `VisibleAnchorObservingNavigator`-equivalent API, this fork's protocol can be deleted and the class conformance can switch to upstream's. The host app's `Coordinator` already speaks via `(@MainActor @Sendable (String, String) -> Void)?` closures so the wire shape is upstream-agnostic.
