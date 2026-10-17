//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreFoundation
import Foundation

/// A measured viewport range of one reflowable document, tagged with the frame
/// capability that document held when it answered.
struct EPUBProgressionSample: Equatable, Sendable {
    let capability: EPUBSpreadFrameCapability
    let range: ClosedRange<Double>
}

/// The closed result of one progression read. These are observation results,
/// not navigation outcomes: none of them is a `PageTurnOutcome`.
enum EPUBProgressionReadOutcome: Equatable, Sendable {
    /// The selected frame measured its viewport under the current capability.
    case sample(EPUBProgressionSample)
    /// The document answered without a measurement: its geometry could not be
    /// measured, or it no longer held the capability. Transient.
    case unavailable
    /// The answer was malformed or named another capability. Fails closed.
    case invalid
    /// The logical deadline passed before WebKit answered. The call still
    /// occupies the transport until it actually completes.
    case expired
    /// The document, its capability or the selected frame changed before the
    /// answer arrived.
    case cancelled
    /// WebKit returned an error.
    case failed

    /// Decodes a `readProgression` answer for the document issued `capability`.
    /// A sample has exactly `capability`, `first` and `last`; the capability must
    /// be the expected one, and both ends ordered, finite, non-Boolean numbers
    /// in 0...1.
    static func decoding(
        _ value: Any,
        expecting capability: EPUBSpreadFrameCapability
    ) -> EPUBProgressionReadOutcome {
        // The script answers `null` when it cannot measure or no longer holds
        // the capability; WebKit delivers that as `NSNull`.
        if value is NSNull {
            return .unavailable
        }
        guard
            let payload = value as? [String: Any],
            Set(payload.keys) == ["capability", "first", "last"],
            payload["capability"] as? String == capability.id.uuidString,
            let first = unitInterval(payload["first"]),
            let last = unitInterval(payload["last"]),
            first <= last
        else {
            return .invalid
        }
        return .sample(EPUBProgressionSample(capability: capability, range: first ... last))
    }

    private static func unitInterval(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard (0 ... 1).contains(double) else {
            return nil
        }
        return double
    }
}

/// Why location observation waits for a recovery grant instead of reading.
enum EPUBObservationUnavailability: Equatable, Sendable {
    /// A read outlived its deadline and still holds the transport.
    case operationPending
    /// A read failed and so did its one retry, or the recovery cycle's
    /// ceiling passed before an attempt could start.
    case readFailed
    /// A read answered malformed or for a capability it was not dispatched
    /// under.
    case invalidProvenance
    /// The capability hand-off failed, and so did its one re-issue.
    case registrationMissing
}

/// What the spread's live state allows observation to do right now.
enum EPUBObservationEligibility: Equatable, Sendable {
    /// Ready, at rest and commanded by nothing: a read of `capability` may start.
    case eligible(EPUBSpreadFrameCapability)
    /// The user is dragging or the content is decelerating.
    case nativeMotion
    /// Readiness is not ready, or a position command is in flight. Each
    /// settles with a request of its own.
    case unsettled
}

/// What grants one recovery cycle, and so ends an unavailability.
enum EPUBObservationGrant: Equatable, Sendable {
    /// The owning scene became active again.
    case visibility
    /// The latest position command settled.
    case commandSettlement
    /// A frame registered under the current capability.
    case registration
    /// A transport call that outlived its deadline, a read or a hand-off
    /// injection, finally completed.
    case lateCompletion

    /// Only the late completion frees a hung call's slot, and only renewed
    /// authority clears a provenance failure.
    fileprivate func ends(_ unavailability: EPUBObservationUnavailability) -> Bool {
        switch unavailability {
        case .operationPending:
            self == .lateCompletion
        case .invalidProvenance:
            self == .registration
        case .readFailed, .registrationMissing:
            true
        }
    }
}

/// An accepted sample and its geometry stamp. The stamp changes only when the
/// measured range does, so an equal sample does not invalidate work already
/// computed from it.
struct EPUBAcceptedObservation: Equatable, Sendable {
    let sample: EPUBProgressionSample
    let stamp: UInt64
}

/// Schedules the reflowable progression reads that report a settled location.
///
/// One read is outstanding at a time and one measurement obligation is
/// retained until a current sample discharges it. Authoritative invalidations
/// (readiness, native motion, command admission) revoke the accepted sample;
/// page hints only ask for a measurement, coalesced into one fixed 300 ms
/// window. A returned transient failure gets one retry after 300 ms, within
/// 10,300 ms of the first attempt; after that, or after a read outlives its
/// deadline or answers with invalid provenance, observation waits unavailable,
/// with no read timer and ignoring hints, for a grant. Physical occupancy
/// stays the transport's: a refused start keeps the obligation until the slot
/// or a registration frees.
@MainActor
final class EPUBLocationObservation {
    typealias Read = @MainActor (
        _ deadline: EPUBLocatorOperationDeadline,
        _ completion: @escaping @MainActor (EPUBProgressionReadOutcome) -> Void
    ) -> EPUBLocatorCommandBridge.ProgressionReadStart

    /// How long one read may take: the bridge's operation ceiling.
    static let readBudget: Duration = .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
    /// The wait between a returned transient failure and its retry, and
    /// between a failed hand-off and its re-issue.
    static let retryGap: Duration = .milliseconds(300)
    /// The fixed window that coalesces hints, and that a settlement still
    /// reporting native motion waits out.
    static let hintWindow: Duration = .milliseconds(300)
    /// A recovery cycle's bound from its first dispatch: two full reads and
    /// the gap between them.
    static let recoveryCeiling: Duration = readBudget * 2 + retryGap

    private struct ActiveRead {
        let id: Int
        let authorityRevision: UInt64
        let capability: EPUBSpreadFrameCapability
    }

    /// Consecutive transient failures of one obligation: the first attempt and
    /// at most one retry, both bounded by the ceiling from the first dispatch.
    private struct RecoveryCycle {
        var firstDispatch: ContinuousClock.Instant?
        var retryUsed = false
    }

    private let scheduler: EPUBDeadlineScheduler
    private let eligibility: @MainActor () -> EPUBObservationEligibility
    private let documentCapability: @MainActor () -> EPUBSpreadFrameCapability?
    private let read: Read
    private let reissueHandshake: @MainActor (EPUBSpreadFrameCapability) -> Void
    private let onAccepted: @MainActor (EPUBAcceptedObservation) -> Void

    private var authorityRevision: UInt64 = 0
    private(set) var hasObligation = false
    private var active: ActiveRead?
    private var lastReadID = 0
    private var hintWindowDeadline: EPUBScheduledDeadline?
    private var retryDeadline: EPUBScheduledDeadline?
    private var cycle = RecoveryCycle()
    private var handshakeRetryUsed = false
    private var handshakeRetryDeadline: EPUBScheduledDeadline?
    private var lastStamp: UInt64 = 0
    private var latestAccepted: EPUBAcceptedObservation?

    private(set) var unavailability: EPUBObservationUnavailability?
    /// The accepted sample, until an authoritative invalidation revokes it.
    private(set) var currentObservation: EPUBAcceptedObservation?

    /// - Parameters:
    ///   - eligibility: read from the live spread at every decision; never cached.
    ///   - documentCapability: the capability of the current document, ready or not.
    ///   - read: starts one bridge read, calling `completion` at most once.
    ///   - reissueHandshake: hands `capability` to the document again.
    ///   - onAccepted: told of each accepted sample, equal ones included.
    init(
        scheduler: EPUBDeadlineScheduler,
        eligibility: @escaping @MainActor () -> EPUBObservationEligibility,
        documentCapability: @escaping @MainActor () -> EPUBSpreadFrameCapability?,
        read: @escaping Read,
        reissueHandshake: @escaping @MainActor (EPUBSpreadFrameCapability) -> Void,
        onAccepted: @escaping @MainActor (EPUBAcceptedObservation) -> Void
    ) {
        self.scheduler = scheduler
        self.eligibility = eligibility
        self.documentCapability = documentCapability
        self.read = read
        self.reissueHandshake = reissueHandshake
        self.onAccepted = onAccepted
    }

    // MARK: - Signals

    /// An authoritative change of what the document shows. Keeps the
    /// obligation; a read already outstanding can no longer be accepted.
    func invalidate() {
        authorityRevision &+= 1
        currentObservation = nil
    }

    /// An authoritative settlement asks for a measurement. It bypasses the hint
    /// window unless native motion is still reported, when it waits one window.
    func request() {
        hasObligation = true
        attemptDispatch(waitingOutNativeMotion: true)
    }

    /// A page hint asks for one measurement at the end of a fixed window that
    /// later hints neither extend nor restart. Ignored while unavailable.
    func hint() {
        guard hintWindowDeadline == nil, unavailability == nil else {
            return
        }
        armHintWindow()
    }

    /// The transport is free: retained work may take it.
    func slotAvailable() {
        attemptDispatch(waitingOutNativeMotion: false)
    }

    /// Grants one recovery cycle and asks for a measurement. It never bypasses
    /// an occupied transport, and ends only an unavailability it can resolve.
    /// A read already outstanding becomes the granted cycle's first attempt,
    /// so that cycle starts now. While the hand-off is `.registrationMissing`,
    /// any grant but the registration itself re-issues it.
    func grant(_ grant: EPUBObservationGrant) {
        if unavailability == .registrationMissing, grant != .registration,
           let capability = documentCapability()
        {
            handshakeRetryUsed = false
            reissueHandshake(capability)
        }
        if grant == .registration {
            handshakeRetryUsed = false
            handshakeRetryDeadline?.cancel()
            handshakeRetryDeadline = nil
        }
        if unavailability.map({ grant.ends($0) }) ?? true {
            unavailability = nil
            cycle = RecoveryCycle(firstDispatch: active == nil ? nil : scheduler.now())
        }
        request()
    }

    /// The hand-off of `capability` ended without a registration. The current
    /// document's gets one re-issue after the retry gap; a second failure waits
    /// unavailable for a grant.
    func handshakeDidFail(for capability: EPUBSpreadFrameCapability) {
        guard capability == documentCapability() else {
            return
        }
        guard !handshakeRetryUsed else {
            becomeUnavailable(.registrationMissing)
            return
        }
        handshakeRetryUsed = true
        handshakeRetryDeadline = scheduler.schedule(scheduler.now() + Self.retryGap) { [weak self] in
            guard let self else { return }
            handshakeRetryDeadline = nil
            guard documentCapability() == capability else { return }
            reissueHandshake(capability)
        }
    }

    /// A new document, or teardown: drops the obligation, the accepted sample
    /// and every timer. An outstanding read still occupies the transport until
    /// it actually completes; its answer is ignored.
    func reset() {
        authorityRevision &+= 1
        hasObligation = false
        active = nil
        cancelReadTimers()
        handshakeRetryDeadline?.cancel()
        handshakeRetryDeadline = nil
        cycle = RecoveryCycle()
        handshakeRetryUsed = false
        unavailability = nil
        currentObservation = nil
        latestAccepted = nil
    }

    // MARK: - Dispatch

    private func armHintWindow() {
        hintWindowDeadline = scheduler.schedule(scheduler.now() + Self.hintWindow) { [weak self] in
            guard let self else { return }
            hintWindowDeadline = nil
            hasObligation = true
            attemptDispatch(waitingOutNativeMotion: false)
        }
    }

    private func attemptDispatch(waitingOutNativeMotion: Bool) {
        guard
            hasObligation,
            active == nil,
            unavailability == nil,
            retryDeadline == nil
        else {
            return
        }
        switch eligibility() {
        case let .eligible(capability):
            dispatch(capability)
        case .nativeMotion:
            if waitingOutNativeMotion, hintWindowDeadline == nil {
                armHintWindow()
            }
        case .unsettled:
            break
        }
    }

    private func dispatch(_ capability: EPUBSpreadFrameCapability) {
        let now = scheduler.now()
        let previousCycle = cycle
        let firstDispatch = cycle.firstDispatch ?? now
        let deadline = EPUBLocatorOperationDeadline(expiringAt: min(
            now + Self.readBudget,
            firstDispatch + Self.recoveryCeiling
        ))
        // A retry the spread could only start after the cycle's ceiling.
        guard !deadline.hasExpired(at: now) else {
            becomeUnavailable(.readFailed)
            return
        }
        cycle.firstDispatch = firstDispatch
        lastReadID += 1
        let id = lastReadID
        active = ActiveRead(id: id, authorityRevision: authorityRevision, capability: capability)
        // The read carries the obligation; a request while it runs retains a
        // follow-up.
        hasObligation = false
        let start = read(deadline) { [weak self] outcome in
            self?.readDidFinish(id, with: outcome)
        }
        guard start != .started else {
            return
        }
        active = nil
        hasObligation = true
        cycle = previousCycle
        if start == .deadlinePassed {
            becomeUnavailable(.readFailed)
        }
    }

    private func readDidFinish(_ id: Int, with outcome: EPUBProgressionReadOutcome) {
        guard let read = active, read.id == id else {
            return
        }
        active = nil
        switch outcome {
        case let .sample(sample):
            // The bridge measured under another capability than the spread
            // was ready with: the two disagree, which a retry cannot fix.
            guard sample.capability == read.capability else {
                hasObligation = true
                becomeUnavailable(.invalidProvenance)
                return
            }
            guard
                read.authorityRevision == authorityRevision,
                eligibility() == .eligible(read.capability)
            else {
                restartAfterStaleRead()
                return
            }
            accept(sample)
        case .cancelled:
            restartAfterStaleRead()
        case .unavailable, .failed:
            guard read.authorityRevision == authorityRevision else {
                restartAfterStaleRead()
                return
            }
            hasObligation = true
            retryOrGiveUp()
        case .invalid:
            hasObligation = true
            becomeUnavailable(.invalidProvenance)
        case .expired:
            hasObligation = true
            becomeUnavailable(.operationPending)
        }
    }

    /// Authority changed under the read, so its answer, success or transient
    /// failure, says nothing about what is shown now. That is not a failure:
    /// the cycle restarts and the obligation is tried again when eligible.
    private func restartAfterStaleRead() {
        hasObligation = true
        cycle = RecoveryCycle()
        attemptDispatch(waitingOutNativeMotion: false)
    }

    /// The retry's own dispatch applies the cycle's ceiling.
    private func retryOrGiveUp() {
        guard !cycle.retryUsed else {
            becomeUnavailable(.readFailed)
            return
        }
        cycle.retryUsed = true
        retryDeadline = scheduler.schedule(scheduler.now() + Self.retryGap) { [weak self] in
            guard let self else { return }
            retryDeadline = nil
            attemptDispatch(waitingOutNativeMotion: false)
        }
    }

    private func accept(_ sample: EPUBProgressionSample) {
        let stamp: UInt64
        if let latestAccepted, latestAccepted.sample == sample {
            stamp = latestAccepted.stamp
        } else {
            lastStamp &+= 1
            stamp = lastStamp
        }
        let accepted = EPUBAcceptedObservation(sample: sample, stamp: stamp)
        latestAccepted = accepted
        currentObservation = accepted
        cycle = RecoveryCycle()
        onAccepted(accepted)
        attemptDispatch(waitingOutNativeMotion: false)
    }

    /// Stops the read timers; a pending hand-off re-issue is not a read and
    /// still runs.
    private func becomeUnavailable(_ reason: EPUBObservationUnavailability) {
        unavailability = reason
        cancelReadTimers()
    }

    private func cancelReadTimers() {
        hintWindowDeadline?.cancel()
        hintWindowDeadline = nil
        retryDeadline?.cancel()
        retryDeadline = nil
    }
}
