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
// The script runs in its own content world (`EPUBExternalLinkActivationBridge`), so a publication
// script can neither redefine what it calls here nor post its message. Its listeners go on the
// window, in the capture phase, as it runs at document start: no publication script has run yet,
// so none of its handlers sees the click first, and one that handles an outbound link itself finds
// the click already cancelled. A link inside a closed shadow root, an SVG `<use>` instance or a
// frame that may not run script is hidden from them and falls back to the navigation delegate.

const SVG_NS = "http://www.w3.org/2000/svg";
const XLINK_NS = "http://www.w3.org/1999/xlink";
const MATHML_NS = "http://www.w3.org/1998/Math/MathML";

window.addEventListener("click", onLinkActivation, true);
window.addEventListener("auxclick", onLinkActivation, true);

function onLinkActivation(event) {
  // WebKit activates a link on any click but a right-button one.
  if (event instanceof MouseEvent && event.button === 2) {
    return;
  }
  const href = hrefLeavingPublication(event);
  if (href == null) {
    return;
  }
  // Posted before the click is cancelled: if the message cannot be posted, the click keeps its
  // default handling and the navigation delegate still asks, rather than doing nothing.
  try {
    webkit.messageHandlers.externalLinkActivated.postMessage({ href: href });
  } catch {
    return;
  }
  event.preventDefault();
}

/**
 * The absolute URL of the link the event is in, when it points away from the server the document
 * came from. A `javascript:` link runs script rather than leaving, so it is not one.
 */
function hrefLeavingPublication(event) {
  // The composed path, not `event.target`: at the window, a link inside an open shadow root has
  // been retargeted to its host.
  let raw = null;
  for (const node of event.composedPath()) {
    raw = linkHref(node);
    if (raw != null) {
      break;
    }
  }
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
 * The URL `node` links to, when WebKit treats it as a link: an HTML `a` or `area` with an `href`,
 * an SVG `a` with an `href` or `xlink:href`, or a MathML element with an `href`. An `a` without
 * one is not a link, so the search goes on to an enclosing one, as WebKit's does.
 */
function linkHref(node) {
  if (!(node instanceof Element)) {
    return null;
  }
  switch (node.namespaceURI) {
    case SVG_NS:
      return node.localName === "a"
        ? node.getAttribute("href") ?? node.getAttributeNS(XLINK_NS, "href")
        : null;
    case MATHML_NS:
      return node.getAttribute("href");
    default:
      return node.localName === "a" || node.localName === "area"
        ? node.getAttribute("href")
        : null;
  }
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
