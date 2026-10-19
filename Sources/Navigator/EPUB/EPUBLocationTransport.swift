//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// What the location transport reports to its owner: closed outcomes keyed
/// only by the opaque capability they concern.
enum EPUBLocationTransportEvent: Equatable, Sendable {
    /// The hand-off of `capability` ended without a registered frame: WebKit
    /// rejected the injection, or the attempt's deadline passed first.
    case handshakeFailed(EPUBSpreadFrameCapability)
    /// A call whose deadline had passed finally completed and its value was
    /// discarded. The slot it freed may already hold a pending hand-off.
    case lateCompletion
    /// An actual completion left the slot free: a wake-up for work waiting on
    /// it, reported after everything else that completion reports.
    case slotAvailable
}

/// A cancellable one-shot deadline armed by `EPUBDeadlineScheduler`.
struct EPUBScheduledDeadline {
    let cancel: @MainActor () -> Void
}

/// Reads the monotonic time and arms one-shot deadline callbacks for location
/// reporting. Injected so a test can fire a deadline at an exact point relative
/// to a call's actual completion, independently of either.
struct EPUBDeadlineScheduler {
    let now: @MainActor () -> ContinuousClock.Instant
    let schedule: @MainActor (
        _ instant: ContinuousClock.Instant,
        _ action: @escaping @MainActor () -> Void
    ) -> EPUBScheduledDeadline

    /// The production binding: sleeps on `clock` in a task the returned
    /// deadline cancels.
    static func clock(_ clock: EPUBMonotonicClock) -> EPUBDeadlineScheduler {
        EPUBDeadlineScheduler(
            now: { clock.now() },
            schedule: { instant, action in
                let task = Task { @MainActor in
                    do {
                        try await clock.sleep(instant)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else {
                        return
                    }
                    action()
                }
                return EPUBScheduledDeadline(cancel: { task.cancel() })
            }
        )
    }
}

/// The single physical WebKit call one reflowable web view may have outstanding
/// for location reporting: a capability injection or a progression read.
///
/// A logical deadline bounds how long the caller waits, never how long the call
/// occupies the web view: only the call's actual completion frees the slot, so
/// a page that stops answering cannot accumulate abandoned calls. Completions
/// hold the transport weakly and are matched by operation identity; `close()`
/// cancels the deadline and makes the outstanding call's callbacks inert.
@MainActor
final class EPUBLocationTransport {
    /// How a started call ended for its caller.
    enum Delivery {
        case completed(Result<Any, any Error>)
        case expired
    }

    /// Performs the physical call, handing WebKit the completion to call once.
    typealias Invocation = @MainActor (
        _ completion: @escaping @MainActor @Sendable (Result<Any, any Error>) -> Void
    ) -> Void

    private struct Operation {
        let id: Int
        var deliver: (@MainActor (Delivery) -> Void)?
        var deadline: EPUBScheduledDeadline?
        var reportsLateCompletion = false
    }

    private let scheduler: EPUBDeadlineScheduler
    private var operation: Operation?
    private var lastOperationID = 0

    /// Called when a call whose deadline had passed finally completes. Its value
    /// has been discarded; `onSlotFreed` may already have refilled the slot. A
    /// deadline alone never reports here: only an actual completion does.
    var onLateCompletion: (@MainActor () -> Void)?

    /// Called last for an actual completion, and only if the slot is still
    /// free after `onSlotFreed`, the caller and `onLateCompletion` ran.
    var onSlotAvailable: (@MainActor () -> Void)?

    /// Called whenever an actual completion frees the slot, before the caller
    /// or `onLateCompletion` is told, so queued work the owner ranks first can
    /// take the slot ahead of anything they start.
    var onSlotFreed: (@MainActor () -> Void)?

    init(scheduler: EPUBDeadlineScheduler) {
        self.scheduler = scheduler
    }

    /// Whether a physical call is outstanding, including one whose deadline
    /// passed or whose callbacks `close()` made inert.
    var isOccupied: Bool {
        operation != nil
    }

    /// Starts `invocation` when the slot is free and `deadline` is still ahead,
    /// and returns whether it did. `deliver` then receives exactly one of the
    /// call's completion or `.expired` at the deadline, whichever comes first,
    /// unless `close()` runs before either.
    @discardableResult
    func start(
        until deadline: EPUBLocatorOperationDeadline,
        invocation: Invocation,
        deliver: @escaping @MainActor (Delivery) -> Void
    ) -> Bool {
        guard operation == nil, !deadline.hasExpired(at: scheduler.now()) else {
            return false
        }
        lastOperationID += 1
        let id = lastOperationID
        operation = Operation(id: id, deliver: deliver)
        operation?.deadline = scheduler.schedule(deadline.expiresAt) { [weak self] in
            self?.expire(id)
        }
        invocation { [weak self] result in
            self?.complete(id, with: result)
        }
        return true
    }

    /// Cancels the outstanding call's deadline and silences its delivery and
    /// late-completion report. The slot stays occupied until WebKit actually
    /// completes the call, and that completion still reports the freed slot
    /// (`onSlotFreed`, `onSlotAvailable`).
    func close() {
        guard var current = operation else {
            return
        }
        current.deadline?.cancel()
        current.deadline = nil
        current.deliver = nil
        current.reportsLateCompletion = false
        operation = current
    }

    private func expire(_ id: Int) {
        guard var current = operation, current.id == id, let deliver = current.deliver else {
            return
        }
        current.deliver = nil
        current.deadline = nil
        current.reportsLateCompletion = true
        operation = current
        deliver(.expired)
    }

    private func complete(_ id: Int, with result: Result<Any, any Error>) {
        guard let current = operation, current.id == id else {
            return
        }
        operation = nil
        current.deadline?.cancel()
        onSlotFreed?()
        if let deliver = current.deliver {
            deliver(.completed(result))
        } else if current.reportsLateCompletion {
            onLateCompletion?()
        }
        if operation == nil {
            onSlotAvailable?()
        }
    }
}
