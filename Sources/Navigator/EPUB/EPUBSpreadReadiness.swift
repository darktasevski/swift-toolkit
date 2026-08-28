//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Replays the newest value when it changes while an asynchronous mutation is
/// in flight. The caller remains responsible for serializing separate
/// `applyLatest` invocations.
@MainActor
final class EPUBLatestMutation<Value> {
    private(set) var latestValue: Value
    private var revision: UInt64 = 0

    init(initialValue: Value) {
        latestValue = initialValue
    }

    func update(_ value: Value) {
        latestValue = value
        revision &+= 1
    }

    func applyLatest(
        _ operation: @MainActor (Value) async -> Bool
    ) async -> Bool {
        while !Task.isCancelled {
            let appliedRevision = revision
            let value = latestValue
            guard await operation(value), !Task.isCancelled else {
                return false
            }
            if appliedRevision == revision {
                return true
            }
        }
        return false
    }
}

/// Opaque identity for the frame document accepted by a spread generation.
struct EPUBSpreadFrameCapability: Equatable, Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Owns the lifecycle of one spread's render generations and position writers.
///
/// Document availability is intentionally distinct from command readiness. The
/// former lets initialization evaluate scripts without waiting on itself; the
/// latter is published only after every generation-bound writer releases its
/// lease.
@MainActor
final class EPUBSpreadReadiness {
    typealias Generation = UInt64

    /// One non-resetting budget shared by stylesheet, font and geometry
    /// stabilization during spread initialization.
    static let initializationStabilityBudgetMilliseconds = 5000

    /// Bounds controller waits after a page object is installed but before its
    /// exact render generation publishes command readiness.
    static let commandReadinessBudget: Duration = .seconds(2)

    enum State: Equatable, Sendable {
        case unavailable(generation: Generation)
        case loading(generation: Generation)
        case initializing(generation: Generation, activeWriterLeases: Int)
        case ready(generation: Generation, frameCapability: EPUBSpreadFrameCapability)
        case failed(generation: Generation)

        var generation: Generation {
            switch self {
            case let .unavailable(generation),
                 let .loading(generation),
                 let .initializing(generation, _),
                 let .ready(generation, _),
                 let .failed(generation):
                return generation
            }
        }
    }

    struct WriterLease: Equatable, Hashable, Sendable {
        let generation: Generation
        fileprivate let id: UUID
    }

    enum WaitOutcome: Equatable, Sendable {
        case documentAvailable(generation: Generation)
        case ready(generation: Generation, frameCapability: EPUBSpreadFrameCapability)
        case invalidated
        case cancelled
        case timedOut
        case failed(generation: Generation)
    }

    enum InitializationOutcome: Equatable, Sendable {
        case succeeded
        case failed
    }

    enum MutationOutcome: Equatable, Sendable {
        case succeeded
        case superseded
        case failed
    }

    private enum WaitTarget {
        case documentAvailability
        case commandReadiness
    }

    private struct Waiter {
        let generation: Generation
        let target: WaitTarget
        let continuation: CheckedContinuation<WaitOutcome, Never>
    }

    private(set) var state: State = .unavailable(generation: 0)

    private var activeWriterLeaseIDs: Set<UUID> = []
    private var initializingFrameCapability: EPUBSpreadFrameCapability?
    /// The monotonic source every bounded wait below sleeps on. Injected so a test
    /// can drive a readiness deadline without waiting out the real budget.
    private let clock: EPUBMonotonicClock
    private var waiters: [UUID: Waiter] = [:]

    init(clock: EPUBMonotonicClock = .continuous) {
        self.clock = clock
    }

    var generation: Generation {
        state.generation
    }

    /// The frame-document capability currently owning the lifecycle, across
    /// BOTH phases a live document can be in: `.ready`, and `.initializing`
    /// when a same-document mutation (position/layout writer) retains the
    /// capability while advancing the generation. Nil once the document is
    /// gone — replacement load, invalidation, or failure — so "is this exact
    /// document still current?" is answerable independently of generation
    /// arithmetic.
    var currentFrameCapability: EPUBSpreadFrameCapability? {
        switch state {
        case let .ready(_, frameCapability):
            return frameCapability
        case .initializing:
            return initializingFrameCapability
        case .unavailable, .loading, .failed:
            return nil
        }
    }

    var isCommandReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    /// Starts a replacement document load and invalidates all older work.
    @discardableResult
    func beginLoading() -> Generation {
        let generation = nextGeneration()
        drainWaiters(with: .invalidated)
        activeWriterLeaseIDs.removeAll()
        initializingFrameCapability = nil
        state = .loading(generation: generation)
        return generation
    }

    /// Makes the document available to internal initialization and acquires
    /// the root initialization writer before the caller can suspend.
    func beginInitialization(
        for generation: Generation,
        frameCapability: EPUBSpreadFrameCapability
    ) -> WriterLease? {
        guard case .loading(generation) = state else {
            return nil
        }

        let lease = WriterLease(generation: generation, id: UUID())
        activeWriterLeaseIDs = [lease.id]
        initializingFrameCapability = frameCapability
        state = .initializing(generation: generation, activeWriterLeases: 1)
        resumeEligibleWaiters()
        return lease
    }

    /// Joins an initialization generation as an additional position or layout
    /// writer. Callers acquire this synchronously before their first await.
    func acquireWriterLease(for generation: Generation) -> WriterLease? {
        guard case .initializing(generation, _) = state else {
            return nil
        }

        let lease = WriterLease(generation: generation, id: UUID())
        activeWriterLeaseIDs.insert(lease.id)
        state = .initializing(
            generation: generation,
            activeWriterLeases: activeWriterLeaseIDs.count
        )
        return lease
    }

    /// Starts a same-document geometry or position mutation in a new render
    /// generation while retaining the current frame-document capability.
    func beginMutation() -> WriterLease? {
        guard case let .ready(_, frameCapability) = state else {
            return nil
        }

        let generation = nextGeneration()
        drainWaiters(with: .invalidated)
        let lease = WriterLease(generation: generation, id: UUID())
        activeWriterLeaseIDs = [lease.id]
        initializingFrameCapability = frameCapability
        state = .initializing(generation: generation, activeWriterLeases: 1)
        return lease
    }

    /// Acquires a position writer in either initialization or ready state.
    /// A ready document advances to a fresh generation; initialization work
    /// joins the generation already in progress.
    func acquirePositionWriter() -> WriterLease? {
        switch state {
        case let .initializing(generation, _):
            return acquireWriterLease(for: generation)
        case .ready:
            return beginMutation()
        case .unavailable, .loading, .failed:
            return nil
        }
    }

    /// Releases a writer only when both its generation and identity are still
    /// current. Stale and duplicate releases are inert.
    func release(_ lease: WriterLease) {
        guard
            case .initializing(lease.generation, _) = state,
            activeWriterLeaseIDs.remove(lease.id) != nil
        else {
            return
        }

        if activeWriterLeaseIDs.isEmpty {
            guard let frameCapability = initializingFrameCapability else {
                invalidate()
                return
            }
            initializingFrameCapability = nil
            state = .ready(
                generation: lease.generation,
                frameCapability: frameCapability
            )
            resumeEligibleWaiters()
        } else {
            state = .initializing(
                generation: lease.generation,
                activeWriterLeases: activeWriterLeaseIDs.count
            )
        }
    }

    /// Finishes the root initialization write. Failure invalidates the exact
    /// active generation instead of releasing it into a ready state.
    func finishInitialization(
        _ lease: WriterLease,
        outcome: InitializationOutcome
    ) {
        guard
            case .initializing(lease.generation, _) = state,
            activeWriterLeaseIDs.contains(lease.id)
        else {
            return
        }

        switch outcome {
        case .succeeded:
            release(lease)
        case .failed:
            fail(ifCurrent: lease.generation)
        }
    }

    /// Finishes a runtime write against the retained frame capability.
    /// Supersession is a successful hand-off to a known successor, while an
    /// actual write failure makes the document unavailable.
    func finishMutation(
        _ lease: WriterLease,
        outcome: MutationOutcome
    ) {
        guard
            case .initializing(lease.generation, _) = state,
            activeWriterLeaseIDs.contains(lease.id)
        else {
            return
        }

        switch outcome {
        case .succeeded, .superseded:
            release(lease)
        case .failed:
            fail(ifCurrent: lease.generation)
        }
    }

    /// Marks a generation as terminally failed without changing its identity.
    /// A later load advances normally, while callbacks from older generations
    /// remain unable to affect the replacement lifecycle.
    @discardableResult
    func fail(ifCurrent generation: Generation) -> Bool {
        guard state.generation == generation else {
            return false
        }
        activeWriterLeaseIDs.removeAll()
        initializingFrameCapability = nil
        state = .failed(generation: generation)
        drainWaiters(with: .failed(generation: generation))
        return true
    }

    /// Invalidates the current document and terminates every registered wait.
    func invalidate() {
        let generation = nextGeneration()
        drainWaiters(with: .invalidated)
        activeWriterLeaseIDs.removeAll()
        initializingFrameCapability = nil
        state = .unavailable(generation: generation)
    }

    func waitForDocumentAvailability(for generation: Generation) async -> WaitOutcome {
        await wait(for: .documentAvailability, generation: generation)
    }

    func waitForCommandReadiness(for generation: Generation) async -> WaitOutcome {
        await wait(for: .commandReadiness, generation: generation)
    }

    /// Waits for command readiness of the exact frame DOCUMENT rather than a
    /// fixed render generation. A same-document mutation (a position writer
    /// acquired the instant readiness published — e.g. a precise locator
    /// landing) advances the generation while retaining the capability; this
    /// wait follows the document across those advances and resumes `.ready`
    /// when the latest same-document generation publishes. It returns
    /// `.invalidated` once the capability is gone or replaced (replacement
    /// load, invalidation, or a different document), and forwards `.failed` /
    /// `.cancelled` from the underlying generation wait.
    func waitForCommandReadiness(
        forDocument capability: EPUBSpreadFrameCapability
    ) async -> WaitOutcome {
        await waitForCommandReadiness(forDocument: capability) { generation in
            await self.waitForCommandReadiness(for: generation)
        }
    }

    /// The deadline-bounded form of `waitForCommandReadiness(forDocument:)`.
    ///
    /// Every re-wait shares the SAME absolute instant, so following a document
    /// across an unbounded number of same-document mutations cannot extend the
    /// operation past its deadline — an advancing generation buys no extra time,
    /// it only redistributes what is left. A document whose generation keeps
    /// advancing (font, stylesheet and progression churn during initialization)
    /// therefore surfaces as `.timedOut`, which the caller reads as a miss, and
    /// never as a hang.
    func waitForCommandReadiness(
        forDocument capability: EPUBSpreadFrameCapability,
        until deadline: ContinuousClock.Instant
    ) async -> WaitOutcome {
        await waitForCommandReadiness(
            forDocument: capability,
            until: deadline
        ) { generation, sharedDeadline in
            await self.waitForCommandReadiness(
                for: generation,
                until: sharedDeadline
            )
        }
    }

    /// Test seam for the bounded document-following law. The exact deadline is
    /// handed to every generation wait so a test can prove re-waits reuse it
    /// without racing a real timeout against mutation churn.
    func waitForCommandReadiness(
        forDocument capability: EPUBSpreadFrameCapability,
        until deadline: ContinuousClock.Instant,
        awaitingEachGenerationWith generationWait: (
            Generation,
            ContinuousClock.Instant
        ) async -> WaitOutcome
    ) async -> WaitOutcome {
        await waitForCommandReadiness(forDocument: capability) { generation in
            await generationWait(generation, deadline)
        }
    }

    /// The one document-following law, parameterized by how each generation is
    /// awaited. Both overloads above are this loop; keeping a single body is
    /// what stops the bounded and unbounded forms from drifting on the question
    /// that matters — which advances count as the same document.
    ///
    /// Not `private`: the `.invalidated` re-wait arm — the entire reason this
    /// type has a document-scoped wait at all — is only reachable in production
    /// through a main-actor race between reading `generation` and registering on
    /// it, which no test can drive deterministically. Injecting the per-generation
    /// wait is the only way to assert the law rather than the race.
    func waitForCommandReadiness(
        forDocument capability: EPUBSpreadFrameCapability,
        awaitingEachGenerationWith generationWait: (Generation) async -> WaitOutcome
    ) async -> WaitOutcome {
        while !Task.isCancelled {
            guard currentFrameCapability == capability else {
                return .invalidated
            }
            let outcome = await generationWait(generation)
            switch outcome {
            case let .ready(readyGeneration, readyCapability):
                guard readyCapability == capability else {
                    return .invalidated
                }
                return .ready(
                    generation: readyGeneration,
                    frameCapability: readyCapability
                )
            case .invalidated:
                // The generation advanced under this wait. If the capability
                // survived, it was a same-document mutation — wait again on
                // the successor generation; otherwise the document is gone.
                continue
            case .documentAvailable, .cancelled, .timedOut, .failed:
                return outcome
            }
        }
        return .cancelled
    }

    /// Waits against an absolute monotonic deadline. Timing out cancels and
    /// unregisters only this waiter; it never mutates shared readiness.
    func waitForCommandReadiness(
        for generation: Generation,
        until deadline: ContinuousClock.Instant
    ) async -> WaitOutcome {
        await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return .cancelled }
                return await self.waitForCommandReadiness(for: generation)
            }
            let clock = self.clock
            group.addTask {
                do {
                    try await clock.sleep(deadline)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            return outcome
        }
    }

    private func wait(
        for target: WaitTarget,
        generation: Generation
    ) async -> WaitOutcome {
        if Task.isCancelled {
            return .cancelled
        }
        if let outcome = immediateOutcome(for: target, generation: generation) {
            return outcome
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if let outcome = immediateOutcome(for: target, generation: generation) {
                    continuation.resume(returning: outcome)
                } else {
                    waiters[waiterID] = Waiter(
                        generation: generation,
                        target: target,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func immediateOutcome(
        for target: WaitTarget,
        generation: Generation
    ) -> WaitOutcome? {
        guard generation == state.generation else {
            return .invalidated
        }

        switch (target, state) {
        case (.documentAvailability, .initializing),
             (.documentAvailability, .ready):
            return .documentAvailable(generation: generation)
        case let (.commandReadiness, .ready(_, frameCapability)):
            return .ready(
                generation: generation,
                frameCapability: frameCapability
            )
        case (_, .unavailable):
            return .invalidated
        case let (_, .failed(generation)):
            return .failed(generation: generation)
        case (_, .loading), (.commandReadiness, .initializing):
            return nil
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(returning: .cancelled)
    }

    private func resumeEligibleWaiters() {
        let resumptions = waiters.compactMap { id, waiter -> (UUID, WaitOutcome)? in
            immediateOutcome(for: waiter.target, generation: waiter.generation)
                .map { (id, $0) }
        }
        for (id, outcome) in resumptions {
            guard let waiter = waiters.removeValue(forKey: id) else {
                continue
            }
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func drainWaiters(with outcome: WaitOutcome) {
        let waiters = waiters.values
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func nextGeneration() -> Generation {
        state.generation + 1
    }
}
