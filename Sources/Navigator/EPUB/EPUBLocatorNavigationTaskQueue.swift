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

    private struct Entry {
        let id: UUID
        let task: Task<LocatorNavigationOutcome, Never>
    }

    private var entry: Entry?

    func run(_ operation: @escaping Operation) async -> LocatorNavigationOutcome {
        let predecessor = entry?.task
        predecessor?.cancel()

        let id = UUID()
        let task = Task<LocatorNavigationOutcome, Never> { @MainActor [weak self] in
            if let predecessor {
                _ = await predecessor.value
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
        entry = Entry(id: id, task: task)

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func removeEntry(with id: UUID) {
        guard entry?.id == id else { return }
        entry = nil
    }
}
