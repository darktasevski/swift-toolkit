//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Gives locator navigation latest-request-wins semantics without overlapping
/// the navigator state machine.
@MainActor
final class EPUBLocatorNavigationTaskQueue {
    typealias Operation = @MainActor () async -> LocatorNavigationOutcome

    /// Bounds how long a superseding request waits for its cancelled
    /// predecessor to acknowledge before proceeding regardless. A predecessor
    /// that observes cancellation returns well within this budget; the bound
    /// only backstops a predecessor that never yields, so the successor can
    /// never stall behind unresponsive work.
    typealias PredecessorAcknowledgement = @MainActor () async -> Void

    /// Positively cancels the predecessor's in-flight bridge command. A
    /// superseding request runs this — a `readerLocatorCommands.invalidate(token)`
    /// round-trip into the predecessor's selected frame and content world — so
    /// the predecessor's suspended `callAsyncJavaScript` aborts and returns
    /// promptly, instead of stalling until its JavaScript frame timeout. It is
    /// awaited BEFORE the bounded predecessor acknowledgement (Design Y).
    typealias CancellationRelay = @MainActor () async -> Void

    /// Bounds the successor's wait for a cancelled predecessor to acknowledge.
    /// Frozen as `predecessorAcknowledgementBudgetMilliseconds` in
    /// `locatorNavigationBudgets` (the checked budget manifest,
    /// `docs/benchmarks/render-faithful-v7-budgets.json`); it is a
    /// convention-chosen supersession backstop, so oldest-device graduation is
    /// still pending for that family.
    static let predecessorAcknowledgementBudget: Duration = .seconds(1)

    private struct Entry {
        let id: UUID
        let task: Task<LocatorNavigationOutcome, Never>
        /// The active request's relay. `cancelPending()` fires it so a
        /// view-lifecycle teardown aborts the suspended bridge command in its
        /// own frame, exactly as a superseding request does. The relay is
        /// position-independent ("cancel whatever is in flight now"), so the
        /// same closure serves supersession and teardown.
        let cancellationRelay: CancellationRelay
    }

    /// Resumes its continuation at most once regardless of how many racers
    /// report completion. MainActor isolation makes the guard race-free. The
    /// continuation attaches after creation so ambient cancellation — which
    /// fires the gate before the continuation exists — is handled: a `fire()`
    /// that lands before `attach(_:)` resumes the continuation the moment it
    /// arrives.
    @MainActor
    private final class AcknowledgementGate {
        private var resumed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func attach(_ continuation: CheckedContinuation<Void, Never>) {
            guard !resumed else {
                continuation.resume()
                return
            }
            self.continuation = continuation
        }

        func fire() {
            guard !resumed else { return }
            resumed = true
            continuation?.resume()
            continuation = nil
        }
    }

    private let predecessorAcknowledgement: PredecessorAcknowledgement
    private var entry: Entry?

    init(
        predecessorAcknowledgement: @escaping PredecessorAcknowledgement = {
            try? await ContinuousClock().sleep(
                for: EPUBLocatorNavigationTaskQueue.predecessorAcknowledgementBudget
            )
        }
    ) {
        self.predecessorAcknowledgement = predecessorAcknowledgement
    }

    func run(
        _ operation: @escaping Operation,
        cancellationRelay: @escaping CancellationRelay = {}
    ) async -> LocatorNavigationOutcome {
        let predecessor = entry?.task
        predecessor?.cancel()

        let id = UUID()
        let acknowledgement = predecessorAcknowledgement
        let task = Task<LocatorNavigationOutcome, Never> { @MainActor [weak self] in
            if let predecessor {
                // Signal the predecessor's in-flight bridge to abort before
                // waiting for it to acknowledge (Design Y: relay, then ack).
                await cancellationRelay()
                await Self.awaitPredecessorAcknowledgement(
                    predecessor,
                    budget: acknowledgement
                )
            }
            guard !Task.isCancelled else {
                self?.removeEntry(with: id)
                return LocatorNavigationOutcome.cancelled
            }

            let outcome = await operation()
            let finalOutcome: LocatorNavigationOutcome = Task.isCancelled ? .cancelled : outcome
            self?.removeEntry(with: id)
            return finalOutcome
        }
        entry = Entry(id: id, task: task, cancellationRelay: cancellationRelay)

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits for the cancelled predecessor to finish, bounded by the
    /// acknowledgement budget. Whichever of predecessor-completion, budget
    /// elapse, or the successor's own cancellation happens first releases the
    /// successor; the losers are abandoned. A predecessor that never observes
    /// cancellation cannot block the successor past the budget, and a successor
    /// that is itself superseded (or the caller cancels) returns promptly
    /// instead of waiting out either racer.
    @MainActor
    private static func awaitPredecessorAcknowledgement(
        _ predecessor: Task<LocatorNavigationOutcome, Never>,
        budget: @escaping PredecessorAcknowledgement
    ) async {
        let gate = AcknowledgementGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                Task { @MainActor in
                    _ = await predecessor.value
                    gate.fire()
                }
                Task { @MainActor in
                    await budget()
                    gate.fire()
                }
            }
        } onCancel: {
            Task { @MainActor in gate.fire() }
        }
    }

    /// Drains the active navigation with an explicit `.cancelled` terminal
    /// outcome. A view-lifecycle teardown that rebuilds the spreads
    /// (settings/layout reload, generic reload, or a process-termination
    /// rebuild) invalidates any in-flight precise landing: the target geometry
    /// no longer exists. Cancelling the task synchronously gives the request its
    /// terminal outcome before the spreads are torn down, and firing the stored
    /// relay positively aborts the suspended bridge command in its own frame
    /// rather than leaving it to self-error on the vanishing webview. Idle when
    /// no navigation is in flight.
    func cancelPending() {
        guard let entry else { return }
        entry.task.cancel()
        let relay = entry.cancellationRelay
        Task { @MainActor in await relay() }
    }

    private func removeEntry(with id: UUID) {
        guard entry?.id == id else { return }
        entry = nil
    }
}
