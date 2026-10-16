//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// A link that leaves the publication must not start a navigation: WebKit connects to the target's
// host while it handles the link's click, before the navigation delegate can cancel the navigation,
// so the reader would reach the host before the app has asked. The click is cancelled and the URL
// handed to the navigator in an `externalLinkActivated` message instead.
//
// The listeners go on the window, in the capture phase, as this script runs at document start: no
// publication script has run yet, so none of its handlers sees the click first. A link inside a
// closed shadow root is hidden from them and falls back to the navigation delegate.

window.addEventListener("click", onLinkActivation, true);
window.addEventListener("auxclick", onLinkActivation, true);

function onLinkActivation(event) {
  // The buttons WebKit activates a link with (`isLinkClick`, `HTMLAnchorElement.cpp`).
  if (event.button !== 0 && event.button !== 1) {
    return;
  }
  const href = hrefLeavingPublication(event);
  if (href == null) {
    return;
  }
  event.preventDefault();
  webkit.messageHandlers.externalLinkActivated.postMessage({ href: href });
}

/**
 * The absolute URL of the link the event is in, when it points away from the server the document
 * came from. A `javascript:` link runs script rather than leaving, so it is not one.
 */
function hrefLeavingPublication(event) {
  // The composed path, not `event.target`: at the window, a link inside an open shadow root has
  // been retargeted to its host.
  const link = event
    .composedPath()
    .find((node) => node instanceof Element && node.matches("a, area"));
  if (link == null) {
    return null;
  }
  const raw =
    link.getAttribute("href") ??
    link.getAttributeNS("http://www.w3.org/1999/xlink", "href");
  if (raw == null) {
    return null;
  }
  let url;
  try {
    url = new URL(raw, document.baseURI);
  } catch {
    return null;
  }
  const origin = documentLocation();
  if (
    url.protocol === "javascript:" ||
    (url.protocol === origin.protocol && url.host === origin.host)
  ) {
    return null;
  }
  return url.href;
}

/**
 * Where the document came from: its `location`, not `document.baseURI`, which a `<base href>`
 * moves. An `about:srcdoc` or `about:blank` frame came from no server, so its embedder's.
 */
function documentLocation() {
  let view = window;
  while (view.location.protocol === "about:" && view.frameElement != null) {
    view = view.frameElement.ownerDocument.defaultView;
  }
  return view.location;
}
