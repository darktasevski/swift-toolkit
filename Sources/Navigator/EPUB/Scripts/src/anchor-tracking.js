//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// IntersectionObserver-based "what NCX-mapped anchor is at the viewport
// top" reporter for reflowable EPUBs. See
// docs/superpowers/specs/2026-05-03-readium-visible-anchor-tracking-design.md
// (in the host app's repo) for the full design rationale.

// Module-scoped state — held at module scope so teardown can clear it.
// Closure-captured handles leak across rapid initAnchorTracking calls.
// All `let` bindings declared up-front to avoid TDZ surprises when
// scheduleEmit etc. are invoked synchronously from observer install.
let observer = null;
let stylesheetPollInterval = null;
let stylesheetPollAttempts = 0;
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

function isVerticalWritingMode() {
  const wm = getComputedStyle(document.documentElement).writingMode || "";
  return wm.startsWith("vertical");
}

function rootMarginForViewport() {
  // rootMargin is interpreted in physical (top/right/bottom/left) coords.
  // Horizontal writing-mode (default): collapse bottom → 0px sentinel band at top.
  // Vertical-rl: collapse right → 0px sentinel band at the leading (right) edge.
  // RTL alone (text reversed but horizontal writing mode) is irrelevant —
  // page top is still page top.
  return isVerticalWritingMode() ? "0px -100% 0px 0px" : "0px 0px -100% 0px";
}

function notifyAnchor(anchorId) {
  // Defensive: postMessage against a removed handler throws TypeError.
  if (!window.webkit ||
      !window.webkit.messageHandlers ||
      !window.webkit.messageHandlers.visibleAnchorChanged) {
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
      // Topmost intersecting anchor = lowest document-order index that
      // is currently in the sentinel band.
      let topmost = null;
      let topmostOrder = Infinity;
      for (const id of intersectingIds) {
        const order = orderById.get(id);
        if (order !== undefined && order < topmostOrder) {
          topmost = id;
          topmostOrder = order;
        }
      }
      if (topmost !== null) {
        scheduleEmit(topmost);
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
    window.removeEventListener("scrollend", emitDebounceListener);
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
  stylesheetPollAttempts = 0;
  stylesheetPollInterval = setInterval(() => {
    stylesheetPollAttempts++;
    // Cap at ~1.5s (≈90 attempts × 16ms). RAIL-model "feels instant"
    // threshold; a malformed CSS or attacker-slow <link> URL would
    // otherwise mask the bug being fixed (header lag) for the entire
    // poll window. Fail-open after the cap.
    if (allReady() || stylesheetPollAttempts > 90) {
      clearInterval(stylesheetPollInterval);
      stylesheetPollInterval = null;
      callback();
    }
  }, 16);
}

function emitInitialAnchorIfApplicable() {
  // Synchronous selection-rule pass: find the topmost tracked anchor whose
  // top edge is at or above the viewport top. Bypasses scrollend debounce
  // because this fires once on spread load — no rapid-update coalescing
  // needed.
  let topmost = null;
  let topmostOrder = Infinity;
  trackedAnchorIds.forEach((id, order) => {
    const el = document.getElementById(id);
    if (!el) return;
    const rect = el.getBoundingClientRect();
    // "At or above the top of the viewport" — horizontal writing mode
    // collapses to rect.top <= 0; vertical-rl collapses to
    // rect.right >= window.innerWidth. Mirror the rootMargin shape.
    const inBand = isVerticalWritingMode()
      ? rect.right >= window.innerWidth
      : rect.top <= 0;
    if (inBand && order < topmostOrder) {
      topmost = id;
      topmostOrder = order;
    }
  });
  if (topmost !== null) notifyAnchor(topmost);
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
  // malformed publisher input. Rejects:
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
      const cu = s.charCodeAt(i);                       // code unit, not code point
      if (cu <= 0x1F) return true;                       // C0 controls
      if (cu >= 0x7F && cu <= 0x9F) return true;         // DEL + C1 controls
      if (cu >= 0xD800 && cu <= 0xDFFF) return true;     // lone surrogate halves
      if (cu === 0xFFFE || cu === 0xFFFF) return true;   // noncharacters
      if (cu === 0x2028 || cu === 0x2029) return true;   // line separators
    }
    return false;
  }
  trackedAnchorIds = anchorIds.filter((id) =>
    typeof id === "string" &&
    id.length > 0 &&
    id.length <= 4096 &&
    !hasForbiddenChar(id)
  );
    if (trackedAnchorIds.length === 0) return;
  installPagehideListener();
  whenStylesheetsApplied(function () {
    installObserver();
    emitInitialAnchorIfApplicable();
  });
};
