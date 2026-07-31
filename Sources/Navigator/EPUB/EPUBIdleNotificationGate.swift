//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Coalesces requests to run work that must wait until the navigator settles
/// into an idle lifecycle state.
///
/// Replaces a `DispatchQueue` poll (`execute(when:pollingInterval:)`) with an
/// edge-triggered drain: a request made while the navigator is busy is stashed
/// and released the instant the state machine reports idle, rather than
/// re-checked every fixed interval. A request made while idle runs at once. The
/// stash is idempotent — repeated busy-time requests still drain exactly once —
/// and draining clears it so a later request re-evaluates from scratch.
@MainActor
final class EPUBIdleNotificationGate {
    private var isIdle: Bool
    private var hasPendingRequest = false

    init(isIdle: Bool = false) {
        self.isIdle = isIdle
    }

    /// Requests the deferred work. Returns `true` when the caller should run it
    /// now (the gate is idle); `false` stashes the request until the next
    /// busy→idle transition.
    func request() -> Bool {
        guard isIdle else {
            hasPendingRequest = true
            return false
        }
        hasPendingRequest = false
        return true
    }

    /// Records a lifecycle transition. Returns `true` only on the busy→idle
    /// edge with a request pending — the single moment a stashed request should
    /// run. Draining clears the stash so it fires at most once per request.
    func setIdle(_ idle: Bool) -> Bool {
        isIdle = idle
        guard idle, hasPendingRequest else { return false }
        hasPendingRequest = false
        return true
    }
}
