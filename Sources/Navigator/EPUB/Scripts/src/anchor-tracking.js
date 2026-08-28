//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// IntersectionObserver-based "what anchor is at the viewport top" reporter
// for reflowable EPUBs. The conformer (currently the Reader app) supplies
// the anchor-id list at navigator construction; this module owns observation
// and reports topmost-crossing events back to Swift via the
// `visibleAnchorChanged` message handler. Full design rationale lives in
// the conformer's docs (Readium 3.x Reader-app fork: see ADR-0106 in the
// host repository).

// Module-scoped state — held at module scope so teardown can clear it.
// Closure-captured handles leak across rapid initAnchorTracking calls.
// All `let` bindings declared up-front to avoid TDZ surprises when
// scheduleEmit etc. are invoked synchronously from observer install.
let observer = null;
let stylesheetPollInterval = null;
let emitDebounceListener = null;
let pagehideListener = null;
let lastReportedAnchorId = null;
let pendingAnchorId = null;
let trackedAnchorIds = [];

function teardownAnchorTracking() {
  if (stylesheetPollInterval) {
    clearInterval(stylesheetPollInterval);
    stylesheetPollInterval = null;
  }
  if (observer) {
    observer.disconnect();
    observer = null;
  }
  if (emitDebounceListener) {
    window.removeEventListener("scrollend", emitDebounceListener);
    emitDebounceListener = null;
  }
  if (pagehideListener) {
    window.removeEventListener("pagehide", pagehideListener);
    pagehideListener = null;
  }
  lastReportedAnchorId = null;
  pendingAnchorId = null;
  trackedAnchorIds = [];
}

function rootMarginForViewport() {
  // Track every anchor visible anywhere in the viewport (no shrink).
  //
  // Pre-fix this returned a 0px-thick band at the viewport's leading edge
  // ("0px 0px -100% 0px" / "0px -100% 0px 0px"). The intent was to fire
  // only when an anchor "crossed" the leading edge — fine for vertical
  // scroll where headings cross y=0, broken for paginated horizontal mode
  // where column-top headings have `rect.top ≈ 20px` (body padding) and
  // their bounding box never straddles y=0 regardless of which column is
  // visible. The observer would install, fire once on the initial pass,
  // then never fire again — header stuck on whatever the first emit
  // picked (often the wrong anchor due to layout quirks).
  //
  // Full-viewport tracking: `intersectingIds` contains every currently-
  // visible anchor; the picker in the IO callback selects the most
  // recently-passed one (largest document-order). Works for paginated
  // (horizontal page turns) and scroll (vertical) modes uniformly,
  // including vertical writing modes where document order still encodes
  // reading order regardless of visual flow.
  return "0px";
}

function notifyAnchor(anchorId) {
  // Defensive: postMessage against a removed handler throws TypeError.
  if (
    !window.webkit ||
    !window.webkit.messageHandlers ||
    !window.webkit.messageHandlers.visibleAnchorChanged
  ) {
    return;
  }
  if (anchorId === lastReportedAnchorId) return;
  lastReportedAnchorId = anchorId;
  webkit.messageHandlers.visibleAnchorChanged.postMessage({ anchorId });
}

function installObserver() {
  // Observed targets are resolved from trackedAnchorIds at install time.
  // Anchors not present in the DOM are silently skipped — newly-added
  // DOM nodes (footnote popovers, lazy chapter content) are not auto-
  // discovered by the observer; reflow re-binds existing observations
  // automatically per W3C IO § 3.4.
  const elements = trackedAnchorIds
    .map((id) => document.getElementById(id))
    .filter((el) => el !== null);
  if (elements.length === 0) return;

  // Pre-sort tracked anchor ids by document order so we can compute
  // "topmost-currently-intersecting" deterministically without calling
  // getBoundingClientRect inside the IO callback.
  const orderById = new Map();
  elements.forEach((el, i) => orderById.set(el.id, i));

  const intersectingIds = new Set();

  observer = new IntersectionObserver(
    (entries) => {
      // entry.boundingClientRect is engine-provided — does NOT force
      // synchronous layout. element.getBoundingClientRect() inside this
      // callback would; never call it here.
      for (const entry of entries) {
        const id = entry.target.id;
        if (entry.isIntersecting) {
          intersectingIds.add(id);
        } else {
          intersectingIds.delete(id);
        }
      }
      // "Current chapter" = the LARGEST document-order anchor currently
      // visible in the viewport. For forward reading (LTR or RTL — document
      // order matches reading order regardless of visual direction), this
      // is the most recently-passed heading. For iPad two-column spreads
      // where two headings may be simultaneously visible, the later one
      // wins — the user has progressed into it.
      //
      // Pre-fix this picked the SMALLEST doc-order, which under the
      // 0px-band geometry rarely mattered (the set was usually empty or
      // singleton). With the full-viewport tracking the set is non-trivial,
      // and "first visible chapter" is the wrong semantic — it gets stuck
      // on whichever earlier heading happens to be co-visible.
      let current = null;
      let currentOrder = -1;
      for (const id of intersectingIds) {
        const order = orderById.get(id);
        if (order !== undefined && order > currentOrder) {
          current = id;
          currentOrder = order;
        }
      }
      if (current !== null) {
        scheduleEmit(current);
      }
    },
    {
      root: null,
      rootMargin: rootMarginForViewport(),
      threshold: 0,
    }
  );

  for (const el of elements) {
    observer.observe(el);
  }
}

function scheduleEmit(anchorId) {
  // Coalesce frequent IO updates into one emit per scroll-stop. scrollend
  // is iOS 18+ unconditional; the fallback setTimeout(100) path called out
  // in earlier drafts is removed (untested-by-definition code).
  if (emitDebounceListener) {
    // Already armed — pending emit will pick up the latest anchor id
    // because we re-read `pendingAnchorId` at fire time.
    pendingAnchorId = anchorId;
    return;
  }
  pendingAnchorId = anchorId;
  emitDebounceListener = function () {
    const id = pendingAnchorId;
    pendingAnchorId = null;
    // { once: true } below auto-removes; no explicit removeEventListener
    // needed here.
    emitDebounceListener = null;
    if (id !== null) notifyAnchor(id);
  };
  window.addEventListener("scrollend", emitDebounceListener, { once: true });
  // Initial-pass emit (synchronous, post-stylesheets-applied) bypasses
  // the scrollend wait — see emitInitialAnchorIfApplicable.
}

// `document.fonts.ready` and `requestIdleCallback` are NOT substitutes:
//   - fonts.ready resolves on web-fonts only; orthogonal to external <link> CSS.
//   - requestIdleCallback is a scheduler, not a readiness signal.
// The link.sheet poll is the canonical primitive per ADR-0097 Amendment 2
// (host app's docs/ADR/0097-typographic-origin-correction.md).
function whenStylesheetsApplied(callback) {
  const links = Array.from(document.querySelectorAll('link[rel="stylesheet"]'));
  const allReady = () => links.every((l) => l.sheet !== null);
  if (allReady()) {
    callback();
    return;
  }
  let pollAttempts = 0;
  stylesheetPollInterval = setInterval(() => {
    pollAttempts++;
    // Cap at ~1.5s (≈90 attempts × 16ms). RAIL-model "feels instant"
    // threshold; a malformed CSS or attacker-slow <link> URL would
    // otherwise mask the bug being fixed (header lag) for the entire
    // poll window. Fail-open after the cap.
    if (allReady() || pollAttempts > 90) {
      clearInterval(stylesheetPollInterval);
      stylesheetPollInterval = null;
      callback();
    }
  }, 16);
}

function emitInitialAnchorIfApplicable() {
  // Synchronous initial selection on spread load: pick the LARGEST
  // doc-order anchor whose bounding box overlaps the viewport. Bypasses
  // the scrollend debounce because no scroll event fires on first paint —
  // and IO's first callback isn't reliably synchronous on observer.observe
  // for elements present at install time.
  //
  // Walk reverse doc-order so the FIRST visible match is the largest-
  // order one; break early to bound the worst-case `getBoundingClientRect`
  // reads (which force layout). For the common case of 20–80 anchors per
  // spine and ~1–2 visible at a time, this is ~2–80 layout reads, paid
  // once per spread load.
  //
  // Pre-fix this iterated forward and required `rect.top <= 0` (or the
  // vertical-rl equivalent on the right edge). Under paginated horizontal
  // mode that condition was almost never satisfied (anchors at column-top
  // sit at `rect.top ≈ 20px` due to body padding), so initial emit either
  // misfired on a layout-quirk anchor or didn't fire at all.
  const vpW = window.innerWidth;
  const vpH = window.innerHeight;
  let current = null;
  for (let i = trackedAnchorIds.length - 1; i >= 0; i--) {
    const id = trackedAnchorIds[i];
    const el = document.getElementById(id);
    if (!el) continue;
    const rect = el.getBoundingClientRect();
    // Any overlap with viewport rect [0, 0, vpW, vpH]. Off-screen anchors
    // (scrolled past horizontally on a previous spread, or not yet
    // reached) have rect.right ≤ 0 or rect.left ≥ vpW respectively.
    if (
      rect.right > 0 &&
      rect.left < vpW &&
      rect.bottom > 0 &&
      rect.top < vpH
    ) {
      current = id;
      break;
    }
  }
  if (current !== null) notifyAnchor(current);
}

function installPagehideListener() {
  // Defensive cleanup if document tears down without an explicit teardown
  // call. pagehide (NOT unload) is reliable on iOS and BFCache-friendly.
  pagehideListener = function () {
    teardownAnchorTracking();
  };
  window.addEventListener("pagehide", pagehideListener);
}

window.readium = window.readium || {};

window.readium.initAnchorTracking = function (anchorIds) {
  // ALWAYS first — clears prior state for the re-init case AND for the
  // empty/oversized cases (re-extraction may shrink the chapter list to
  // zero; without the unconditional teardown the previously-installed
  // observer would keep emitting against stale ids).
  teardownAnchorTracking();
  if (!Array.isArray(anchorIds) || anchorIds.length === 0) return;
  if (anchorIds.length > 256) {
    // Privacy-safe diagnostic: count only, no anchor content.
    console.warn("anchor tracking skipped: list size=" + anchorIds.length);
    return;
  }
  // Defensive charset filter — defence-in-depth against malicious /
  // malformed publisher input. Reference: W3C XML 1.0 § 2.3 (Name
  // production); EPUB 3 NCX restricts ids to XML 1.0 NameChar so any
  // character XML rejects is also forbidden in a well-formed publication.
  // The filter is intentionally over-conservative: it rejects some legal
  // NameChar code points (e.g., DEL+C1, U+2028/29) that XML doesn't
  // explicitly forbid, on the grounds that legitimate NCX ids in the
  // wild use a small subset of NameChar (alphanumerics, `-`, `_`, `.`).
  //
  // Rejects:
  //   - C0 controls         U+0000–U+001F (XML 1.0 forbids in Name).
  //   - DEL + C1 controls   U+007F–U+009F (XML 1.0 forbids in Name).
  //   - Lone surrogate halves U+D800–U+DFFF (UTF-16 code units that
  //     escape JSON serialisation in surprising ways downstream).
  //   - Unicode noncharacters U+FFFE, U+FFFF (XML 1.0 Name forbids).
  //   - Line separators     U+2028, U+2029 (escape JS string literals
  //     in pre-ES2019 contexts; not relevant to our callers but
  //     defence-in-depth is cheap).
  //
  // Implemented as a charCodeAt scan (NOT a regex literal): literal
  // control chars in regex source do not survive markdown round-trips.
  // Each iteration reads a UTF-16 code UNIT (not a code point); for
  // BMP characters (which NCX Name production constrains to anyway)
  // they're identical, so the surrogate-half check is sufficient even
  // for malformed inputs that try to ship astral characters.
  function hasForbiddenChar(s) {
    for (let i = 0; i < s.length; i++) {
      const cu = s.charCodeAt(i); // code unit, not code point
      if (cu <= 0x1f) return true; // C0 controls
      if (cu >= 0x7f && cu <= 0x9f) return true; // DEL + C1 controls
      if (cu >= 0xd800 && cu <= 0xdfff) return true; // lone surrogate halves
      if (cu === 0xfffe || cu === 0xffff) return true; // noncharacters
      if (cu === 0x2028 || cu === 0x2029) return true; // line separators
    }
    return false;
  }
  trackedAnchorIds = anchorIds.filter(
    (id) =>
      typeof id === "string" &&
      id.length > 0 &&
      id.length <= 4096 &&
      !hasForbiddenChar(id)
  );
  if (trackedAnchorIds.length < anchorIds.length) {
    // Privacy-safe diagnostic: count only, no anchor content.
    console.warn(
      "anchor tracking: " +
        (anchorIds.length - trackedAnchorIds.length) +
        " ids rejected by filter"
    );
  }
  if (trackedAnchorIds.length === 0) return;
  installPagehideListener();
  whenStylesheetsApplied(function () {
    installObserver();
    emitInitialAnchorIfApplicable();
  });
};
