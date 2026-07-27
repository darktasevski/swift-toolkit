//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { isAddressableTextNode, logError } from "./utils";
import { toNativeRect } from "./rect";
import { TextRange } from "./vendor/hypothesis/anchoring/text-range";

// Polyfill for iOS 12
import matchAll from "string.prototype.matchall";
matchAll.shim();

export function getCurrentSelection() {
  if (!readium.link) {
    return null;
  }
  const href = readium.link.href;
  if (!href) {
    return null;
  }

  const selectionData = getCurrentSelectionText();
  if (!selectionData) {
    return null;
  }

  const rect = getSelectionRect();

  // Compute domRange for highlight anchoring
  const domRange = computeDomRange(selectionData.range);

  // Extract text properties (without the range)
  const text = {
    highlight: selectionData.highlight,
    before: selectionData.before,
    after: selectionData.after,
  };

  return { href, text, rect, domRange };
}

function getSelectionRect() {
  try {
    let sel = window.getSelection();
    if (!sel) {
      return;
    }
    let range = sel.getRangeAt(0);

    return toNativeRect(range.getBoundingClientRect());
  } catch (e) {
    logError(e);
    return null;
  }
}

function getCurrentSelectionText() {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed) {
    return undefined;
  }

  const highlight = selection.toString();
  const cleanHighlight = highlight
    .trim()
    .replace(/\n/g, " ")
    .replace(/\s\s+/g, " ");

  if (cleanHighlight.length === 0) {
    return undefined;
  }

  if (!selection.anchorNode || !selection.focusNode) {
    return undefined;
  }

  const range =
    selection.rangeCount === 1
      ? selection.getRangeAt(0)
      : createOrderedRange(
          selection.anchorNode,
          selection.anchorOffset,
          selection.focusNode,
          selection.focusOffset
        );

  if (!range || range.collapsed) {
    return undefined;
  }

  const text = document.body.textContent;

  let textRange;
  try {
    textRange = TextRange.fromRange(range).relativeTo(document.body);
  } catch (e) {
    logError(e);
    return undefined;
  }

  const start = textRange.start.offset;
  const end = textRange.end.offset;

  const snippetLength = 200;

  // Compute the text before the highlight, ignoring the first "word", which might be cut.
  let before = text.slice(Math.max(0, start - snippetLength), start);
  let firstWordStart = before.search(/\P{L}\p{L}/gu);
  if (firstWordStart !== -1) {
    before = before.slice(firstWordStart + 1);
  }

  // Compute the text after the highlight, ignoring the last "word", which might be cut.
  let after = text.slice(end, Math.min(text.length, end + snippetLength));
  let lastWordEnd = Array.from(after.matchAll(/\p{L}\P{L}/gu)).pop();
  if (lastWordEnd !== undefined && lastWordEnd.index > 1) {
    after = after.slice(0, lastWordEnd.index + 1);
  }

  // Return the range as well so we can compute domRange
  return { highlight, before, after, range };
}

function createOrderedRange(startNode, startOffset, endNode, endOffset) {
  const range = new Range();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, endOffset);
  if (!range.collapsed) {
    return range;
  }
  // Try reversed range (selection direction may be backwards)
  const rangeReverse = new Range();
  rangeReverse.setStart(endNode, endOffset);
  rangeReverse.setEnd(startNode, startOffset);
  if (!rangeReverse.collapsed) {
    return rangeReverse;
  }
  return undefined;
}

/**
 * Computes a unique CSS selector for an element.
 * Uses ID if available, otherwise builds a path with nth-child selectors.
 */
function getCssSelector(element) {
  if (!element || element.nodeType !== Node.ELEMENT_NODE) {
    return null;
  }

  // If element has an ID, use it (most reliable)
  if (element.id) {
    return "#" + CSS.escape(element.id);
  }

  // Build path from root
  const path = [];
  let current = element;

  while (
    current &&
    current !== document.body &&
    current !== document.documentElement
  ) {
    if (current.nodeType !== Node.ELEMENT_NODE) {
      current = current.parentElement;
      continue;
    }

    let selector = current.tagName.toLowerCase();

    // If element has an ID, use it and stop
    if (current.id) {
      selector = "#" + CSS.escape(current.id);
      path.unshift(selector);
      break;
    }

    // Add nth-child for uniqueness among siblings
    const parent = current.parentElement;
    if (parent) {
      const siblings = Array.from(parent.children).filter(
        (child) => child.tagName === current.tagName
      );
      if (siblings.length > 1) {
        const index = siblings.indexOf(current) + 1;
        selector += ":nth-of-type(" + index + ")";
      }
    }

    path.unshift(selector);
    current = current.parentElement;
  }

  // Prepend body to make the selector absolute
  if (path.length > 0 && !path[0].startsWith("#")) {
    path.unshift("body");
  }

  return path.join(" > ");
}

/**
 * Finds the text node index within the parent element.
 * Returns the index of the text node among all child text nodes of the parent.
 */
function getTextNodeIndex(node) {
  if (!node) return -1;

  // If the node cannot hold a `textNodeIndex` slot, return -1
  if (!isAddressableTextNode(node)) {
    return -1;
  }

  const parent = node.parentElement;
  if (!parent) return -1;

  let textNodeIndex = 0;
  for (const child of parent.childNodes) {
    if (child === node) {
      return textNodeIndex;
    }
    if (isAddressableTextNode(child)) {
      textNodeIndex++;
    }
  }

  return -1;
}

/**
 * Computes a DOMRange object from a Range for serialization.
 * This follows the Readium DOMRange format for highlight anchoring.
 */
function computeDomRange(range) {
  if (!range) return null;

  try {
    const startContainer = range.startContainer;
    const endContainer = range.endContainer;
    const startOffset = range.startOffset;
    const endOffset = range.endOffset;

    // Get the parent element for the start
    const startElement = isAddressableTextNode(startContainer)
      ? startContainer.parentElement
      : startContainer;

    // Get the parent element for the end
    const endElement = isAddressableTextNode(endContainer)
      ? endContainer.parentElement
      : endContainer;

    if (!startElement || !endElement) {
      return null;
    }

    const startCssSelector = getCssSelector(startElement);
    const endCssSelector = getCssSelector(endElement);

    // Validate CSS selectors - must be non-null and non-empty.
    // Empty selectors can occur with malformed HTML, elements removed from DOM during selection,
    // or edge cases where getCssSelector cannot build a valid path (e.g., detached nodes).
    if (
      !startCssSelector ||
      !endCssSelector ||
      startCssSelector === "" ||
      endCssSelector === ""
    ) {
      return null;
    }

    // Get text node indices
    const startTextNodeIndex = isAddressableTextNode(startContainer)
      ? getTextNodeIndex(startContainer)
      : 0;

    const endTextNodeIndex = isAddressableTextNode(endContainer)
      ? getTextNodeIndex(endContainer)
      : 0;

    // Validate text node indices - getTextNodeIndex returns -1 on failure
    if (startTextNodeIndex < 0 || endTextNodeIndex < 0) {
      return null;
    }

    return {
      start: {
        cssSelector: startCssSelector,
        textNodeIndex: startTextNodeIndex,
        charOffset: startOffset,
      },
      end: {
        cssSelector: endCssSelector,
        textNodeIndex: endTextNodeIndex,
        charOffset: endOffset,
      },
    };
  } catch (e) {
    logError(e);
    return null;
  }
}

export function convertRangeInfo(document, rangeInfo) {
  const startElement = document.querySelector(
    rangeInfo.startContainerElementCssSelector
  );
  if (!startElement) {
    return undefined;
  }
  let startContainer = startElement;
  if (rangeInfo.startContainerChildTextNodeIndex >= 0) {
    if (
      rangeInfo.startContainerChildTextNodeIndex >=
      startElement.childNodes.length
    ) {
      return undefined;
    }
    startContainer =
      startElement.childNodes[rangeInfo.startContainerChildTextNodeIndex];
    if (!isAddressableTextNode(startContainer)) {
      return undefined;
    }
  }
  const endElement = document.querySelector(
    rangeInfo.endContainerElementCssSelector
  );
  if (!endElement) {
    return undefined;
  }
  let endContainer = endElement;
  if (rangeInfo.endContainerChildTextNodeIndex >= 0) {
    if (
      rangeInfo.endContainerChildTextNodeIndex >= endElement.childNodes.length
    ) {
      return undefined;
    }
    endContainer =
      endElement.childNodes[rangeInfo.endContainerChildTextNodeIndex];
    if (!isAddressableTextNode(endContainer)) {
      return undefined;
    }
  }
  return createOrderedRange(
    startContainer,
    rangeInfo.startOffset,
    endContainer,
    rangeInfo.endOffset
  );
}

export function location2RangeInfo(location) {
  const locations = location.locations;
  const domRange = locations.domRange;
  const start = domRange.start;
  const end = domRange.end;

  // Support both `charOffset` (current spec) and `offset` (legacy) property names
  // for backward compatibility with persisted Locator models from older versions.
  return {
    endContainerChildTextNodeIndex: end.textNodeIndex,
    endContainerElementCssSelector: end.cssSelector,
    endOffset: end.charOffset ?? end.offset,
    startContainerChildTextNodeIndex: start.textNodeIndex,
    startContainerElementCssSelector: start.cssSelector,
    startOffset: start.charOffset ?? start.offset,
  };
}
