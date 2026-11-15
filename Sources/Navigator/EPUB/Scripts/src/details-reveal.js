// Copyright 2026 Readium Foundation. All rights reserved.
// Use of this source code is governed by the BSD-style license
// available in the top-level LICENSE file of the project.

const ELEMENT_NODE = 1;

// Opens every closed `<details>` whose content holds `node`, as a browser
// does before it scrolls to a fragment there: a target inside a closed
// disclosure is not rendered, so it has no position to scroll to. A target
// in a disclosure's summary is shown already, and the disclosure stays as it
// was. Given `offset`, the target is the boundary point (`node`, `offset`) a
// range starts at, which for a range around an element is that element's
// parent: the point lies between the element's children, so the element
// itself is the first disclosure that may hold it.
export function revealDetailsAround(node, offset) {
  let child = node;
  let ancestor = node ? node.parentElement : null;
  if (offset !== undefined && node && node.nodeType === ELEMENT_NODE) {
    child = node.childNodes[offset] ?? null;
    ancestor = node;
  }
  while (ancestor) {
    if (
      ancestor.localName === "details" &&
      !ancestor.open &&
      summaryOf(ancestor) !== child
    ) {
      ancestor.open = true;
    }
    child = ancestor;
    ancestor = ancestor.parentElement;
  }
}

// A disclosure's summary: its first `<summary>` child.
function summaryOf(details) {
  for (const element of details.children) {
    if (element.localName === "summary") {
      return element;
    }
  }
  return null;
}
