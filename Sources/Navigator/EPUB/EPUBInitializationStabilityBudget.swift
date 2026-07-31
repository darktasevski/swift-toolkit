//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// The single authority for how long one stabilization budget lasts, and for
/// the clock that measures it.
///
/// Three sites mint a stabilization deadline: the shared initialization budget,
/// and two independent caps that bound a JS call which must dispatch even when
/// the shared budget is spent. Before this type each minted its own from the
/// same global constant, so nothing structurally stopped them drifting onto
/// different lengths or different clocks; holding one per spread makes that
/// disagreement unrepresentable.
///
/// Minting is a closure rather than arithmetic over ``milliseconds`` so a
/// caller can observe *how many* budgets a generation armed. That count is the
/// property the budget assertions actually claim — "one budget, never re-armed
/// per rung" — which elapsed wall time can only approximate, and approximates
/// worst exactly when the host is loaded enough to matter.
struct EPUBInitializationStabilityBudget: Sendable {
    /// Why a deadline is being minted. The two are deliberately separate
    /// allowances, not one shared instant: see the call sites in
    /// ``EPUBReflowableSpreadView`` for why an own cap must survive a spent
    /// shared budget.
    enum Purpose: Sendable, Hashable {
        /// The one non-resetting budget shared by stylesheet, font and geometry
        /// stabilization inside a single initialization.
        case sharedInitialization
        /// An independent cap bounding a single JS call that must dispatch
        /// regardless of what the shared budget has left.
        case ownCap
    }

    /// The length of one budget. Read by the rungs that hand the page a
    /// `performance.now()` allowance, so it must stay the same number the
    /// deadline was minted from.
    let milliseconds: Int

    /// The monotonic source every deadline is measured against.
    let clock: EPUBMonotonicClock

    /// Mints the deadline one budget from now.
    let deadline: @Sendable (Purpose) -> ContinuousClock.Instant

    static let production = EPUBInitializationStabilityBudget(
        milliseconds: EPUBSpreadReadiness.initializationStabilityBudgetMilliseconds,
        clock: .continuous
    )

    /// Builds a budget whose deadlines are plain arithmetic over `clock`.
    init(milliseconds: Int, clock: EPUBMonotonicClock) {
        self.init(milliseconds: milliseconds, clock: clock) { _ in
            clock.now().advanced(by: .milliseconds(milliseconds))
        }
    }

    init(
        milliseconds: Int,
        clock: EPUBMonotonicClock,
        deadline: @escaping @Sendable (Purpose) -> ContinuousClock.Instant
    ) {
        self.milliseconds = milliseconds
        self.clock = clock
        self.deadline = deadline
    }

    /// The page-side allowance left at `deadline`, measured by the same clock
    /// that minted this budget. Keeping the clock inside the authority prevents
    /// an injected clock from silently drifting away from the advertised
    /// JavaScript allowance.
    func remainingMilliseconds(until deadline: ContinuousClock.Instant) -> Int {
        let remaining = clock.now().duration(to: deadline)
        guard remaining > .zero else { return 0 }

        let components = remaining.components
        let millisecondsPerSecond: Int64 = 1000
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let wholeMilliseconds = components.seconds * millisecondsPerSecond
        let partialMilliseconds = (
            components.attoseconds + attosecondsPerMillisecond - 1
        ) / attosecondsPerMillisecond
        return Int(wholeMilliseconds + partialMilliseconds)
    }
}
