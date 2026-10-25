//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class EPUBLocationPublicationTests: XCTestCase {
    // MARK: - Idle

    func test_aRequestWhileIdleCalculatesAndCommits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")

        fixture.publication.request()

        XCTAssertEqual(fixture.dispatched, ["a"])
        a.release()
        try await fixture.waitUntil { fixture.committed == ["a"] }
        XCTAssertFalse(fixture.publication.hasObligation)
    }

    func test_aRequestWhileNavigatingWaitsUntilIdle() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()

        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, [])
        XCTAssertTrue(fixture.publication.hasObligation)

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    func test_repeatedRequestsWhileNavigatingCalculateOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()
        fixture.publication.request()
        fixture.publication.request()
        fixture.publication.request()

        fixture.publication.setIdle(true)
        try await fixture.waitUntil { fixture.committed == ["a"] }
        fixture.publication.setIdle(false)
        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
    }

    func test_settlingWithoutAnObligationCalculatesNothing() throws {
        let fixture = try PublicationFixture()
        fixture.offer("a")

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, [])
    }

    /// A committed result discharges the obligation, so settling again after
    /// another navigation needs a new request.
    func test_aCommittedResultDischargesTheObligation() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.offer("a").release()
        fixture.publication.request()
        try await fixture.waitUntil { fixture.committed == ["a"] }

        fixture.publication.setIdle(false)
        fixture.offer("b")
        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
    }

    /// An obligation retained while navigating survives a further navigation
    /// and runs once, when the navigator first settles.
    func test_anObligationSurvivesAnotherNavigationBeforeSettling() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()
        fixture.publication.request()
        fixture.publication.setIdle(false)
        XCTAssertEqual(fixture.dispatched, [])

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    /// Idle with nothing current to read retains the obligation; the request
    /// that comes with publishable inputs runs it once.
    func test_anObligationWaitsForPublishableInputs() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)

        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, [])
        XCTAssertTrue(fixture.publication.hasObligation)

        fixture.offer("a").release()
        fixture.publication.request()

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    // MARK: - One calculation at a time

    /// Requests while a calculation runs neither start a second one nor
    /// supersede it; they retain exactly one follow-up.
    func test_requestsDuringACalculationCoalesceIntoOneFollowUp() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()

        fixture.publication.request()
        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, ["a"], "A second calculation started beside the first")

        let followUp = fixture.offer("a-again")
        a.release()
        try await fixture.waitUntil { followUp.started }
        followUp.release()
        try await fixture.waitUntil { fixture.committed == ["a", "a-again"] }
        XCTAssertEqual(fixture.dispatched, ["a", "a-again"])
        XCTAssertFalse(fixture.publication.hasObligation)
    }

    // MARK: - Currency

    /// Navigating while A computes keeps A's result from committing, even when
    /// the navigator is idle again by then; the latest inputs are calculated
    /// and committed instead.
    func test_aCalculationOutlivedByANavigationCommitsNothingAndTheLatestDoes() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        fixture.publication.setIdle(false)
        let b = fixture.offer("b")
        fixture.publication.setIdle(true)
        a.release()

        try await fixture.waitUntil { !fixture.committed.isEmpty || fixture.dispatched.last == "b" }
        XCTAssertEqual(fixture.committed, [], "A calculation outlived by a navigation committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
    }

    /// A capture that stopped being current (new geometry, or another spread
    /// at the same index) commits nothing, with no navigation needed.
    func test_aCaptureThatStoppedBeingCurrentCommitsNothing() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        a.isCurrent = false
        let b = fixture.offer("b")
        a.release()

        try await fixture.waitUntil { !fixture.committed.isEmpty || fixture.dispatched.last == "b" }
        XCTAssertEqual(fixture.committed, [], "A result that was no longer current committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
    }

    func test_aNewObservationOfTheSameSpreadIsANewKey() {
        let capability = EPUBSpreadFrameCapability()
        let before = EPUBPublicationKey(spreadIndex: 2, capability: capability, stamp: 4)

        XCTAssertNotEqual(before, EPUBPublicationKey(spreadIndex: 2, capability: capability, stamp: 5))
        XCTAssertEqual(before, EPUBPublicationKey(spreadIndex: 2, capability: capability, stamp: 4))
    }

    /// A spread replaced at the same index loads its document under a
    /// capability of its own, so its key is new.
    func test_aReplacedSpreadAtTheSameIndexIsANewKey() {
        XCTAssertNotEqual(
            EPUBPublicationKey(spreadIndex: 2, capability: EPUBSpreadFrameCapability(), stamp: 4),
            EPUBPublicationKey(spreadIndex: 2, capability: EPUBSpreadFrameCapability(), stamp: 4)
        )
    }

    // MARK: - Holds

    /// A hold keeps an idle navigator from calculating; its release runs the
    /// obligation retained meanwhile.
    func test_aHoldKeepsAnIdleNavigatorFromCalculatingUntilItsRelease() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.offer("a").release()
        fixture.publication.hold()

        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, [], "A held publication calculated")
        XCTAssertTrue(fixture.publication.hasObligation)

        fixture.publication.release()

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    /// A hold taken while a calculation runs keeps its result from committing,
    /// as leaving idle does; the release calculates the latest inputs.
    func test_aCalculationOutlivedByAHoldCommitsNothingAndTheReleaseRecalculates() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        fixture.publication.hold()
        fixture.offer("b").release()
        a.release()
        try await fixture.waitUntil { a.exited && !fixture.publication.isCalculating }

        XCTAssertEqual(fixture.committed, [], "A calculation outlived by a hold committed")
        XCTAssertEqual(fixture.dispatched, ["a"], "A held publication calculated")
        fixture.publication.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
    }

    // MARK: - Rebuild location

    func test_aRebuildStartsAtTheInitialLocationUntilAPositionIsMeasured() throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.rebuildTitle, PublicationFixture.initialTitle)
    }

    /// A rebuild starts at the measured position, one started before the
    /// rebuilt spread measures anything starts there too, and the next
    /// measurement replaces it.
    func test_aRebuildStartsAtTheCurrentPositionUntilAnotherIsMeasured() throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.measure("a")

        XCTAssertEqual(fixture.rebuildTitle, "a")
        fixture.measure(nil)
        XCTAssertEqual(fixture.rebuildTitle, "a")
        fixture.measure("b")
        XCTAssertEqual(fixture.rebuildTitle, "b")
    }

    /// A request records the position measured then, so a rebuild after that
    /// measurement is revoked, as motion revokes it, still starts there.
    func test_aRequestRecordsThePositionARebuildStartsAt() throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.measure("a")
        fixture.publication.request()

        fixture.measure(nil)

        XCTAssertEqual(fixture.rebuildTitle, "a")
    }

    /// A calculation can start with no request, when the one before it exits
    /// stale; what it publishes is recorded too, so a rebuild never starts
    /// behind the published location.
    func test_aCalculationStartedWithoutARequestRecordsThePositionItPublishes() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.measure("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        a.isCurrent = false
        fixture.offer("b").release()
        fixture.measure("b")
        a.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
        fixture.measure(nil)

        XCTAssertEqual(fixture.rebuildTitle, "b", "A rebuild would start behind the published location")
    }

    /// While the navigator navigates, the current spread can be one it is
    /// passing through, such as a neighbour shown before its landing: no
    /// calculation would publish it, so it is not recorded until the navigator
    /// settles.
    func test_aPositionMeasuredWhileNavigatingIsRecordedOnlyOnceTheNavigatorSettles() throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.measure("before")
        fixture.publication.request()
        fixture.publication.setIdle(false)

        fixture.measure("passing")
        fixture.publication.request()
        XCTAssertEqual(fixture.rebuildTitle, "before", "A rebuild while navigating started at a position measured mid-navigation")

        fixture.measure("landed")
        fixture.publication.setIdle(true)
        fixture.measure(nil)
        XCTAssertEqual(fixture.rebuildTitle, "landed", "Settling did not record the position")
    }

    /// What shows while an operation holds publication is not its result: a
    /// rebuild meanwhile starts at the position recorded before the hold, and
    /// only the last release records the current one.
    func test_aHoldKeepsTheRebuildLocationUntilTheLastRelease() throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.measure("before")
        fixture.publication.request()
        fixture.publication.hold()
        fixture.publication.hold()

        fixture.measure("hop")
        fixture.publication.request()
        XCTAssertEqual(fixture.rebuildTitle, "before", "A rebuild during a hold started at the held position")
        fixture.measure("landing")
        fixture.publication.release()
        XCTAssertEqual(fixture.rebuildTitle, "before", "A rebuild during the remaining hold started at the held position")

        fixture.publication.release()
        fixture.measure(nil)
        XCTAssertEqual(fixture.rebuildTitle, "landing", "The last release did not record the position")
    }

    // MARK: - Deadline and actual exit

    /// A calculation past its deadline keeps the slot: no replacement starts
    /// until it actually exits, its result is discarded, and then the latest
    /// obligation runs and commits.
    func test_anExpiredCalculationKeepsItsSlotUntilItExits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget)
        XCTAssertTrue(fixture.publication.isOperationPending)
        XCTAssertTrue(fixture.publication.hasObligation, "Expiry dropped the obligation")
        let b = fixture.offer("b")
        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, ["a"], "A replacement started beside the expired calculation")

        a.release()
        try await fixture.waitUntil { b.started }
        XCTAssertEqual(fixture.committed, [], "The expired result committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
        XCTAssertFalse(fixture.publication.isOperationPending)
    }

    /// A calculation still running does not keep the publication alive, and
    /// its late exit commits nothing.
    func test_aRunningCalculationDoesNotKeepThePublicationAlive() async throws {
        let deadlines = ManualDeadlines()
        let calculation = try Calculation(name: "a", href: XCTUnwrap(RelativeURL(path: "chapter.html")).anyURL)
        let commits = CommitRecorder()
        var publication: EPUBLocationPublication? = EPUBLocationPublication(
            scheduler: deadlines.scheduler,
            initialLocation: nil,
            position: { nil },
            capture: { EPUBPublicationCapture(isCurrent: { true }, calculate: { await calculation.run() }) },
            commit: { commits.titles.append($0.locator?.title ?? "nil") }
        )
        publication?.setIdle(true)
        publication?.request()
        try await pollUntil { calculation.started }
        weak let weakPublication = publication

        publication = nil
        XCTAssertNil(weakPublication, "The running calculation kept the publication alive")

        calculation.release()
        try await pollUntil { calculation.exited }
        try await ContinuousClock().sleep(for: .milliseconds(50))
        XCTAssertEqual(commits.titles, [], "The released publication's calculation committed")
    }

    func test_aCalculationThatExitsInTimeLeavesNoDeadlineArmed() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.offer("a").release()

        fixture.publication.request()
        try await fixture.waitUntil { fixture.committed == ["a"] }

        XCTAssertEqual(fixture.deadlines.armedCount, 0)
        XCTAssertFalse(fixture.publication.isCalculating)
    }

    // MARK: - Pending commit wait

    func test_aWaitWithNothingOutstandingReturnsAtOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)

        let wait = fixture.startWait()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "A wait with nothing outstanding armed a deadline")
    }

    func test_aWaitResumesOnceTheRunningCalculationCommits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)
        a.release()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.committed, ["a"])
    }

    func test_aWaitEndsAtItsDeadlineWhileWorkIsStillOutstanding() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working

        let wait = try await fixture.startArmedWait()
        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget - .milliseconds(1))
        try await fixture.assertStillWaiting(wait)
        fixture.deadlines.advance(by: .milliseconds(1))
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, true)
    }

    func test_aCalculationBegunMidWaitDoesNotExtendItsDeadline() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let wait = try await fixture.startArmedWait()
        fixture.deadlines.advance(by: .seconds(3))

        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }
        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget - .seconds(3))
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, true)
        XCTAssertTrue(fixture.publication.isCalculating, "premise: the later calculation is still running")
        a.release()
    }

    /// An obligation with nothing publishable to capture still holds the wait:
    /// the inputs it waits for are on their way.
    func test_anObligationWaitingForPublishableInputsHoldsTheWait() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.current = nil
        fixture.publication.request()
        XCTAssertTrue(fixture.publication.hasObligation, "premise: the obligation was retained")
        XCTAssertFalse(fixture.publication.isCalculating, "premise: nothing could be captured")

        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)
        fixture.offer("a").release()
        fixture.publication.request()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.committed, ["a"])
    }

    /// A navigation under way when the wait starts will settle and ask for a
    /// publication: a dismiss early in a page turn waits for the turn.
    func test_aNavigationInFlightHoldsTheWaitUntilWhatItSettlesOnCommits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.publication.setIdle(false)
        XCTAssertFalse(fixture.publication.hasObligation, "premise: the move has not asked yet")

        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)
        let a = fixture.offer("a")
        fixture.publication.request()
        fixture.publication.setIdle(true)
        try await fixture.waitUntil { a.started }
        try await fixture.assertStillWaiting(wait)
        a.release()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.committed, ["a"])
    }

    /// Before its first settle the navigator is still opening at its initial
    /// location, which has nothing newer to publish.
    func test_aNavigatorThatNeverSettledHasNothingToWaitFor() async throws {
        let fixture = try PublicationFixture()

        let wait = fixture.startWait()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
    }

    func test_aHoldHoldsTheWaitUntilItsRelease() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.publication.hold()

        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)
        fixture.publication.release()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
    }

    /// A calculation outlived by a navigation exits without committing and
    /// keeps the obligation, so the wait runs on to the next commit.
    func test_aStaleExitKeepsTheWaitUntilTheNextCalculationCommits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }
        let wait = try await fixture.startArmedWait()
        fixture.publication.setIdle(false)
        fixture.publication.setIdle(true)
        let b = fixture.offer("b")

        a.release()
        try await fixture.waitUntil { b.started }
        try await fixture.assertStillWaiting(wait)
        b.release()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.committed, ["b"])
    }

    func test_spreadWorkHoldsTheWaitUntilTheSpreadReportsItDone() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working

        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)
        fixture.spreadWork = .idle
        fixture.publication.spreadWorkDidChange()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
    }

    /// The observation reports each of its changes as it makes it, so within
    /// one turn it can pass through a state that is not where it ends.
    func test_aSpreadThatIsIdleOnlyMidTurnDoesNotEndTheWait() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let wait = try await fixture.startArmedWait()

        fixture.spreadWork = .idle
        fixture.publication.spreadWorkDidChange()
        fixture.spreadWork = .working
        fixture.publication.spreadWorkDidChange()

        try await fixture.assertStillWaiting(wait)
        fixture.spreadWork = .idle
        fixture.publication.spreadWorkDidChange()
        try await fixture.waitUntil { wait.isFinished }
    }

    func test_aBlockedSpreadEndsTheWaitAtOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)

        fixture.spreadWork = .blocked
        fixture.publication.spreadWorkDidChange()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
    }

    /// An expired calculation may never exit, and until it does nothing else
    /// can publish (ADR-0195, the navigator slot).
    func test_anExpiredCalculationHoldingTheSlotEndsTheWaitAtOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }
        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget)
        XCTAssertTrue(fixture.publication.isOperationPending, "premise: the calculation expired")

        let wait = fixture.startWait()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        a.release()
    }

    /// A deadline and a change that ends the wait arriving together resume it
    /// once: a second resume would trap.
    func test_theDeadlineAndAnEndingChangeTogetherResumeTheWaitOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)

        fixture.spreadWork = .idle
        fixture.publication.spreadWorkDidChange()
        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget)
        try await fixture.waitUntil { wait.isFinished }
        try await fixture.settle()

        XCTAssertEqual(wait.deadlinePassed, true)
    }

    func test_everyOutstandingWaitResumes() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let first = fixture.startWait()
        let second = fixture.startWait()
        try await fixture.assertStillWaiting(first)

        fixture.spreadWork = .idle
        fixture.publication.spreadWorkDidChange()
        try await fixture.waitUntil { first.isFinished && second.isFinished }

        XCTAssertEqual(first.deadlinePassed, false)
        XCTAssertEqual(second.deadlinePassed, false)
    }

    func test_aCancelledWaitReturnsAtOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.spreadWork = .working
        let wait = fixture.startWait()
        try await fixture.assertStillWaiting(wait)

        wait.cancel()
        try await fixture.waitUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, false)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "The cancelled wait left its deadline armed")
    }

    /// The suspended call keeps the publication alive, and the deadline still
    /// ends the wait when nothing else owns it.
    func test_aWaitWhosePublicationHasNoOtherOwnerResumesAtItsDeadline() async throws {
        let deadlines = ManualDeadlines()
        var publication: EPUBLocationPublication? = EPUBLocationPublication(
            scheduler: deadlines.scheduler,
            initialLocation: nil,
            position: { nil },
            capture: { nil },
            commit: { _ in }
        )
        publication?.setIdle(true)
        publication?.spreadWork = { .working }
        let wait = try PendingWait(XCTUnwrap(publication))
        weak let weakPublication = publication

        publication = nil
        try await pollUntil { deadlines.armedCount == 1 }
        XCTAssertNotNil(weakPublication, "premise: the suspended wait keeps its publication")
        deadlines.advance(by: EPUBLocationPublication.calculationBudget)
        try await pollUntil { wait.isFinished }

        XCTAssertEqual(wait.deadlinePassed, true)
        try await pollUntil { weakPublication == nil }
    }
}

// MARK: - Fixtures

/// A calculation held open until the test releases it.
@MainActor
private final class Calculation {
    let name: String
    let href: AnyURL
    var isCurrent = true
    private(set) var started = false
    private(set) var exited = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(name: String, href: AnyURL) {
        self.name = name
        self.href = href
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func run() async -> EPUBPublicationOutput {
        started = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        exited = true
        return EPUBPublicationOutput(
            locator: Locator(href: href, mediaType: .html, title: name),
            viewport: NavigatorViewport(resources: [], progression: 0 ... 0, positions: nil)
        )
    }
}

/// A publication whose inputs, calculations and commits the test controls.
@MainActor
private final class PublicationFixture {
    static let initialTitle = "initial"

    let deadlines = ManualDeadlines()
    private let href: AnyURL
    /// What the navigator would capture now; `nil` while it cannot publish.
    var current: Calculation?
    /// The position the current spread measured; `nil` while it has none.
    private var position: Locator?
    private(set) var dispatched: [String] = []
    private(set) var committed: [String] = []

    /// What the current spread still owes the publication.
    var spreadWork: EPUBSpreadLocationWork = .idle

    lazy var publication: EPUBLocationPublication = {
        let publication = EPUBLocationPublication(
            scheduler: deadlines.scheduler,
            initialLocation: Locator(href: href, mediaType: .html, title: Self.initialTitle),
            position: { [unowned self] in position },
            capture: { [unowned self] in
                guard let calculation = current else {
                    return nil
                }
                dispatched.append(calculation.name)
                return EPUBPublicationCapture(
                    isCurrent: { calculation.isCurrent },
                    calculate: { await calculation.run() }
                )
            },
            commit: { [unowned self] in committed.append($0.locator?.title ?? "nil") }
        )
        publication.spreadWork = { [unowned self] in spreadWork }
        return publication
    }()

    init() throws {
        href = try XCTUnwrap(RelativeURL(path: "chapter.html")).anyURL
    }

    @discardableResult
    func offer(_ name: String) -> Calculation {
        let calculation = Calculation(name: name, href: href)
        current = calculation
        return calculation
    }

    /// Makes the current spread's measured position the one titled `name`, or
    /// leaves it without one.
    func measure(_ name: String?) {
        position = name.map { Locator(href: href, mediaType: .html, title: $0) }
    }

    /// The title of the location a rebuild would start at now.
    var rebuildTitle: String? {
        publication.rebuildLocation()?.title
    }

    func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await pollUntil(condition, file: file, line: line)
    }

    /// Starts a wait for the pending commit.
    func startWait() -> PendingWait {
        PendingWait(publication)
    }

    /// Starts a wait and returns once its deadline is armed, so advancing the
    /// deadlines measures from the wait's start.
    func startArmedWait() async throws -> PendingWait {
        let armedBefore = deadlines.armedCount
        let wait = startWait()
        try await waitUntil { deadlines.armedCount == armedBefore + 1 }
        return wait
    }

    /// Lets queued main-actor work run.
    func settle() async throws {
        try await ContinuousClock().sleep(for: .milliseconds(50))
    }

    /// Fails when `wait` has ended, after letting queued main-actor work run.
    func assertStillWaiting(
        _ wait: PendingWait,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await settle()
        XCTAssertNil(wait.deadlinePassed, "The wait ended with work outstanding", file: file, line: line)
    }
}

/// One wait for a publication's pending commit, run in its own task.
@MainActor
private final class PendingWait {
    private(set) var deadlinePassed: Bool?
    private var task: Task<Void, Never>?

    init(_ publication: EPUBLocationPublication) {
        task = Task { @MainActor [weak self] in
            let passed = await publication.awaitPendingCommit()
            self?.deadlinePassed = passed
        }
    }

    var isFinished: Bool {
        deadlinePassed != nil
    }

    func cancel() {
        task?.cancel()
    }
}

/// Commits recorded apart from any fixture, so a test can release everything
/// else.
@MainActor
private final class CommitRecorder {
    var titles: [String] = []
}

/// Polls until `condition` holds, failing otherwise.
@MainActor
private func pollUntil(
    _ condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if condition() {
            return
        }
        try await clock.sleep(for: .milliseconds(5))
    }
    XCTFail("Condition did not become true before timeout", file: file, line: line)
    throw PublicationTimeout()
}

private struct PublicationTimeout: Error {}
