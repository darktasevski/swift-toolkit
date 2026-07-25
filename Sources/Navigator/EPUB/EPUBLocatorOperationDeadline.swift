//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// The single absolute deadline for one locator navigation, minted at operation
/// start and spent — never re-armed — by every rung beneath it.
///
/// A precise landing is not one call: it may hop to another resource, wait for the
/// target page's identity, wait for that spread's command readiness, and only then
/// run the bridge command, which itself waits on viewport, offset settle, and
/// visibility corrections. When each rung minted its own allowance, the total time a
/// navigation could occupy was the SUM of every rung's budget multiplied by the
/// resources it touched, with no relationship to the frozen
/// `locatorNavigationBudgets.totalCommandDeadlineMilliseconds`.
///
/// Passing this value instead of a duration is what makes the contract structural: a
/// rung can only ask how much is LEFT, so there is no argument it could pass to
/// restart the clock.
struct EPUBLocatorOperationDeadline: Equatable, Sendable {
    /// The instant the whole operation must be finished by.
    let expiresAt: ContinuousClock.Instant

    init(startingAt start: ContinuousClock.Instant, budget: Duration) {
        expiresAt = start.advanced(by: budget)
    }

    func hasExpired(at now: ContinuousClock.Instant) -> Bool {
        now >= expiresAt
    }

    /// What remains, in whole milliseconds, clamped to zero.
    ///
    /// Truncates toward zero rather than rounding, so a sub-millisecond remainder can
    /// never be handed on as a millisecond the operation no longer has. The result is
    /// non-negative because it crosses into JavaScript as the command token's
    /// `budgetMilliseconds`, which the script validates as a non-negative integer — a
    /// negative value would be rejected as a malformed token instead of being read as
    /// "no time left".
    func remainingMilliseconds(at now: ContinuousClock.Instant) -> Int {
        guard now < expiresAt else {
            return 0
        }
        let remaining = now.duration(to: expiresAt)
        let (seconds, attoseconds) = remaining.components
        let milliseconds =
            seconds * 1000 + attoseconds / 1_000_000_000_000_000
        return milliseconds > 0 ? Int(milliseconds) : 0
    }
}
