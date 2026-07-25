//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// A precise landing spans several rungs — page identity, command readiness, then the
/// bridge command itself, plus a cross-resource hop before any of them. The contract is
/// that ONE deadline is minted at operation start and every rung spends what is left of
/// it. These pin the arithmetic that makes "what is left" impossible to re-arm.
final class EPUBLocatorOperationDeadlineTests: XCTestCase {
    private let base = ContinuousClock().now

    func testRemainingBudgetIsTheFullAllowanceAtOperationStart() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(5000))
        XCTAssertEqual(deadline.remainingMilliseconds(at: base), 5000)
    }

    func testRemainingBudgetShrinksAsTheOperationProgresses() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(5000))
        XCTAssertEqual(
            deadline.remainingMilliseconds(at: base.advanced(by: .milliseconds(1200))),
            3800
        )
    }

    /// The anti-reset property, stated directly: a later rung reading the SAME deadline
    /// must receive strictly less than an earlier one. A rung that minted its own budget
    /// (the behaviour this replaces) would return the full allowance again here.
    func testALaterRungAlwaysReceivesStrictlyLessThanAnEarlierRung() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(5000))
        let atReadiness = deadline.remainingMilliseconds(at: base.advanced(by: .milliseconds(900)))
        let atBridgeCommand = deadline.remainingMilliseconds(
            at: base.advanced(by: .milliseconds(2300))
        )
        XCTAssertLessThan(atBridgeCommand, atReadiness)
        XCTAssertEqual(atReadiness, 4100)
        XCTAssertEqual(atBridgeCommand, 2700)
    }

    /// An overrun must clamp to zero, never go negative: the budget crosses into JavaScript
    /// as a non-negative integer the script's token validation requires, and a negative value
    /// there would be rejected as a malformed token rather than treated as "no time left".
    func testAnOverrunClampsToZeroRatherThanGoingNegative() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(250))
        XCTAssertEqual(
            deadline.remainingMilliseconds(at: base.advanced(by: .milliseconds(4000))),
            0
        )
        XCTAssertTrue(deadline.hasExpired(at: base.advanced(by: .milliseconds(4000))))
    }

    func testExpiryIsInclusiveOfTheDeadlineInstant() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(250))
        XCTAssertFalse(deadline.hasExpired(at: base.advanced(by: .milliseconds(249))))
        XCTAssertTrue(deadline.hasExpired(at: base.advanced(by: .milliseconds(250))))
    }

    /// Sub-millisecond remainders must not round UP into a budget the operation no longer
    /// has; truncation toward zero keeps the deadline an upper bound at every rung.
    func testSubMillisecondRemaindersTruncateRatherThanRoundUp() {
        let deadline = EPUBLocatorOperationDeadline(startingAt: base, budget: .milliseconds(10))
        XCTAssertEqual(
            deadline.remainingMilliseconds(at: base.advanced(by: .microseconds(9500))),
            0
        )
    }
}
