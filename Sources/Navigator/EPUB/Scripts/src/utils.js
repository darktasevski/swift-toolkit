//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Catch JS errors to log them in the app.

import { TextQuoteAnchor } from "./vendor/hypothesis/anchoring/types";
import { getCurrentSelection } from "./selection";

window.addEventListener(
  "error",
  function (event) {
    webkit.messageHandlers.logError.postMessage({
      message: event.message,
      filename: event.filename,
      line: event.lineno,
    });
  },
  false
);

// Notify native code that the page has loaded.
window.addEventListener(
  "load",
  function () {
    var pendingResize;
    const observer = new ResizeObserver(() => {
      if (pendingResize) {
        window.cancelAnimationFrame(pendingResize);
      }

      pendingResize = window.requestAnimationFrame(function () {
        onViewportWidthChanged();
        onScroll();
      });
    });
    observer.observe(document.body);
  },
  false
);

function onViewportWidthChanged() {
  viewportWidth = window.innerWidth;
  appendVirtualColumnIfNeeded();
  snapCurrentPosition();
}

/**
 * Having an odd number of columns when displaying two columns per screen causes snapping and page
 * turning issues. To fix this, we insert a blank virtual column at the end of the resource.
 */
function appendVirtualColumnIfNeeded() {
  const id = "readium-virtual-page";
  var virtualCol = document.getElementById(id);
  if (isScrollModeEnabled() || getColumnCountPerScreen() != 2) {
    virtualCol?.remove();
  } else {
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var colCount = documentWidth / pageWidth;
    var hasOddColCount = (Math.round(colCount * 2) / 2) % 1 > 0.1;
    if (hasOddColCount) {
      if (virtualCol) {
        virtualCol.remove();
      } else {
        virtualCol = document.createElement("div");
        virtualCol.setAttribute("id", id);
        virtualCol.style.breakBefore = "column";
        virtualCol.innerHTML = "&#8203;"; // zero-width space
        document.body.appendChild(virtualCol);
      }
    }
  }
}

var lastKnownProgressions;
var ticking = false;
var viewportWidth = 0;

/**
 * First and last progressions in range [0 - 1].
 * Expects an object {first, last}
 */
function notifyProgressions(progressions) {
  webkit.messageHandlers.progressionChanged.postMessage(progressions);
}

window.addEventListener("scroll", onScroll);

function onScroll() {
  if (readium.isFixedLayout) {
    return;
  }

  let root = document.scrollingElement;
  if (isScrollModeEnabled() && !isVerticalWritingMode()) {
    const scrollY = window.scrollY;
    const viewportHeight = window.innerHeight;
    const totalContentHeight = root.scrollHeight;
    lastKnownProgressions = {
      first: scrollY / totalContentHeight,
      last: (scrollY + viewportHeight) / totalContentHeight,
    };
  } else {
    let scrollX = window.scrollX;
    const viewportWidth = window.innerWidth;
    const totalContentWidth = root.scrollWidth;

    if (isRTL()) {
      scrollX = Math.abs(scrollX);
    }
    lastKnownProgressions = {
      first: scrollX / totalContentWidth,
      last: (scrollX + viewportWidth) / totalContentWidth,
    };
  }

  // Window is hidden
  if (root.scrollWidth === 0 || root.scrollHeight === 0) {
    return;
  }

  if (!ticking) {
    window.requestAnimationFrame(function () {
      notifyProgressions(lastKnownProgressions);
      ticking = false;
    });
  }
  ticking = true;
}

document.addEventListener(
  "selectionchange",
  debounce(50, function () {
    webkit.messageHandlers.selectionChanged.postMessage(getCurrentSelection());
  })
);

export function getColumnCountPerScreen() {
  return parseInt(
    window
      .getComputedStyle(document.documentElement)
      .getPropertyValue("column-count")
  );
}

export function isScrollModeEnabled() {
  const style = document.documentElement.style;
  return style.getPropertyValue("--USER__view").trim() == "readium-scroll-on";
}

export function isVerticalWritingMode() {
  const writingMode = window
    .getComputedStyle(document.documentElement)
    .getPropertyValue("writing-mode");
  return writingMode.startsWith("vertical");
}

export function isRTL() {
  const style = window.getComputedStyle(document.documentElement);
  return (
    style.getPropertyValue("direction") == "rtl" ||
    style.getPropertyValue("writing-mode") == "vertical-rl"
  );
}

// Scroll to the given TagId in document and snap.
export function scrollToId(id, animated) {
  let element = document.getElementById(id);
  if (!element) {
    return false;
  }

  scrollToRect(element.getBoundingClientRect(), animated);
  return true;
}

// Position must be in the range [0 - 1], 0-100%.
export function scrollToPosition(position, dir, animated) {
  if (position < 0 || position > 1) {
    console.error(
      `Expected a valid progression in scrollToPosition, got ${position}`
    );
    return;
  }

  if (isScrollModeEnabled()) {
    if (!isVerticalWritingMode()) {
      let offset = document.scrollingElement.scrollHeight * position;
      scrollTo({ top: offset, animated });
    } else {
      let offset = document.scrollingElement.scrollWidth * position;
      scrollTo({ left: -offset, animated });
    }
  } else {
    var documentWidth = document.scrollingElement.scrollWidth;
    var factor = dir == "rtl" ? -1 : 1;
    let offset = documentWidth * position * factor;
    scrollTo({ left: snapOffset(offset), animated });
  }
}

// Scrolls to the first occurrence of the given text snippet.
//
// The expected text argument is a Locator object, as defined here:
// https://readium.org/architecture/models/locators/
export function scrollToLocator(locator, animated) {
  let range = rangeFromLocator(locator);
  if (!range) {
    return false;
  }
  return scrollToRange(range, animated);
}

function scrollToRange(range, animated) {
  return scrollToRect(range.getBoundingClientRect(), animated);
}

function scrollToRect(rect, animated) {
  if (isScrollModeEnabled()) {
    scrollTo({ top: rect.top + window.scrollY, animated });
  } else {
    scrollTo({ left: snapOffset(rect.left + window.scrollX), animated });
  }

  return true;
}

// Returns false if the page is already at the left-most scroll offset.
export function scrollLeft(dir, animated) {
  var isRTL = dir == "rtl";
  var documentWidth = document.scrollingElement.scrollWidth;
  var pageWidth = window.innerWidth;
  var offset = window.scrollX - pageWidth;
  var minOffset = isRTL ? -(documentWidth - pageWidth) : 0;
  return scrollToOffset(Math.max(offset, minOffset), animated);
}

// Returns false if the page is already scrolled at the right-most scroll
// offset.
export function scrollRight(dir, animated) {
  var isRTL = dir == "rtl";
  var documentWidth = document.scrollingElement.scrollWidth;
  var pageWidth = window.innerWidth;
  var offset = window.scrollX + pageWidth;
  var maxOffset = isRTL ? 0 : documentWidth - pageWidth;
  return scrollToOffset(Math.min(offset, maxOffset), animated);
}

// Scrolls to the given left offset.
// Returns false if the page scroll position is already close enough to the given offset.
function scrollToOffset(offset, animated) {
  var currentOffset = window.scrollX;
  var pageWidth = window.innerWidth;

  // In some case the scrollX cannot reach the position respecting to innerWidth
  var diff = Math.abs(currentOffset - offset) / pageWidth;
  var moved = diff > 0.01;

  if (moved) {
    scrollTo({ left: offset, animated });
  }

  return moved;
}

// Scrolls to the given position.
function scrollTo({ left, top, animated } = {}) {
  document.scrollingElement.scrollTo({
    left,
    top,
    behavior: animated ? "smooth" : "instant",
  });
}

// Snap the offset to the screen width (page width).
function snapOffset(offset) {
  const delta = isRTL() ? -1 : 1;
  const value = offset + delta;
  return value - (value % viewportWidth);
}

function snapCurrentPosition() {
  if (isScrollModeEnabled()) {
    return;
  }
  var currentOffset = window.scrollX;
  var currentOffsetSnapped = snapOffset(currentOffset + 1);

  document.scrollingElement.scrollLeft = currentOffsetSnapped;
}

export function rangeFromLocator(locator) {
  try {
    let locations = locator.locations;
    let text = locator.text;

    // Try domRange first - it's the most precise anchoring method
    if (locations && locations.domRange) {
      let range = rangeFromDomRange(locations.domRange);
      if (range && domRangeCoversQuote(range, locator)) {
        log("rangeFromLocator: Successfully anchored using domRange");
        return range;
      }
      log(
        "rangeFromLocator: domRange anchoring failed, falling back to text matching"
      );
    }

    // Fall back to text-based matching
    if (text && text.highlight) {
      var root;
      if (locations && locations.cssSelector) {
        root = document.querySelector(locations.cssSelector);
      }
      if (!root) {
        root = document.body;
      }

      let anchor = new TextQuoteAnchor(root, text.highlight, {
        prefix: text.before,
        suffix: text.after,
      });

      return anchor.toRange();
    }

    if (locations) {
      var element = null;

      if (!element && locations.cssSelector) {
        element = document.querySelector(locations.cssSelector);
      }

      if (!element && locations.fragments) {
        for (const htmlId of locations.fragments) {
          element = document.getElementById(htmlId);
          if (element) {
            break;
          }
        }
      }

      if (element) {
        let range = document.createRange();
        range.setStartBefore(element);
        range.setEndAfter(element);
        return range;
      }
    }
  } catch (e) {
    logError(e);
  }

  return null;
}

/**
 * Creates a DOM Range from a domRange object.
 * domRange format: { start: { cssSelector, textNodeIndex, charOffset }, end: { ... } }
 */
function rangeFromDomRange(domRange) {
  try {
    if (!domRange || !domRange.start) {
      return null;
    }

    const start = domRange.start;
    const end = domRange.end || start;

    // Validate CSS selectors before querying
    if (!start.cssSelector) {
      log("rangeFromDomRange: start.cssSelector is empty");
      return null;
    }

    // Find start container
    const startElement = document.querySelector(start.cssSelector);
    if (!startElement) {
      log(
        "rangeFromDomRange: Could not find start element: " + start.cssSelector
      );
      return null;
    }

    // Find the text node at the given index
    const startTextNode = getTextNodeAtIndex(startElement, start.textNodeIndex);
    if (!startTextNode) {
      log(
        "rangeFromDomRange: Could not find start text node at index " +
          start.textNodeIndex
      );
      return null;
    }

    // Validate end CSS selector
    if (!end.cssSelector) {
      log("rangeFromDomRange: end.cssSelector is empty");
      return null;
    }

    // Find end container
    const endElement = document.querySelector(end.cssSelector);
    if (!endElement) {
      log("rangeFromDomRange: Could not find end element: " + end.cssSelector);
      return null;
    }

    const endTextNode = getTextNodeAtIndex(endElement, end.textNodeIndex);
    if (!endTextNode) {
      log(
        "rangeFromDomRange: Could not find end text node at index " +
          end.textNodeIndex
      );
      return null;
    }

    // An out-of-range offset means the DOM is not the one the locator was recorded against
    // (a CDATA/text-node split, a DOM-mutating reading mode, a republished resource). Clamping
    // would silently anchor the nearest valid position and report success, so the caller would
    // paint or scroll to prose that is not the passage asked for. Refusing lets `rangeFromLocator`
    // fall through to text-quote matching, which either finds the real passage or misses honestly.
    const startOffset = start.charOffset ?? 0;
    const endOffset = end.charOffset ?? 0;
    if (
      startOffset < 0 ||
      endOffset < 0 ||
      startOffset > startTextNode.length ||
      endOffset > endTextNode.length
    ) {
      log(
        "rangeFromDomRange: charOffset out of range for the resolved text node"
      );
      return null;
    }

    // Create the range
    const range = document.createRange();

    range.setStart(startTextNode, startOffset);
    range.setEnd(endTextNode, endOffset);

    // Zero-length selections (collapsed ranges) don't represent a valid text selection
    if (range.collapsed) {
      log("rangeFromDomRange: Range is collapsed (zero-length selection)");
      return null;
    }

    return range;
  } catch (e) {
    log("rangeFromDomRange: Error creating range: " + e.message);
    logError(e);
    return null;
  }
}

/**
 * Whether a `domRange`-resolved range actually covers the passage the locator names.
 *
 * A structurally valid Range is not evidence that it is the RIGHT range: a locator recorded against
 * a different DOM shape can resolve to a real node at an in-bounds offset and still cover unrelated
 * prose. Without this check the caller paints or scrolls to that prose and reports success. A
 * locator carrying no quote (a plain position, or a selection-derived range) has nothing to verify
 * against and is accepted as before.
 *
 * Only the covered text is compared, never the stored `before`/`after` context: that context is
 * produced with the indexer's own width, which need not equal any width reconstructed here, so
 * requiring it to match would reject correct landings and silently cost precision-anchoring yield.
 * The covered text is what gets painted, so it is the whole question.
 *
 * `TextQuoteAnchor.fromRange(root, range).exact` is deliberately NOT used for the comparison, even
 * though it is the obvious candidate. It reconstructs the text as plain `textContent`, which
 * includes `script` / `style` / `noscript` / `template` content that the indexer's projection
 * excludes — so a correct landing on any chunk spanning one of those would compare unequal and be
 * rejected. It also resolves the range relative to a root before computing `exact`, which can throw
 * for a value that does not depend on the root at all.
 */
function domRangeCoversQuote(range, locator) {
  const highlight = locator.text && locator.text.highlight;
  if (!highlight) {
    return true;
  }
  try {
    return projectedTextFromRange(range) === highlight;
  } catch (e) {
    log("rangeFromLocator: could not read the resolved range's text");
    return false;
  }
}

/** Elements whose text the indexer's projection excludes, and which must therefore be dropped
 * before comparing a resolved range against a stored quote. Mirrors the Rust projection's
 * exclusion set; `head` is omitted because it cannot occur inside a `<body>`-scoped range. */
const PROJECTION_EXCLUDED_SELECTOR = "script, style, noscript, template";

/**
 * The range's text as the indexer's projection would have recorded it: excluded subtrees dropped,
 * each `<br>` contributing one space.
 */
function projectedTextFromRange(range) {
  const container = document.createElement("div");
  container.appendChild(range.cloneContents());
  for (const excluded of Array.from(
    container.querySelectorAll(PROJECTION_EXCLUDED_SELECTOR)
  )) {
    excluded.remove();
  }
  for (const lineBreak of Array.from(container.querySelectorAll("br"))) {
    lineBreak.replaceWith(document.createTextNode(" "));
  }
  return container.textContent ?? "";
}

/**
 * Whether a child node occupies a `textNodeIndex` slot.
 *
 * Both `Text` and `CDATASection` are `CharacterData`: they render as prose and accept
 * `Range.setStart`. XML parsing (`application/xhtml+xml`, the dominant EPUB served type)
 * materializes every `<![CDATA[…]]>` as a `CDATASection` — empty sections included — which also
 * splits the surrounding character data into separate `Text` siblings. Counting only `Text` would
 * therefore address a different node than the indexer recorded. The HTML parser reduces the same
 * bytes to a comment, which neither side counts, so both parse paths agree on this predicate.
 */
export function isAddressableTextNode(node) {
  return (
    node.nodeType === Node.TEXT_NODE ||
    node.nodeType === Node.CDATA_SECTION_NODE
  );
}

/**
 * Gets the text node at the given index within an element.
 */
function getTextNodeAtIndex(element, index) {
  let textNodeIndex = 0;
  for (const child of element.childNodes) {
    if (isAddressableTextNode(child)) {
      if (textNodeIndex === index) {
        return child;
      }
      textNodeIndex++;
    }
  }
  return null;
}

/// User Settings.

export function setCSSProperties(properties) {
  for (const name in properties) {
    setProperty(name, properties[name]);
  }
}

// For setting user setting.
export function setProperty(key, value) {
  if (value === null) {
    removeProperty(key);
  } else {
    var root = document.documentElement;
    // The `!important` annotation is added with `setProperty()` because if
    // it's part of the `value`, it will be ignored by the Web View.
    root.style.setProperty(key, value, "important");
  }
}

// For removing user setting.
export function removeProperty(key) {
  var root = document.documentElement;

  root.style.removeProperty(key);
}

/// Toolkit

function debounce(delay, func) {
  var timeout;
  return function () {
    var self = this;
    var args = arguments;
    function callback() {
      func.apply(self, args);
      timeout = null;
    }
    clearTimeout(timeout);
    timeout = setTimeout(callback, delay);
  };
}

export function log() {
  var message = Array.prototype.slice.call(arguments).join(" ");
  webkit.messageHandlers.log.postMessage(message);
}

export function logErrorMessage(msg) {
  logError(new Error(msg));
}

export function logError(e) {
  webkit.messageHandlers.logError.postMessage({
    message: e.message,
  });
}
