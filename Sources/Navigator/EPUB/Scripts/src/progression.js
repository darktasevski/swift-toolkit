//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// The one viewport-progression calculation, shared by the page-world scroll
// hint and the isolated-world read. It has no side effects and imports nothing,
// so either world can load it without installing the other's listeners.

/**
 * Measures the visible range of the current document as `{ first, last }`
 * progressions in 0...1, or `null` when the geometry cannot support one.
 *
 * Vertical scroll measures `scrollY` against `scrollHeight`. Paginated and
 * vertical-writing layouts measure the horizontal offset against
 * `scrollWidth`, by its absolute value when the inline direction runs right to
 * left. Missing roots and non-positive or non-finite dimensions or offsets
 * yield `null` rather than a fabricated position. The extent is positive, so
 * the range is ordered; a finite overscroll is clamped.
 */
export function measureProgression() {
  const root = document.scrollingElement;
  if (!root) {
    return null;
  }
  const dimensions = [
    innerWidth,
    innerHeight,
    root.scrollWidth,
    root.scrollHeight,
  ];
  if (!dimensions.every((value) => Number.isFinite(value) && value > 0)) {
    return null;
  }

  const style = getComputedStyle(document.documentElement);
  const writingMode = style.getPropertyValue("writing-mode");
  const isVertical = writingMode.startsWith("vertical");
  const isScroll =
    document.documentElement.style.getPropertyValue("--USER__view").trim() ===
    "readium-scroll-on";
  const useY = isScroll && !isVertical;
  const isRTL =
    style.getPropertyValue("direction") === "rtl" ||
    writingMode === "vertical-rl";

  const size = useY ? root.scrollHeight : root.scrollWidth;
  const extent = useY ? innerHeight : innerWidth;
  const offset = useY ? scrollY : isRTL ? Math.abs(scrollX) : scrollX;
  if (!Number.isFinite(offset)) {
    return null;
  }
  const clamp = (value) => Math.min(Math.max(value, 0), 1);
  return {
    first: clamp(offset / size),
    last: clamp((offset + extent) / size),
  };
}
