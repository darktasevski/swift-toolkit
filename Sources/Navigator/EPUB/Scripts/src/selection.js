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

const SELECTION_MIRROR_NAME = "readium-selection-mirror";
const SELECTION_MIRROR_STYLE_ID = "readium-selection-mirror-style";
let selectionMirrorStylePending = false;

function canMirrorSelection() {
  return (
    typeof CSS !== "undefined" &&
    CSS.highlights !== undefined &&
    typeof window.Highlight !== "undefined"
  );
}

function installSelectionMirrorStyle() {
  if (!document.head || document.getElementById(SELECTION_MIRROR_STYLE_ID)) {
    return;
  }

  const style = document.createElement("style");
  style.id = SELECTION_MIRROR_STYLE_ID;
  // Suppressing the native paint is what makes the mirror a replacement rather
  // than a second layer. Both draw the same range with the same colour, and
  // --RS__selectionBackgroundColor is translucent on a themed reader, so
  // leaving both on composes the two alphas and the run darkens the moment the
  // mirror lands. The suppression lives in the style the mirror installs, and
  // only after a range is registered, so a runtime without the Custom
  // Highlight API keeps WebKit's own paint untouched.
  style.textContent = `
    ::selection {
      background-color: transparent !important;
    }

    ::highlight(${SELECTION_MIRROR_NAME}) {
      color: var(--RS__selectionTextColor, inherit);
      background-color: var(--RS__selectionBackgroundColor, #b4d8fe);
    }
  `;
  document.head.appendChild(style);
}

function ensureSelectionMirrorStyle() {
  if (document.head) {
    installSelectionMirrorStyle();
    return;
  }

  if (selectionMirrorStylePending) {
    return;
  }

  selectionMirrorStylePending = true;
  document.addEventListener(
    "DOMContentLoaded",
    () => {
      selectionMirrorStylePending = false;
      installSelectionMirrorStyle();
    },
    { once: true }
  );
}

function clearSelectionMirror() {
  if (canMirrorSelection()) {
    // WebKit bug 306396 was fixed in 306433@main, but the repaint fix was not
    // backported to safari-7624, the branch used by iOS 26.4.
    // Keep the registry entry and clear its ranges so affected runtimes repaint.
    // https://bugs.webkit.org/show_bug.cgi?id=306396
    CSS.highlights.get(SELECTION_MIRROR_NAME)?.clear();
  }
}

function updateSelectionMirror(range) {
  if (!canMirrorSelection()) {
    return;
  }

  const clonedRange = range.cloneRange();
  const mirror = CSS.highlights.get(SELECTION_MIRROR_NAME);
  if (mirror) {
    // Reuse the registered Highlight so changing an active selection repaints
    // both the old and new ranges on WebKit versions affected by bug 306396.
    mirror.clear();
    mirror.add(clonedRange);
  } else {
    CSS.highlights.set(
      SELECTION_MIRROR_NAME,
      new window.Highlight(clonedRange)
    );
  }
  // Only once a range is actually registered, because installing the style is
  // what turns the native paint off.
  ensureSelectionMirrorStyle();
}

function mirrorCurrentSelection() {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
    clearSelectionMirror();
    return;
  }

  const range = selection.getRangeAt(0);
  if (range.collapsed) {
    clearSelectionMirror();
    return;
  }

  updateSelectionMirror(range);
}

let selectionMirrorInstalled = false;

/**
 * Starts painting the selection. Called once, from the page-world entry point.
 *
 * Deliberately not a module side effect: this file is reachable from the
 * isolated command bundle too (through `rect` → `utils`), and a second world
 * registering a second highlight for the same range would stack a second
 * translucent band — the very thing the mirror suppresses the native paint to
 * avoid. Painting is a page-world concern, so the page world asks for it.
 *
 * The mirror tracks the selection on its own, undebounced, listener rather than
 * riding the debounced bridge that reports a selection to the host. That bridge
 * is a trailing debounce: during a drag `selectionchange` keeps firing and it
 * never settles, so the paint would not appear until the finger stopped. It can
 * afford to wait because it does the expensive part — text extraction and the
 * message to the host. Repainting a highlight range costs no DOM work, so it
 * runs on every event and the band stays under the finger.
 */
export function installSelectionMirror() {
  if (selectionMirrorInstalled) {
    return;
  }
  selectionMirrorInstalled = true;
  document.addEventListener("selectionchange", mirrorCurrentSelection);
}

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
