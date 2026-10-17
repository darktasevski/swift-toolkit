//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// The observation scheduler's state contract, driven with deadlines, reads and
/// answers the test controls: one read at a time, a retained obligation, hints
/// that only ask, a single bounded retry and explicit unavailability.
@MainActor
final class EPUBLocationObservationTests: XCTestCase {
    // MARK: - Dispatch and acceptance

    func test_aRequestWhileEligibleReadsOnceAndPublishesTheSample() {
        let fixture = ObservationFixture()

        fixture.observation.request()
        fixture.answer(0, fixture.sample(0.25 ... 0.5))

        XCTAssertEqual(fixture.startedReads, 1)
        XCTAssertEqual(fixture.accepted.map(\.sample.range), [0.25 ... 0.5])
        XCTAssertEqual(fixture.observation.currentObservation, fixture.accepted.last)
        XCTAssertFalse(fixture.observation.hasObligation)
    }

    func test_requestsWhileAReadIsOutstandingStartNoSecondReadButOneFollowUp() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        for _ in 0 ..< 5 {
            fixture.observation.request()
        }
        XCTAssertEqual(fixture.startedReads, 1, "A second read started beside the outstanding one")

        fixture.answer(0, fixture.sample(0 ... 0.5))
        XCTAssertEqual(fixture.startedReads, 2, "The requests during the read left no follow-up")
        fixture.answer(1, fixture.sample(0 ... 0.5))
        XCTAssertEqual(fixture.startedReads, 2)
        XCTAssertFalse(fixture.observation.hasObligation)
    }

    func test_anIneligibleSpreadKeepsTheObligationUntilItSettles() {
        let fixture = ObservationFixture()
        fixture.eligibility = .unsettled

        fixture.observation.request()
        XCTAssertEqual(fixture.reads.count, 0)
        XCTAssertTrue(fixture.observation.hasObligation)

        fixture.eligibility = .eligible(fixture.capability)
        fixture.observation.request()
        XCTAssertEqual(fixture.startedReads, 1)
    }

    /// A sample answered after an authoritative invalidation describes a view
    /// that may no longer be shown: it is discarded, and the obligation is read
    /// again rather than dropped.
    func test_aSampleAnsweredAfterAnInvalidationIsReadAgain() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.observation.invalidate()
        fixture.answer(0, fixture.sample(0 ... 0.25))

        XCTAssertEqual(fixture.accepted, [], "A sample from before the invalidation was accepted")
        XCTAssertEqual(fixture.startedReads, 2)
        fixture.answer(1, fixture.sample(0.25 ... 0.5))
        XCTAssertEqual(fixture.accepted.map(\.sample.range), [0.25 ... 0.5])
    }

    func test_aSampleAnsweredWhileTheSpreadIsNoLongerEligibleIsNotAccepted() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.eligibility = .unsettled
        fixture.answer(0, fixture.sample(0 ... 0.25))

        XCTAssertEqual(fixture.accepted, [])
        XCTAssertTrue(fixture.observation.hasObligation)
    }

    /// A bridge measuring under another capability than the spread was ready
    /// with disagrees with it; that fails closed instead of reading again.
    func test_aSampleOfAnotherCapabilityFailsClosed() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        let other = EPUBSpreadFrameCapability()
        fixture.answer(0, .sample(EPUBProgressionSample(capability: other, range: 0 ... 0.25)))

        XCTAssertEqual(fixture.accepted, [])
        XCTAssertEqual(fixture.observation.unavailability, .invalidProvenance)
        XCTAssertEqual(fixture.startedReads, 1, "The mismatched sample was read again")
        XCTAssertTrue(fixture.observation.hasObligation)
    }

    func test_anInvalidationRevokesTheAcceptedSample() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, fixture.sample(0 ... 0.25))
        XCTAssertNotNil(fixture.observation.currentObservation)

        fixture.observation.invalidate()

        XCTAssertNil(fixture.observation.currentObservation)
    }

    /// The stamp names the geometry: an equal range keeps it, even across an
    /// invalidation, and a changed one advances it.
    func test_theStampAdvancesOnlyForAChangedRange() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, fixture.sample(0 ... 0.25))
        fixture.observation.invalidate()
        fixture.observation.request()
        fixture.answer(1, fixture.sample(0 ... 0.25))
        fixture.observation.request()
        fixture.answer(2, fixture.sample(0.25 ... 0.5))

        let stamps = fixture.accepted.map(\.stamp)
        XCTAssertEqual(fixture.accepted.count, 3, "An equal sample was not reported")
        XCTAssertEqual(stamps[0], stamps[1], "An equal range advanced the stamp")
        XCTAssertNotEqual(stamps[1], stamps[2], "A changed range kept the stamp")
    }

    // MARK: - Hints

    /// Hints coalesce into one read at the end of a window that starts with the
    /// first of them; later hints neither extend nor restart it.
    func test_hintsCoalesceIntoOneReadAtTheEndOfAFixedWindow() {
        let fixture = ObservationFixture()

        fixture.observation.hint()
        fixture.deadlines.advance(by: .milliseconds(200))
        fixture.observation.hint()
        XCTAssertEqual(fixture.reads.count, 0, "A hint read before its window ended")

        fixture.deadlines.advance(by: .milliseconds(100))
        XCTAssertEqual(fixture.startedReads, 1, "A later hint extended the window")
        fixture.answer(0, fixture.sample(0 ... 0.25))
        fixture.deadlines.advance(by: .seconds(1))
        XCTAssertEqual(fixture.startedReads, 1, "A later hint opened a window of its own")
    }

    /// Hints arriving throughout a read start no second read, revoke no
    /// accepted sample, and do not keep a valid answer from publishing.
    func test_hintsDuringAReadNeitherRevokeTheSampleNorKeepItsAnswerFromPublishing() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, fixture.sample(0 ... 0.25))
        let accepted = fixture.observation.currentObservation
        fixture.observation.request()

        for _ in 0 ..< 3 {
            fixture.observation.hint()
            fixture.deadlines.advance(by: .milliseconds(150))
        }
        XCTAssertEqual(fixture.observation.currentObservation, accepted, "A hint revoked the accepted sample")
        XCTAssertEqual(fixture.startedReads, 2, "A hint started a read beside the outstanding one")
        fixture.answer(1, fixture.sample(0 ... 0.25))

        XCTAssertEqual(fixture.accepted.count, 2, "The answer did not publish")
        XCTAssertEqual(fixture.startedReads, 3, "The hints left no single follow-up read")
    }

    func test_hintsDoNotRestoreASpentRetry() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        fixture.observation.hint()
        fixture.deadlines.advance(by: EPUBLocationObservation.hintWindow)
        fixture.answer(1, .failed)

        XCTAssertEqual(fixture.observation.unavailability, .readFailed)
    }

    // MARK: - Native motion

    /// A settlement still reporting native motion waits one window instead of
    /// reading; a window that ends with the content still moving arms nothing
    /// further.
    func test_aSettlementDuringNativeMotionWaitsOutOneWindow() {
        let fixture = ObservationFixture()
        fixture.eligibility = .nativeMotion

        fixture.observation.request()
        XCTAssertEqual(fixture.reads.count, 0)
        fixture.eligibility = .eligible(fixture.capability)
        fixture.deadlines.advance(by: EPUBLocationObservation.hintWindow)
        XCTAssertEqual(fixture.startedReads, 1)

        let stillMoving = ObservationFixture()
        stillMoving.eligibility = .nativeMotion
        stillMoving.observation.request()
        stillMoving.deadlines.advance(by: EPUBLocationObservation.hintWindow)
        XCTAssertEqual(stillMoving.deadlines.armedCount, 0, "A window re-armed while the content moved")
        XCTAssertTrue(stillMoving.observation.hasObligation)
    }

    /// A settlement during native motion joins a hint window already open;
    /// a second window would leave one that a reset cannot cancel.
    func test_aSettlementDuringMotionJoinsAnOpenHintWindow() {
        let fixture = ObservationFixture()
        fixture.observation.hint()
        fixture.eligibility = .nativeMotion

        fixture.observation.request()
        XCTAssertEqual(fixture.deadlines.armedCount, 1, "The settlement opened a second window")

        fixture.observation.reset()
        fixture.eligibility = .eligible(fixture.capability)
        fixture.deadlines.advance(by: .seconds(1))
        XCTAssertEqual(fixture.reads.count, 0, "A window outlived the reset")
    }

    /// A freed slot is a wake-up, not a settlement: during native motion it
    /// arms no window, and the motion's own settlement asks later.
    func test_aSlotAvailableDuringNativeMotionArmsNoWindow() {
        let fixture = ObservationFixture()
        fixture.nextStart = .transportOccupied
        fixture.observation.request()
        fixture.eligibility = .nativeMotion

        fixture.observation.slotAvailable()

        XCTAssertEqual(fixture.deadlines.armedCount, 0, "A freed slot armed a window during motion")
        XCTAssertTrue(fixture.observation.hasObligation)
    }

    // MARK: - Physical occupancy

    func test_anOccupiedTransportKeepsTheObligationUntilTheSlotIsAvailable() {
        let fixture = ObservationFixture()
        fixture.nextStart = .transportOccupied

        fixture.observation.request()
        XCTAssertEqual(fixture.startedReads, 0)
        XCTAssertTrue(fixture.observation.hasObligation)

        fixture.observation.slotAvailable()
        XCTAssertEqual(fixture.startedReads, 1)
    }

    func test_anUnregisteredFrameKeepsTheObligationUntilARegistration() {
        let fixture = ObservationFixture()
        fixture.nextStart = .frameUnavailable

        fixture.observation.request()
        XCTAssertTrue(fixture.observation.hasObligation)

        fixture.observation.grant(.registration)
        XCTAssertEqual(fixture.startedReads, 1)
    }

    func test_aSlotAvailableWithoutAnObligationReadsNothing() {
        let fixture = ObservationFixture()

        fixture.observation.slotAvailable()

        XCTAssertEqual(fixture.reads.count, 0)
    }

    // MARK: - Recovery

    /// A returned transient failure keeps the obligation and retries once,
    /// exactly one gap later; a second failure waits unavailable with no timer.
    func test_aTransientFailureRetriesOnceThenWaitsUnavailable() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.answer(0, .failed)
        XCTAssertTrue(fixture.observation.hasObligation)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap - .milliseconds(1))
        XCTAssertEqual(fixture.startedReads, 1, "The retry did not wait out its gap")
        fixture.deadlines.advance(by: .milliseconds(1))
        XCTAssertEqual(fixture.startedReads, 2)

        fixture.answer(1, .unavailable)
        XCTAssertEqual(fixture.observation.unavailability, .readFailed)
        XCTAssertTrue(fixture.observation.hasObligation)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "An unavailable observation kept a timer")
        fixture.observation.request()
        fixture.observation.hint()
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "A hint armed a window while unavailable")
        fixture.deadlines.advance(by: .seconds(30))
        XCTAssertEqual(fixture.startedReads, 2, "An unavailable observation read again")
    }

    func test_aRecoveredRetryPublishes() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .unavailable)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        fixture.answer(1, fixture.sample(0 ... 0.25))

        XCTAssertEqual(fixture.accepted.map(\.sample.range), [0 ... 0.25])
        XCTAssertNil(fixture.observation.unavailability)
        fixture.observation.request()
        fixture.answer(2, .failed)
        XCTAssertNil(fixture.observation.unavailability, "The success left the next obligation without a retry")
    }

    /// A cancelled read lost its authority mid-flight; that is not a failure,
    /// and the obligation is read again at once.
    func test_aCancelledReadIsReadAgainWithoutSpendingTheRetry() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.answer(0, .cancelled)
        XCTAssertEqual(fixture.startedReads, 2)
        fixture.answer(1, .failed)

        XCTAssertNil(fixture.observation.unavailability)
    }

    func test_aStaleReadRestoresTheRetryOfTheNextFailure() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        fixture.observation.invalidate()
        fixture.answer(1, fixture.sample(0 ... 0.25))
        fixture.answer(2, .failed)

        XCTAssertNil(fixture.observation.unavailability, "A stale read spent the next obligation's retry")
    }

    /// A transient failure answered after an invalidation is as stale as a
    /// sample would be: the obligation is read again at once, its retry unspent.
    func test_aFailureAnsweredAfterAnInvalidationIsReadAgainWithItsRetryUnspent() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.observation.invalidate()
        fixture.answer(0, .failed)
        XCTAssertEqual(fixture.startedReads, 2, "The stale failure waited out a retry gap")

        fixture.answer(1, .failed)
        XCTAssertNil(fixture.observation.unavailability, "The stale failure spent the retry")
    }

    /// A grant while a read is outstanding makes that read the granted cycle's
    /// first attempt: its failure keeps the retry, bounded from the grant.
    func test_aGrantDuringAReadMakesItTheGrantedCyclesFirstAttempt() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.deadlines.advance(by: .seconds(4))
        let granted = fixture.deadlines.now
        fixture.observation.grant(.commandSettlement)
        XCTAssertEqual(fixture.startedReads, 1, "The grant started a read beside the outstanding one")

        fixture.answer(0, .failed)
        XCTAssertNil(fixture.observation.unavailability, "The grant spent the outstanding read's retry")
        fixture.eligibility = .unsettled
        fixture.deadlines.advance(by: .seconds(6))
        fixture.eligibility = .eligible(fixture.capability)
        fixture.observation.request()

        XCTAssertEqual(fixture.startedReads, 2)
        XCTAssertEqual(fixture.deadline(ofRead: 1), granted + EPUBLocationObservation.recoveryCeiling)
    }

    /// Both attempts of a cycle share one ceiling from the first dispatch, so a
    /// retry the spread could only start late gets what remains of it.
    func test_aRetryIsBoundedByTheCyclesCeiling() {
        let fixture = ObservationFixture()
        let start = fixture.deadlines.now
        fixture.observation.request()
        XCTAssertEqual(fixture.deadline(ofRead: 0), start + EPUBLocationObservation.readBudget)

        fixture.answer(0, .failed)
        fixture.eligibility = .unsettled
        fixture.deadlines.advance(by: .seconds(8))
        fixture.eligibility = .eligible(fixture.capability)
        fixture.observation.request()

        XCTAssertEqual(fixture.deadline(ofRead: 1), start + EPUBLocationObservation.recoveryCeiling)
    }

    /// A retry the spread could start only once the cycle's ceiling passed is
    /// never dispatched: the observation waits unavailable, still obliged.
    func test_aRetryEligibleOnlyAfterTheCeilingWaitsUnavailableWithoutReading() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)
        fixture.eligibility = .unsettled
        fixture.deadlines.advance(by: EPUBLocationObservation.recoveryCeiling)

        fixture.eligibility = .eligible(fixture.capability)
        fixture.observation.request()

        XCTAssertEqual(fixture.reads.count, 1, "A read was dispatched past the cycle's ceiling")
        XCTAssertEqual(fixture.observation.unavailability, .readFailed)
        XCTAssertTrue(fixture.observation.hasObligation)
    }

    func test_aRequestDuringTheRetryGapWaitsForIt() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)

        fixture.observation.request()
        fixture.observation.slotAvailable()
        XCTAssertEqual(fixture.startedReads, 1, "A request cut the retry gap short")

        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.startedReads, 2)
    }

    /// A start the transport refuses is not an attempt: the cycle's ceiling
    /// counts from the first read that actually started.
    func test_aRefusedStartDoesNotOpenTheCycle() {
        let fixture = ObservationFixture()
        fixture.nextStart = .transportOccupied
        fixture.observation.request()

        fixture.deadlines.advance(by: .seconds(8))
        fixture.observation.slotAvailable()

        XCTAssertEqual(
            fixture.deadline(ofRead: 1),
            fixture.deadlines.now + EPUBLocationObservation.readBudget,
            "The refused start shortened the read's deadline"
        )
    }

    func test_aReadRefusedForASpentDeadlineWaitsUnavailable() {
        let fixture = ObservationFixture()
        fixture.nextStart = .deadlinePassed

        fixture.observation.request()

        XCTAssertEqual(fixture.observation.unavailability, .readFailed)
        XCTAssertTrue(fixture.observation.hasObligation)
    }

    func test_aGrantEndsUnavailabilityAndReadsTheRetainedObligation() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        fixture.answer(1, .failed)
        XCTAssertEqual(fixture.observation.unavailability, .readFailed)

        fixture.observation.grant(.visibility)

        XCTAssertNil(fixture.observation.unavailability)
        XCTAssertEqual(fixture.startedReads, 3)
        fixture.answer(2, .failed)
        XCTAssertNil(fixture.observation.unavailability, "The grant did not restore the retry")
    }

    /// Invalid provenance fails closed without a retry; only a registration or
    /// a new document renews it.
    func test_invalidProvenanceWaitsForARegistration() {
        let fixture = ObservationFixture()
        fixture.observation.request()

        fixture.answer(0, .invalid)
        XCTAssertEqual(fixture.observation.unavailability, .invalidProvenance)
        fixture.deadlines.advance(by: .seconds(30))
        fixture.observation.grant(.commandSettlement)
        fixture.observation.grant(.visibility)
        fixture.observation.grant(.lateCompletion)
        XCTAssertEqual(fixture.startedReads, 1, "Provenance was renewed by something other than a registration")

        fixture.observation.grant(.registration)
        XCTAssertEqual(fixture.startedReads, 2)
    }

    /// A read that outlives its deadline keeps the slot: no replacement read
    /// or timer until its late completion grants a cycle.
    func test_anExpiredReadWaitsForItsLateCompletion() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.observation.hint()

        fixture.answer(0, .expired)
        XCTAssertEqual(fixture.observation.unavailability, .operationPending)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "The hint window outlived the expiry")
        fixture.observation.request()
        fixture.observation.hint()
        fixture.observation.slotAvailable()
        fixture.deadlines.advance(by: .seconds(30))
        XCTAssertEqual(fixture.startedReads, 1, "A read started beside the expired one")
        XCTAssertEqual(fixture.deadlines.armedCount, 0)

        fixture.observation.grant(.lateCompletion)
        XCTAssertEqual(fixture.startedReads, 2)
        fixture.answer(1, fixture.sample(0 ... 0.25))
        XCTAssertEqual(fixture.accepted.count, 1, "The late completion's recovery did not publish")
    }

    /// The hung call still holds the slot, so only its late completion ends
    /// the wait; every other grant leaves the observation unavailable.
    func test_onlyALateCompletionEndsAPendingOperation() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .expired)

        fixture.observation.grant(.visibility)
        fixture.observation.grant(.commandSettlement)
        fixture.observation.grant(.registration)

        XCTAssertEqual(fixture.observation.unavailability, .operationPending)
        XCTAssertEqual(fixture.startedReads, 1, "A grant read beside the hung call")
        fixture.observation.grant(.lateCompletion)
        XCTAssertNil(fixture.observation.unavailability)
        XCTAssertEqual(fixture.startedReads, 2)
    }

    // MARK: - Hand-off recovery

    /// A failed hand-off of the current document is re-issued once after the
    /// gap; a second failure waits unavailable until a grant re-issues it.
    func test_aFailedHandshakeIsReissuedOnceThenWaitsForAGrant() {
        let fixture = ObservationFixture()

        fixture.observation.handshakeDidFail(for: fixture.capability)
        XCTAssertEqual(fixture.reissued, [])
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.reissued, [fixture.capability])

        fixture.observation.hint()
        fixture.observation.handshakeDidFail(for: fixture.capability)
        XCTAssertTrue(fixture.observation.isRegistrationMissing)
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "The missing hand-off left the hint window armed")
        fixture.observation.request()
        fixture.observation.hint()
        XCTAssertEqual(fixture.deadlines.armedCount, 0, "A hint armed a window while the hand-off was missing")
        fixture.deadlines.advance(by: .seconds(30))
        XCTAssertEqual(fixture.reissued, [fixture.capability])
        XCTAssertEqual(fixture.reads.count, 0, "A read started while the hand-off was missing")

        fixture.nextStart = .frameUnavailable
        fixture.observation.grant(.visibility)
        XCTAssertEqual(fixture.reissued, [fixture.capability, fixture.capability])
        XCTAssertFalse(fixture.observation.isRegistrationMissing)

        // The grant restored the re-issue, so the next failure waits out the gap.
        fixture.observation.handshakeDidFail(for: fixture.capability)
        XCTAssertFalse(fixture.observation.isRegistrationMissing, "The grant left the re-issue spent")
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.reissued, [fixture.capability, fixture.capability, fixture.capability])
    }

    /// A hand-off failing twice while a hung read holds the slot keeps that
    /// read's reason: a grant re-issues the hand-off, and only the late
    /// completion reads again.
    func test_aMissingHandshakeKeepsAPendingOperation() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .expired)
        failHandshakeTwice(fixture)
        XCTAssertEqual(fixture.observation.unavailability, .operationPending)
        XCTAssertTrue(fixture.observation.isRegistrationMissing)

        fixture.observation.grant(.visibility)

        XCTAssertEqual(fixture.reissued, [fixture.capability, fixture.capability])
        XCTAssertFalse(fixture.observation.isRegistrationMissing)
        XCTAssertEqual(fixture.observation.unavailability, .operationPending, "The hand-off's grant ended the hung read's wait")
        XCTAssertEqual(fixture.startedReads, 1, "A read started beside the hung one")
        fixture.observation.grant(.lateCompletion)
        XCTAssertEqual(fixture.startedReads, 2)
    }

    /// A provenance failure outlives a missing hand-off's grant: only a
    /// registration renews authority.
    func test_aMissingHandshakeKeepsAProvenanceFailureForARegistration() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .invalid)
        failHandshakeTwice(fixture)

        fixture.observation.grant(.commandSettlement)

        XCTAssertEqual(fixture.reissued, [fixture.capability, fixture.capability])
        XCTAssertFalse(fixture.observation.isRegistrationMissing)
        XCTAssertEqual(fixture.observation.unavailability, .invalidProvenance, "The hand-off's grant renewed provenance")
        XCTAssertEqual(fixture.startedReads, 1)
        fixture.observation.grant(.registration)
        XCTAssertEqual(fixture.startedReads, 2)
    }

    /// A registration completes a missing hand-off and renews provenance at
    /// once, with nothing left to re-issue.
    func test_aRegistrationEndsAMissingHandshakeAndAProvenanceFailure() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .invalid)
        failHandshakeTwice(fixture)

        fixture.observation.grant(.registration)

        XCTAssertFalse(fixture.observation.isRegistrationMissing)
        XCTAssertNil(fixture.observation.unavailability)
        XCTAssertEqual(fixture.reissued, [fixture.capability], "A registration re-issued the hand-off it completed")
        XCTAssertEqual(fixture.startedReads, 2)
    }

    func test_aRegistrationRestoresTheHandshakeRetry() {
        let fixture = ObservationFixture()
        fixture.observation.handshakeDidFail(for: fixture.capability)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        fixture.observation.grant(.registration)
        fixture.observation.handshakeDidFail(for: fixture.capability)

        XCTAssertFalse(fixture.observation.isRegistrationMissing)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.reissued, [fixture.capability, fixture.capability])
    }

    /// Another document's failed hand-off re-issues nothing and leaves the
    /// current document's re-issue unspent.
    func test_aFailedHandshakeOfAnotherDocumentIsIgnored() {
        let fixture = ObservationFixture()

        fixture.observation.handshakeDidFail(for: EPUBSpreadFrameCapability())
        fixture.deadlines.advance(by: .seconds(1))
        XCTAssertEqual(fixture.reissued, [])

        fixture.observation.handshakeDidFail(for: fixture.capability)
        XCTAssertFalse(fixture.observation.isRegistrationMissing, "The other document's failure spent the re-issue")
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.reissued, [fixture.capability])
    }

    /// A registration ends the hand-off a pending re-issue was for, so the
    /// re-issue never runs.
    func test_aRegistrationCancelsAPendingHandshakeReissue() {
        let fixture = ObservationFixture()
        fixture.observation.handshakeDidFail(for: fixture.capability)

        fixture.observation.grant(.registration)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        XCTAssertEqual(fixture.reissued, [])
    }

    func test_aHandshakeReissueSkipsADocumentThatLostItsCapability() {
        let fixture = ObservationFixture()
        fixture.observation.handshakeDidFail(for: fixture.capability)

        fixture.documentCapability = nil
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        XCTAssertEqual(fixture.reissued, [])
    }

    /// A read failing while a hand-off re-issue waits does not cancel it.
    func test_aReadFailureKeepsThePendingHandshakeReissue() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.observation.handshakeDidFail(for: fixture.capability)

        fixture.answer(0, .invalid)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        XCTAssertEqual(fixture.reissued, [fixture.capability])
    }

    // MARK: - Replacement and teardown

    /// A new document drops the obligation, the sample and every timer; the
    /// previous document's read is ignored when it answers.
    func test_aResetDropsEverythingAndIgnoresTheOutstandingRead() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.observation.hint()
        fixture.observation.handshakeDidFail(for: fixture.capability)

        fixture.observation.reset()
        fixture.answer(0, fixture.sample(0 ... 0.25))
        fixture.deadlines.advance(by: .seconds(30))

        XCTAssertEqual(fixture.accepted, [])
        XCTAssertFalse(fixture.observation.hasObligation)
        XCTAssertEqual(fixture.deadlines.armedCount, 0)
        XCTAssertEqual(fixture.reissued, [])
        XCTAssertEqual(fixture.reads.count, 1)
    }

    /// The transport would refuse a read while the previous document's is
    /// outstanding; the scheduler still matches each answer to its own read
    /// rather than relying on that.
    func test_anAnswerFromBeforeAResetCannotSettleALaterRead() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.observation.reset()
        fixture.observation.request()

        fixture.answer(0, fixture.sample(0 ... 0.25))
        XCTAssertEqual(fixture.accepted, [], "The previous document's answer settled the new read")
        fixture.answer(1, fixture.sample(0.25 ... 0.5))
        XCTAssertEqual(fixture.accepted.map(\.sample.range), [0.25 ... 0.5])
    }

    /// A new document starts with its own retry: the previous document's
    /// failure does not spend it.
    func test_aResetRestoresTheReadRetry() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .failed)

        fixture.observation.reset()
        fixture.observation.request()
        fixture.answer(1, .failed)

        XCTAssertNil(fixture.observation.unavailability, "The previous document's failure spent the retry")
    }

    /// A new document's hand-off gets its own re-issue.
    func test_aResetRestoresTheHandshakeReissue() {
        let fixture = ObservationFixture()
        fixture.observation.handshakeDidFail(for: fixture.capability)
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)

        let next = EPUBSpreadFrameCapability()
        fixture.observation.reset()
        fixture.documentCapability = next
        fixture.observation.handshakeDidFail(for: next)

        XCTAssertFalse(fixture.observation.isRegistrationMissing, "The previous document's re-issue was counted")
        fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(fixture.reissued, [fixture.capability, next])
    }

    func test_aResetRenewsProvenance() {
        let fixture = ObservationFixture()
        fixture.observation.request()
        fixture.answer(0, .invalid)

        fixture.observation.reset()
        fixture.observation.request()

        XCTAssertEqual(fixture.startedReads, 2)
    }

    func test_anOutstandingReadDoesNotKeepTheObservationAlive() {
        var fixture: ObservationFixture? = ObservationFixture()
        fixture?.observation.request()
        let reads = fixture?.reads ?? []
        weak let weakObservation = fixture?.observation

        fixture = nil
        XCTAssertNil(weakObservation, "The outstanding read kept the observation alive")

        reads.first?.completion(.failed)
    }
}

// MARK: - Fixtures

/// Fails the current document's hand-off, lets its one re-issue run, then
/// fails that too.
@MainActor
private func failHandshakeTwice(_ fixture: ObservationFixture) {
    fixture.observation.handshakeDidFail(for: fixture.capability)
    fixture.deadlines.advance(by: EPUBLocationObservation.retryGap)
    fixture.observation.handshakeDidFail(for: fixture.capability)
}

/// An observation whose eligibility, read starts and answers the test sets.
@MainActor
private final class ObservationFixture {
    struct Read {
        let deadline: EPUBLocatorOperationDeadline
        let start: EPUBLocatorCommandBridge.ProgressionReadStart
        let completion: @MainActor (EPUBProgressionReadOutcome) -> Void
    }

    let deadlines = ManualDeadlines()
    let capability = EPUBSpreadFrameCapability()
    var eligibility: EPUBObservationEligibility
    var documentCapability: EPUBSpreadFrameCapability?
    /// What each read start reports from now on.
    var nextStart: EPUBLocatorCommandBridge.ProgressionReadStart = .started
    private(set) var reads: [Read] = []
    private(set) var reissued: [EPUBSpreadFrameCapability] = []
    private(set) var accepted: [EPUBAcceptedObservation] = []

    lazy var observation = EPUBLocationObservation(
        scheduler: deadlines.scheduler,
        eligibility: { [unowned self] in eligibility },
        documentCapability: { [unowned self] in documentCapability },
        read: { [unowned self] deadline, completion in
            let start = nextStart
            reads.append(Read(deadline: deadline, start: start, completion: completion))
            if start == .started {
                return .started
            }
            nextStart = .started
            return start
        },
        reissueHandshake: { [unowned self] in reissued.append($0) },
        onAccepted: { [unowned self] in accepted.append($0) }
    )

    init() {
        eligibility = .eligible(capability)
        documentCapability = capability
    }

    /// Reads that reached the transport.
    var startedReads: Int {
        reads.filter { $0.start == .started }.count
    }

    func sample(_ range: ClosedRange<Double>) -> EPUBProgressionReadOutcome {
        .sample(EPUBProgressionSample(capability: capability, range: range))
    }

    /// Answers the `index`th started read, failing rather than trapping when
    /// it never started.
    func answer(
        _ index: Int,
        _ outcome: EPUBProgressionReadOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let started = reads.filter { $0.start == .started }
        guard started.indices.contains(index) else {
            XCTFail("Read \(index) never started; \(started.count) did", file: file, line: line)
            return
        }
        started[index].completion(outcome)
    }

    /// The deadline the `index`th read, started or refused, was given.
    func deadline(ofRead index: Int) -> ContinuousClock.Instant? {
        reads.indices.contains(index) ? reads[index].deadline.expiresAt : nil
    }
}
