//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// The one viewport-progression geometry, shared by the page-world scroll hint
// and the isolated-world read and jump. It has no side effects and imports
// nothing, so either world can load it without installing the other's
// listeners.

// Which axis the document advances along, which way, and how far along it the
// viewport is, as an offset that grows from 0 in both directions. Content that
// progresses right to left (`direction: rtl` or `writing-mode: vertical-rl`)
// scrolls from 0 towards negative offsets, so its offset is negated.
function readScrollGeometry() {
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
  const offset = useY ? scrollY : isRTL ? -scrollX : scrollX;
  return { isScroll, useY, isRTL, offset };
}

/**
 * Measures the visible range of the current document as `{ first, last }`
 * progressions in 0...1, or `null` when the geometry cannot support one.
 *
 * Vertical scroll measures `scrollY` against `scrollHeight`. Paginated and
 * vertical-writing layouts measure the horizontal offset against
 * `scrollWidth`, negated for right-to-left content. A missing root, a
 * non-positive or non-finite dimension, or a non-finite offset yields `null`
 * rather than a fabricated position. The extent is positive, so the range is
 * ordered; every finite offset, including an overscroll past either end, is
 * clamped into 0...1.
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

  const { useY, offset } = readScrollGeometry();
  const size = useY ? root.scrollHeight : root.scrollWidth;
  const extent = useY ? innerHeight : innerWidth;
  if (!Number.isFinite(offset)) {
    return null;
  }
  const clamp = (value) => Math.min(Math.max(value, 0), 1);
  return {
    first: clamp(offset / size),
    last: clamp((offset + extent) / size),
  };
}

/**
 * Where a jump to `progression` (0...1) lands, in the geometry
 * `measureProgression` reads: `{ useY, isRTL, offset, target }`, where
 * `offset` is the viewport's current offset and `target` the one to scroll
 * to, both growing from 0 in either direction. `null` when the geometry
 * cannot support a jump.
 *
 * A paginated layout lands on the start of the page holding the
 * progression; the extra pixel keeps a progression that rounding left just
 * short of a page boundary on the page it names. The target is clamped to
 * the scrollport's range, so a progression on the last page lands on the
 * last full viewport.
 */
export function progressionScrollTarget(progression) {
  const root = document.scrollingElement;
  if (!root) {
    return null;
  }
  const { isScroll, useY, isRTL, offset } = readScrollGeometry();
  const size = useY ? root.scrollHeight : root.scrollWidth;
  const extent = useY ? root.clientHeight : root.clientWidth;
  if (
    !Number.isFinite(offset) ||
    !(Number.isFinite(size) && size > 0) ||
    !(Number.isFinite(extent) && extent > 0)
  ) {
    return null;
  }
  let target = progression * size;
  if (!isScroll) {
    target = Math.floor((target + 1) / extent) * extent;
  }
  target = Math.min(Math.max(target, 0), Math.max(size - extent, 0));
  return { useY, isRTL, offset, target };
}
