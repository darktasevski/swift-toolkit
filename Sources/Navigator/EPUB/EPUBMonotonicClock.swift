//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// The monotonic time source the locator navigation authority reads and sleeps on.
///
/// Every rung of a precise landing is bounded by one absolute
/// `EPUBLocatorOperationDeadline`, and the arithmetic that spends it is pure — it
/// takes the instant to measure against. This type is the other half: the single
/// seam through which the authority learns what "now" is and waits for an instant
/// to arrive. Reading `ContinuousClock().now` inline at each rung, as the code did
/// before, left the enforcement untestable — the only way to observe a deadline
/// being enforced was to wait out the real budget, which no unit test can do
/// deterministically.
///
/// Two closures rather than a `Clock` conformance: the deadline is typed on
/// `ContinuousClock.Instant` (frozen by both the arithmetic and the millisecond
/// budget that crosses into JavaScript), so generalizing every rung over the
/// `Clock` protocol would add generic parameters without buying a second instant
/// type. It matches the injection seam the navigation queue already uses for its
/// predecessor-acknowledgement budget.
struct EPUBMonotonicClock: Sendable {
    /// The current monotonic instant. Monotonic, not wall-clock: a system clock
    /// adjustment must never lengthen or shorten a navigation's budget.
    let now: @Sendable () -> ContinuousClock.Instant

    /// Waits until the given absolute instant. Takes an instant rather than a
    /// duration for the same reason every rung does: a duration computed at the
    /// call site is an opportunity to re-arm a spent budget.
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    /// The production binding.
    static let continuous = EPUBMonotonicClock(
        now: { ContinuousClock().now },
        sleep: { try await ContinuousClock().sleep(until: $0) }
    )
}
