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
 * `scrollWidth`. Content that progresses right to left (`direction: rtl` or
 * `writing-mode: vertical-rl`) scrolls from 0 towards negative offsets, so the
 * offset is negated. A missing root, a non-positive or non-finite dimension,
 * or a non-finite offset yields `null` rather than a fabricated position. The
 * extent is positive, so the range is ordered; every finite offset, including
 * an overscroll past either end, is clamped into 0...1.
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
  const offset = useY ? scrollY : isRTL ? -scrollX : scrollX;
  if (!Number.isFinite(offset)) {
    return null;
  }
  const clamp = (value) => Math.min(Math.max(value, 0), 1);
  return {
    first: clamp(offset / size),
    last: clamp((offset + extent) / size),
  };
}
