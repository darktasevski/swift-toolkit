//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Bounds an await that has no timeout of its own by the operation's single absolute
/// deadline.
///
/// The boundary this exists for is `callAsyncJavaScript`. Its continuation is resumed
/// by WebKit, and there are states in which WebKit never resumes it: a wedged page main
/// thread, a script that never yields, a content process that stops servicing the world
/// without delivering `webViewWebContentProcessDidTerminate`. In those states every
/// deadline above the call is decorative — the script's own `performance.now()` budget
/// cannot expire a script that is not running, and the navigation simply never reports
/// an outcome.
///
/// Two properties make this a watchdog rather than another race:
///
/// - **The loser is abandoned, not awaited.** A structured `withThrowingTaskGroup`
///   would be wrong here: on scope exit the group implicitly awaits its remaining
///   children, so throwing on expiry would suspend inside the very hung call the
///   watchdog is supposed to escape. The operation therefore runs in an unstructured
///   task whose completion is reported through a resume-once gate, and expiry abandons
///   it (cancelling it best-effort — WebKit does not observe cancellation, which is
///   precisely why the abandonment has to be safe).
/// - **The operation's own failure is preserved.** A WebKit failure in the current
///   document and a call that never returned are different truths upstream, so the
///   watchdog rethrows what the operation threw and reserves `Expired` for its own
///   verdict.
@MainActor
enum EPUBLocatorCommandWatchdog {
    /// The deadline elapsed with the operation still suspended. Distinct from any error
    /// the operation itself can raise.
    struct Expired: Error {}

    private enum Verdict<Value: Sendable>: Sendable {
        case completed(Value)
        case failed(any Error)
        case expired
        case cancelled
    }

    /// Resumes at most once, whichever racer reports first; MainActor isolation makes
    /// the guard race-free. The continuation attaches after creation so a racer that
    /// finishes before the await begins (an already-cancelled caller, a synchronous
    /// operation) still resumes it the moment it arrives.
    @MainActor
    private final class RaceGate<Value: Sendable> {
        private var verdict: Verdict<Value>?
        private var continuation: CheckedContinuation<Verdict<Value>, Never>?

        func attach(_ continuation: CheckedContinuation<Verdict<Value>, Never>) {
            if let verdict {
                continuation.resume(returning: verdict)
                return
            }
            self.continuation = continuation
        }

        func fire(_ verdict: Verdict<Value>) {
            guard self.verdict == nil else { return }
            self.verdict = verdict
            continuation?.resume(returning: verdict)
            continuation = nil
        }
    }

    /// - Parameters:
    ///   - deadline: the operation-wide deadline. The watchdog spends what is left of
    ///     it; it never mints its own, so a command reached after a hop and a readiness
    ///     wait is bounded by correspondingly less.
    ///   - clock: the monotonic source for both the remaining-budget read and the wait.
    ///   - operation: the unbounded await to guard.
    /// - Throws: `Expired` when the deadline elapses first, `CancellationError` when the
    ///   caller is cancelled first, or whatever `operation` threw.
    static func run<Value: Sendable>(
        until deadline: EPUBLocatorOperationDeadline,
        clock: EPUBMonotonicClock,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        // Arriving with nothing left buys no round-trip: starting the call would let an
        // already-spent operation spend more, which is the exact re-arming the single
        // deadline exists to make impossible.
        guard !deadline.hasExpired(at: clock.now()) else {
            throw Expired()
        }

        let gate = RaceGate<Value>()
        let work = Task { @MainActor in
            do {
                let value = try await operation()
                gate.fire(.completed(value))
            } catch {
                gate.fire(.failed(error))
            }
        }
        let timer = Task { @MainActor in
            // A cancelled sleeper is the operation having already won; the gate has a
            // verdict and this `fire` is a no-op.
            try? await clock.sleep(deadline.expiresAt)
            gate.fire(.expired)
        }
        defer { timer.cancel() }

        let verdict = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.attach($0) }
        } onCancel: {
            Task { @MainActor in gate.fire(.cancelled) }
        }

        switch verdict {
        case let .completed(value):
            return value
        case let .failed(error):
            throw error
        case .expired:
            work.cancel()
            throw Expired()
        case .cancelled:
            work.cancel()
            throw CancellationError()
        }
    }
}
