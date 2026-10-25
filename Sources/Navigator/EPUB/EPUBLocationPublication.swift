//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// A location and viewport computed for the navigator's current spread.
struct EPUBPublicationOutput {
    let locator: Locator?
    let viewport: NavigatorViewport
}

/// What a spread lets the navigator publish now.
struct EPUBSpreadPublicationInput: Equatable {
    let capability: EPUBSpreadFrameCapability
    /// The accepted observation's stamp of a reflowable spread; `nil` for fixed
    /// layout.
    let stamp: UInt64?
    /// The visible range of each reading-order index the spread shows.
    let progressions: [ReadingOrder.Index: ClosedRange<Double>]
}

/// What a spread's publishable inputs were captured from. A calculation is
/// current while the navigator's live key still equals the one it captured.
/// The capability names the spread too: every spread mints its own for each
/// document it loads.
struct EPUBPublicationKey: Equatable {
    let spreadIndex: Int
    let capability: EPUBSpreadFrameCapability
    /// The accepted observation's stamp of a reflowable spread; `nil` for fixed
    /// layout. Equal geometry keeps it, so an equal sample does not supersede a
    /// calculation already computing it.
    let stamp: UInt64?
}

/// A calculation and the check of whether it still describes what the
/// navigator shows.
struct EPUBPublicationCapture {
    /// Read at commit, with no suspension before the assignment it guards.
    let isCurrent: @MainActor () -> Bool
    /// Captures values and dependencies only, never the navigator or a spread.
    let calculate: @Sendable () async -> EPUBPublicationOutput
}

/// Publishes the navigator's location from current inputs only.
///
/// Calculations start only while the navigator is idle and no operation holds
/// publication; a request made meanwhile is retained and runs the moment both
/// end. One calculation
/// runs at a time and one obligation is retained until a current result
/// discharges it; requests made meanwhile coalesce into one follow-up. A
/// result commits only when the navigator has not left idle since it started
/// and its capture is still current, checked and assigned without suspending
/// in between. A calculation that outlives its deadline keeps the slot until it
/// actually exits: its result is discarded, and its exit lets the latest
/// obligation run.
///
/// It also keeps where a rebuild starts. Wherever a calculation could start,
/// it records the current spread's measured position, so a rebuild lands where
/// the reader moved even while the calculation that will publish it is still
/// running, and never behind what was published.
///
/// A caller about to save the position can wait for a commit still to come
/// (`awaitPendingCommit()`), bounded by `calculationBudget`.
@MainActor
final class EPUBLocationPublication {
    /// How long one calculation may take before its result can no longer commit.
    static let calculationBudget: Duration = .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)

    private struct Active {
        let id: Int
        let revision: UInt64
        let capture: EPUBPublicationCapture
        var task: Task<Void, Never>?
        var deadline: EPUBScheduledDeadline?
        var hasExpired = false
    }

    private let scheduler: EPUBDeadlineScheduler
    private let position: @MainActor () -> Locator?
    private let capture: @MainActor () -> EPUBPublicationCapture?
    private let commit: @MainActor (EPUBPublicationOutput) -> Void
    private var recordedLocation: Locator?

    /// Advanced by every `setIdle(false)` and `hold()`.
    private var revision: UInt64 = 0
    private var isIdle = false {
        didSet { commitWorkDidChange() }
    }

    /// Before its first settle the navigator is still opening at its initial
    /// location, so no navigation is in flight that a commit wait should cover.
    private var hasSettled = false
    private var holds = 0 {
        didSet { commitWorkDidChange() }
    }

    private var active: Active? {
        didSet { commitWorkDidChange() }
    }

    private var lastID = 0
    private(set) var hasObligation = false {
        didSet { commitWorkDidChange() }
    }

    /// What the current spread still owes, read by a commit wait. The
    /// navigator sets it when a wait starts.
    var spreadWork: @MainActor () -> EPUBSpreadLocationWork = { .idle }
    private var commitWaiters: [Int: CommitWaiter] = [:]
    private var lastWaiterID = 0
    private var isCommitWaitEvaluationScheduled = false

    /// Whether a calculation this publication started has not exited yet.
    var isCalculating: Bool {
        active != nil
    }

    /// A calculation outlived its deadline and still holds the slot.
    var isOperationPending: Bool {
        active?.hasExpired == true
    }

    /// - Parameters:
    ///   - initialLocation: where a rebuild starts until a position is recorded.
    ///   - position: where the current spread measured it shows, derived
    ///     without suspending, or `nil` while it has no current measurement.
    ///   - capture: the current spread's inputs, or `nil` while there is no
    ///     current spread or nothing current to read.
    ///   - commit: assigns a current result.
    init(
        scheduler: EPUBDeadlineScheduler,
        initialLocation: Locator?,
        position: @escaping @MainActor () -> Locator?,
        capture: @escaping @MainActor () -> EPUBPublicationCapture?,
        commit: @escaping @MainActor (EPUBPublicationOutput) -> Void
    ) {
        self.scheduler = scheduler
        recordedLocation = initialLocation
        self.position = position
        self.capture = capture
        self.commit = commit
    }

    /// Where a rebuild starts: records the current position where a
    /// calculation could start, then answers the last one recorded. So a
    /// rebuild before the rebuilt spread measures anything starts where the
    /// previous one did, and one before any measurement at the initial
    /// location.
    func rebuildLocation() -> Locator? {
        recordPosition()
        return recordedLocation
    }

    /// Only where a calculation could start: while the navigator navigates or
    /// an operation holds publication, the current spread can show a place
    /// that is not the result, such as a neighbour passed on the way or the
    /// approximate hop of a locator navigation.
    private func recordPosition() {
        guard isIdle, holds == 0, let current = position() else {
            return
        }
        recordedLocation = current
    }

    /// The navigator settled (`true`) or started navigating (`false`). Leaving
    /// idle keeps a calculation already running from committing, and keeps the
    /// obligation; settling runs retained work.
    func setIdle(_ idle: Bool) {
        isIdle = idle
        if idle {
            hasSettled = true
            attemptDispatch()
        } else {
            revision &+= 1
        }
    }

    /// Holds publication across an operation the navigator settles in the
    /// middle of, as a locator navigation does between its hop to a resource
    /// and its landing: what shows in between is not the operation's result.
    /// Like leaving idle, it keeps a calculation already running from
    /// committing.
    func hold() {
        holds += 1
        revision &+= 1
    }

    /// Ends one hold; the last runs retained work.
    func release() {
        guard holds > 0 else {
            return
        }
        holds -= 1
        attemptDispatch()
    }

    /// Asks for a publication, coalesced with any already retained.
    func request() {
        hasObligation = true
        attemptDispatch()
    }

    /// Records the position first, whether or not a calculation starts, so
    /// what a calculation publishes has always been recorded.
    private func attemptDispatch() {
        recordPosition()
        guard hasObligation, isIdle, holds == 0, active == nil, let capture = capture() else {
            return
        }
        lastID += 1
        let id = lastID
        // The calculation carries the obligation; a request while it runs
        // retains a follow-up.
        hasObligation = false
        active = Active(id: id, revision: revision, capture: capture)
        let calculate = capture.calculate
        active?.task = Task { @MainActor [weak self] in
            let output = await calculate()
            self?.calculationDidExit(id, with: output)
        }
        active?.deadline = scheduler.schedule(scheduler.now() + Self.calculationBudget) { [weak self] in
            self?.calculationDidExpire(id)
        }
    }

    private func calculationDidExpire(_ id: Int) {
        guard active?.id == id else {
            return
        }
        active?.hasExpired = true
        active?.deadline = nil
        active?.task?.cancel()
        hasObligation = true
    }

    // MARK: - Pending commit wait

    /// Waits until no commit is still to come, and answers whether
    /// `calculationBudget` passed first. Returns at once when nothing would
    /// publish before a named event. A state change, the deadline or the
    /// caller's cancellation resumes it, never WebKit, so a call stuck there
    /// cannot hold it past the deadline.
    func awaitPendingCommit() async -> Bool {
        guard isCommitPending else {
            return false
        }
        lastWaiterID += 1
        let id = lastWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = CommitWaiter(continuation)
                commitWaiters[id] = waiter
                // The suspended call keeps the publication alive, so this fires.
                waiter.deadline = scheduler.schedule(scheduler.now() + Self.calculationBudget) { [weak self] in
                    self?.commitWaiters.removeValue(forKey: id)?.resume(deadlinePassed: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.commitWaiters.removeValue(forKey: id)?.resume(deadlinePassed: false)
            }
        }
    }

    /// The current spread's work changed.
    func spreadWorkDidChange() {
        commitWorkDidChange()
    }

    /// A commit is still to come: an obligation, a calculation, a hold, a
    /// navigation since the first settle, or the spread's own work.
    private var isCommitPending: Bool {
        // An expired calculation may never exit, and nothing publishes until
        // it does (ADR-0195, the navigator slot).
        guard !isOperationPending else {
            return false
        }
        switch spreadWork() {
        case .blocked:
            return false
        case .working:
            return true
        case .idle:
            return hasObligation || active != nil || holds > 0 || (hasSettled && !isIdle)
        }
    }

    /// Evaluates the waits once the current main-actor work ends: a method
    /// passes through intermediate states between its assignments, such as
    /// `calculationDidExit` freeing the slot before it commits.
    private func commitWorkDidChange() {
        guard !commitWaiters.isEmpty, !isCommitWaitEvaluationScheduled else {
            return
        }
        isCommitWaitEvaluationScheduled = true
        Task { @MainActor [weak self] in
            self?.evaluateCommitWaits()
        }
    }

    private func evaluateCommitWaits() {
        isCommitWaitEvaluationScheduled = false
        guard !isCommitPending else {
            return
        }
        let waiters = commitWaiters.values
        commitWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(deadlinePassed: false)
        }
    }

    private func calculationDidExit(_ id: Int, with output: EPUBPublicationOutput) {
        guard let finished = active, finished.id == id else {
            return
        }
        active = nil
        finished.deadline?.cancel()
        if !finished.hasExpired, finished.revision == revision, finished.capture.isCurrent() {
            commit(output)
        } else {
            hasObligation = true
        }
        attemptDispatch()
    }
}

/// One caller waiting for a pending commit. Only the call that removes it
/// from the publication's waiters resumes it, so it resumes once.
@MainActor
private final class CommitWaiter {
    var deadline: EPUBScheduledDeadline?
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(deadlinePassed: Bool) {
        deadline?.cancel()
        continuation.resume(returning: deadlinePassed)
    }
}
