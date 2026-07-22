//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Serializes asynchronous decoration replacement within each group.
///
/// A successor cancels its predecessor, waits for the predecessor's cleanup to finish, then starts
/// with the last committed decoration snapshot. Different groups remain independent.
@MainActor
final class DecorationApplyTaskQueue {
    typealias Operation = @MainActor (_ isSuperseding: Bool) async -> Void

    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var entries: [DecorationGroup: Entry] = [:]

    func submit(in group: DecorationGroup, operation: @escaping Operation) {
        enqueue(in: group, cancelsPredecessor: true, operation: operation)
    }

    /// Replays the latest committed group snapshot after any active mutation.
    ///
    /// Lifecycle and callback replays must not supersede a user-requested
    /// mutation. The operation is created immediately but reads navigator state
    /// only after its predecessor completes.
    func replay(in group: DecorationGroup, operation: @escaping @MainActor () async -> Void) async {
        let task = enqueue(in: group, cancelsPredecessor: false) { _ in
            await operation()
        }
        await task.value
    }

    @discardableResult
    private func enqueue(
        in group: DecorationGroup,
        cancelsPredecessor: Bool,
        operation: @escaping Operation
    ) -> Task<Void, Never> {
        let predecessor = entries[group]?.task
        if cancelsPredecessor {
            predecessor?.cancel()
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }

            guard !Task.isCancelled else {
                self?.removeEntry(with: id, in: group)
                return
            }

            await operation(predecessor != nil)
            self?.removeEntry(with: id, in: group)
        }
        entries[group] = Entry(id: id, task: task)
        return task
    }

    func waitForIdle(in group: DecorationGroup) async {
        while let task = entries[group]?.task {
            await task.value
        }
    }

    private func removeEntry(with id: UUID, in group: DecorationGroup) {
        guard entries[group]?.id == id else { return }
        entries[group] = nil
    }
}

/// Applies resource mutations transactionally with cancellation-independent rollback.
///
/// Resources enter the rollback ledger before their asynchronous mutation starts. This covers a
/// command that mutates WebKit and then observes cancellation before returning its result.
@MainActor
struct DecorationApplyResourceTransaction<Resource> {
    let resources: [Resource]

    func run(
        apply: @MainActor (Resource) async -> Bool,
        rollback: @escaping @MainActor (Resource) async -> Bool
    ) async -> Bool {
        var attempted: [Resource] = []

        for resource in resources {
            guard !Task.isCancelled else {
                await performRollback(attempted, using: rollback)
                return false
            }

            attempted.append(resource)
            guard await apply(resource) else {
                await performRollback(attempted, using: rollback)
                return false
            }
        }

        guard !Task.isCancelled else {
            await performRollback(attempted, using: rollback)
            return false
        }
        return true
    }

    private func performRollback(
        _ resources: [Resource],
        using operation: @escaping @MainActor (Resource) async -> Bool
    ) async {
        _ = await Task { @MainActor in
            var succeeded = true
            for resource in resources.reversed() {
                if await !operation(resource) {
                    succeeded = false
                }
            }
            return succeeded
        }.value
    }
}
