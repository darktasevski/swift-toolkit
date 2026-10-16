//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Kept apart from utils.js, whose module body installs page-world listeners:
// rect.js reaches the isolated locator command bundle, and importing utils.js
// from there would install those listeners in the isolated world too.

export function log() {
  var message = Array.prototype.slice.call(arguments).join(" ");
  webkit.messageHandlers.log.postMessage(message);
}
