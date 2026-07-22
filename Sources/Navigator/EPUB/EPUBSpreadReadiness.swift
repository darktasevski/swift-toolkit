//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

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

    enum State: Equatable, Sendable {
        case unavailable(generation: Generation)
        case loading(generation: Generation)
        case initializing(generation: Generation, activeWriterLeases: Int)
        case ready(generation: Generation, frameCapability: EPUBSpreadFrameCapability)

        var generation: Generation {
            switch self {
            case let .unavailable(generation),
                 let .loading(generation),
                 let .initializing(generation, _),
                 let .ready(generation, _):
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
    private var waiters: [UUID: Waiter] = [:]

    var generation: Generation {
        state.generation
    }

    var isDocumentAvailable: Bool {
        switch state {
        case .initializing, .ready:
            return true
        case .unavailable, .loading:
            return false
        }
    }

    var readyFrameCapability: EPUBSpreadFrameCapability? {
        guard case let .ready(_, frameCapability) = state else {
            return nil
        }
        return frameCapability
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
        case .unavailable, .loading:
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
            group.addTask {
                do {
                    try await ContinuousClock().sleep(until: deadline)
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
        let waiters = self.waiters.values
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func nextGeneration() -> Generation {
        state.generation + 1
    }
}
