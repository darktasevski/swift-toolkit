//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Defence-in-depth caps for anchor-tracking, applied at every layer of
/// the JS↔Swift bridge so a malicious EPUB cannot wedge the WebKit IPC
/// marshaller or the JS-side observer with a 1M-anchor list / 1MB-string
/// payload. Hoisted to a single chokepoint per the post-review P1
/// finding so the four call sites stay in lockstep when the cap is
/// tuned.
///
/// JS-side equivalents in `Sources/Navigator/EPUB/Scripts/src/anchor-tracking.js`
/// keep their own literals — cross-language constant sharing isn't worth
/// a generated header here. Update both sides if you change the values.
enum AnchorTrackingLimits {
    /// Max number of NCX-anchored ids per spine resource. Both Swift-side
    /// cache writes and reinjection-time guards apply this cap.
    static let maxAnchorIdsPerResource = 256

    /// Max byte length (UTF-8) of a single anchor id. WebKit IPC
    /// marshaller has its own much larger ceiling; this is a defence-in-
    /// depth bound paired with the JS-side per-id length filter.
    static let maxAnchorIdByteLength = 4_096
}
