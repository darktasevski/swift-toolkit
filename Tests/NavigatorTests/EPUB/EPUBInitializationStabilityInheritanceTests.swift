//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// A cross-resource landing hops to another resource, and that resource's spread then
/// runs its own stylesheet, font and geometry stabilization. Because a spread
/// initializes on its own load event rather than from the navigation's call stack, that
/// stage used to mint a FRESH stability budget — so a hop could add its whole allowance
/// on top of the operation that asked for it.
///
/// These pin the two decisions that close it: which loads belong to the operation, and
/// how the inherited remainder composes with the stage's own cap.
final class EPUBInitializationStabilityInheritanceTests: XCTestCase {
    private let base = ContinuousClock().now

    private func spread(atReadingOrderIndex index: Int) -> EPUBSpread {
        .single(EPUBSingleSpread(
            resource: EPUBSpreadResource(index: index, link: Link(href: "c\(index).html"))
        ))
    }

    private func doubleSpread(first: Int, second: Int) -> EPUBSpread {
        .double(EPUBDoubleSpread(
            first: EPUBSpreadResource(index: first, link: Link(href: "p\(first).html")),
            second: EPUBSpreadResource(index: second, link: Link(href: "p\(second).html"))
        ))
    }

    private func operation(
        readingOrderIndex: Int,
        startingAt start: ContinuousClock.Instant,
        budgetMilliseconds: Int = 5000
    ) -> EPUBActiveLocatorOperation {
        EPUBActiveLocatorOperation(
            readingOrderIndex: readingOrderIndex,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: start,
                budget: .milliseconds(budgetMilliseconds)
            )
        )
    }

    // MARK: - Which loads belong to the operation

    func testTheHopTargetSpreadIsMatchedByReadingOrderMembership() {
        let active = operation(readingOrderIndex: 4, startingAt: base)

        XCTAssertEqual(
            EPUBInitializationStabilityInheritance.operationDeadline(
                for: spread(atReadingOrderIndex: 4),
                activeOperation: active
            ),
            active.deadline
        )
    }

    /// The load-bearing exclusion. A neighbour preloaded during the same window is not
    /// part of the operation, so bounding it by the operation's remainder would abort a
    /// perfectly healthy adjacent spread's initialization for no reason. An ambient
    /// "current operation deadline" — the obvious alternative shape — gets this wrong.
    func testAPreloadedNeighbourIsNotPartOfTheOperation() {
        XCTAssertNil(
            EPUBInitializationStabilityInheritance.operationDeadline(
                for: spread(atReadingOrderIndex: 5),
                activeOperation: operation(readingOrderIndex: 4, startingAt: base)
            )
        )
    }

    func testAnOrdinaryLoadOutsideAnyOperationInheritsNothing() {
        XCTAssertNil(
            EPUBInitializationStabilityInheritance.operationDeadline(
                for: spread(atReadingOrderIndex: 4),
                activeOperation: nil
            )
        )
    }

    /// A fixed-layout spread renders two resources; the operation targets one of them.
    /// Membership, not the leading index, decides.
    func testAFixedLayoutSpreadInheritsWhenItsTrailingPageIsTheTarget() {
        let active = operation(readingOrderIndex: 7, startingAt: base)

        XCTAssertEqual(
            EPUBInitializationStabilityInheritance.operationDeadline(
                for: doubleSpread(first: 6, second: 7),
                activeOperation: active
            ),
            active.deadline
        )
    }

    // MARK: - How the inherited remainder composes with the stage's own cap

    /// The defect this closes: 4 s of a 5 s operation is already spent by the time the
    /// hop target initializes, so stabilization gets the remaining 1 s — not a fresh 5 s
    /// laid on top, which is what minting its own cap produced.
    func testATargetSpreadStabilizesWithinTheOperationRemainderNotAFreshBudget() {
        let hopCompleted = base.advanced(by: .milliseconds(4000))
        let active = operation(readingOrderIndex: 4, startingAt: base)
        let ownCap = EPUBLocatorOperationDeadline(
            startingAt: hopCompleted,
            budget: .milliseconds(5000)
        ).expiresAt

        let resolved = EPUBInitializationStabilityInheritance.resolve(
            ownCap: ownCap,
            inheritedFrom: active.deadline,
            at: base
        )

        XCTAssertEqual(resolved, active.deadline.expiresAt)
        XCTAssertEqual(
            active.deadline.remainingMilliseconds(at: hopCompleted),
            1000
        )
        XCTAssertLessThan(resolved, ownCap)
    }

    func testAnOrdinaryLoadKeepsItsOwnStabilityBudget() {
        let ownCap = base.advanced(by: .milliseconds(5000))

        XCTAssertEqual(
            EPUBInitializationStabilityInheritance.resolve(
                ownCap: ownCap,
                inheritedFrom: nil,
                at: base
            ),
            ownCap
        )
    }

    /// Caps compose in one direction only. A stage that bounds itself more tightly than
    /// the operation keeps that bound; it never re-arms itself up to the operation's.
    func testTheStagesOwnCapStillShortensAnOperationWithMoreTimeLeft() {
        let ownCap = base.advanced(by: .milliseconds(800))
        let active = operation(
            readingOrderIndex: 4,
            startingAt: base,
            budgetMilliseconds: 5000
        )

        XCTAssertEqual(
            EPUBInitializationStabilityInheritance.resolve(
                ownCap: ownCap,
                inheritedFrom: active.deadline,
                at: base
            ),
            ownCap
        )
    }

    /// The anti-extension property stated directly: for as long as the operation is
    /// live, however much of it the hop already spent, the resolved instant never lands
    /// after the operation's own expiry.
    func testInheritanceCanNeverExtendStabilizationPastALiveOperation() {
        let active = operation(readingOrderIndex: 4, startingAt: base)

        for elapsedMilliseconds in [0, 250, 1000, 4000, 4999] {
            let now = base.advanced(by: .milliseconds(elapsedMilliseconds))
            let resolved = EPUBInitializationStabilityInheritance.resolve(
                ownCap: now.advanced(by: .milliseconds(5000)),
                inheritedFrom: active.deadline,
                at: now
            )
            XCTAssertLessThanOrEqual(
                resolved,
                active.deadline.expiresAt,
                "elapsed=\(elapsedMilliseconds)ms extended past the operation"
            )
        }
    }

    /// An operation that has ALREADY expired is not inherited at all.
    ///
    /// Handing on a spent instant is not a harmless zero wait: the stage's
    /// remaining-budget guard turns it into a failed initialization, which fails the
    /// render generation and leaves the spread permanently hidden. Declining is not a
    /// re-arm — the operation is over and gains nothing from starving the spread.
    @MainActor
    func testAnAlreadyExpiredOperationIsNotInheritedAndLeavesTheStageItsOwnBudget() {
        let active = operation(readingOrderIndex: 4, startingAt: base)
        let afterOverrun = base.advanced(by: .milliseconds(6000))
        let ownCap = afterOverrun.advanced(by: .milliseconds(5000))

        let resolved = EPUBInitializationStabilityInheritance.resolve(
            ownCap: ownCap,
            inheritedFrom: active.deadline,
            at: afterOverrun
        )

        XCTAssertEqual(resolved, ownCap)
        let stopped = EPUBMonotonicClock(now: { afterOverrun }, sleep: { _ in })
        XCTAssertEqual(
            EPUBInitializationStabilityBudget(
                milliseconds: 5000,
                clock: stopped
            ).remainingMilliseconds(until: resolved),
            5000,
            "an expired operation must not starve the spread that outlives it"
        )
    }

    /// The residual the expired-case fix deliberately does NOT close: a live operation
    /// with only a sliver left still hands on that sliver. Pinned so the boundary is
    /// explicit rather than assumed — closing it needs a minimum-budget floor, which
    /// would be a genuine re-arm.
    @MainActor
    func testALiveOperationWithASliverLeftStillHandsOnOnlyThatSliver() {
        let active = operation(readingOrderIndex: 4, startingAt: base)
        let nearlySpent = base.advanced(by: .milliseconds(4999))

        let resolved = EPUBInitializationStabilityInheritance.resolve(
            ownCap: nearlySpent.advanced(by: .milliseconds(5000)),
            inheritedFrom: active.deadline,
            at: nearlySpent
        )

        let stopped = EPUBMonotonicClock(now: { nearlySpent }, sleep: { _ in })
        XCTAssertEqual(
            EPUBInitializationStabilityBudget(
                milliseconds: 5000,
                clock: stopped
            ).remainingMilliseconds(until: resolved),
            1
        )
    }
}

/// The navigator publishes its in-flight hop into a slot the target spread reads back
/// on its own load event. Locator navigation is latest-request-wins with a BOUNDED
/// predecessor acknowledgement, so a superseded operation can still be unwinding while
/// its successor owns the slot — these pin that it can never clear the successor's
/// entry, which would silently restore the fresh-budget behaviour for that landing.
@MainActor
final class EPUBActiveLocatorOperationSlotTests: XCTestCase {
    private let base = ContinuousClock().now

    private func spread(atReadingOrderIndex index: Int) -> EPUBSpread {
        .single(EPUBSingleSpread(
            resource: EPUBSpreadResource(index: index, link: Link(href: "c\(index).html"))
        ))
    }

    private func operation(readingOrderIndex: Int) -> EPUBActiveLocatorOperation {
        EPUBActiveLocatorOperation(
            readingOrderIndex: readingOrderIndex,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: base,
                budget: .milliseconds(5000)
            )
        )
    }

    func testNothingIsInheritedBeforeAnOperationIsPublished() {
        let slot = EPUBActiveLocatorOperationSlot()

        XCTAssertNil(slot.operationDeadline(for: spread(atReadingOrderIndex: 4)))
    }

    func testAPublishedOperationIsInheritedByItsHopTarget() {
        let slot = EPUBActiveLocatorOperationSlot()
        let active = operation(readingOrderIndex: 4)
        slot.publish(active)

        XCTAssertEqual(
            slot.operationDeadline(for: spread(atReadingOrderIndex: 4)),
            active.deadline
        )
        XCTAssertNil(slot.operationDeadline(for: spread(atReadingOrderIndex: 5)))
    }

    func testClearingTheOwnEntryEndsInheritance() {
        let slot = EPUBActiveLocatorOperationSlot()
        let active = operation(readingOrderIndex: 4)
        slot.publish(active)
        slot.clear(active)

        XCTAssertNil(slot.operationDeadline(for: spread(atReadingOrderIndex: 4)))
    }

    func testASupersedingOperationReplacesItsPredecessor() {
        let slot = EPUBActiveLocatorOperationSlot()
        slot.publish(operation(readingOrderIndex: 4))
        let successor = operation(readingOrderIndex: 9)
        slot.publish(successor)

        XCTAssertNil(slot.operationDeadline(for: spread(atReadingOrderIndex: 4)))
        XCTAssertEqual(
            slot.operationDeadline(for: spread(atReadingOrderIndex: 9)),
            successor.deadline
        )
    }

    /// The guard that makes the slot safe under supersession: the predecessor unwinds
    /// AFTER the successor published, and its clear must be inert.
    func testASupersededPredecessorCannotClearItsSuccessorsEntry() {
        let slot = EPUBActiveLocatorOperationSlot()
        let predecessor = operation(readingOrderIndex: 4)
        slot.publish(predecessor)
        let successor = operation(readingOrderIndex: 9)
        slot.publish(successor)

        slot.clear(predecessor)

        XCTAssertEqual(
            slot.operationDeadline(for: spread(atReadingOrderIndex: 9)),
            successor.deadline
        )
    }

    func testClearingAnEntryThatNeverPublishedIsInert() {
        let slot = EPUBActiveLocatorOperationSlot()
        let active = operation(readingOrderIndex: 4)
        slot.publish(active)

        slot.clear(operation(readingOrderIndex: 4))

        XCTAssertEqual(
            slot.operationDeadline(for: spread(atReadingOrderIndex: 4)),
            active.deadline
        )
    }
}
