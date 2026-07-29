//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

final class EPUBInitializationStabilityBudgetTests: XCTestCase {
    /// The property every mint-count assertion silently rests on.
    ///
    /// A budget that memoized its instant would make re-arming structurally
    /// invisible: the count would keep reading one while a rung armed a fresh
    /// allowance on every rung. Nothing else in the suite would notice, because
    /// the counts would all still be right.
    func testEachMintIsAFreshAllowanceRatherThanAMemoizedInstant() {
        var now = ContinuousClock.now
        let budget = EPUBInitializationStabilityBudget(
            milliseconds: 1000,
            clock: EPUBMonotonicClock(
                now: { now },
                sleep: { _ in }
            )
        )

        let first = budget.deadline(.sharedInitialization)
        now = now.advanced(by: .milliseconds(500))
        let second = budget.deadline(.sharedInitialization)

        XCTAssertEqual(first.duration(to: second), .milliseconds(500))
    }

    /// The two purposes are separate ALLOWANCES of equal length, not one shared
    /// instant. An own cap exists precisely to survive a spent shared budget, so
    /// collapsing them would defeat the thing it is for.
    func testAnOwnCapIsIndependentOfTheSharedAllowanceRatherThanTheSameInstant() {
        var now = ContinuousClock.now
        let budget = EPUBInitializationStabilityBudget(
            milliseconds: 1000,
            clock: EPUBMonotonicClock(
                now: { now },
                sleep: { _ in }
            )
        )

        let shared = budget.deadline(.sharedInitialization)
        now = now.advanced(by: .milliseconds(750))
        let ownCap = budget.deadline(.ownCap)

        XCTAssertEqual(shared.duration(to: ownCap), .milliseconds(750))
    }

    /// The production binding is what ships to readers, and every test in the
    /// suite overrides the budget — so nothing else would notice a drift here.
    func testProductionUsesTheShippedAllowanceAndTheContinuousClock() {
        XCTAssertEqual(
            EPUBInitializationStabilityBudget.production.milliseconds,
            EPUBSpreadReadiness.initializationStabilityBudgetMilliseconds
        )

        let budget = EPUBInitializationStabilityBudget.production
        let before = ContinuousClock.now
        let deadline = budget.deadline(.sharedInitialization)
        let after = ContinuousClock.now

        // Bracketed rather than compared to a single instant: the clock advances
        // between the two reads, so the only exact statement available is that
        // the deadline lands one allowance past a point inside that bracket.
        XCTAssertGreaterThanOrEqual(deadline, before.advanced(by: .milliseconds(budget.milliseconds)))
        XCTAssertLessThanOrEqual(deadline, after.advanced(by: .milliseconds(budget.milliseconds)))
    }

    /// `milliseconds` is handed to the page as its own `performance.now()`
    /// allowance while `deadline` bounds the Swift-side await, so in production
    /// the two must describe the same window — the watchdog's whole premise is
    /// that the two budgets cannot disagree.
    func testTheAdvertisedLengthMatchesTheMintedDeadline() {
        var now = ContinuousClock.now
        let budget = EPUBInitializationStabilityBudget(
            milliseconds: 2500,
            clock: EPUBMonotonicClock(
                now: { now },
                sleep: { _ in }
            )
        )

        let start = now
        let deadline = budget.deadline(.sharedInitialization)

        XCTAssertEqual(
            start.duration(to: deadline),
            .milliseconds(budget.milliseconds)
        )
    }
}
