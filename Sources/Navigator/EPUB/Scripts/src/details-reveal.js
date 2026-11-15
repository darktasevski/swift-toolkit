// Copyright 2026 Readium Foundation. All rights reserved.
// Use of this source code is governed by the BSD-style license
// available in the top-level LICENSE file of the project.

// Opens every closed `<details>` whose content holds `node`, as a browser
// does before it scrolls to a fragment there: a target inside a closed
// disclosure is not rendered, so it has no position to scroll to. A target
// in a disclosure's summary is shown already, and the disclosure stays as it
// was.
export function revealDetailsAround(node) {
  let child = node;
  let ancestor = node ? node.parentElement : null;
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
