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
struct EPUBPublicationKey: Equatable {
    let spread: ObjectIdentifier
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
/// Calculations start only while the navigator is idle; a request made while
/// it navigates is retained and runs the moment it settles. One calculation
/// runs at a time and one obligation is retained until a current result
/// discharges it; requests made meanwhile coalesce into one follow-up. A
/// result commits only when the navigator has not left idle since it started
/// and its capture is still current, checked and assigned without suspending
/// in between. A calculation that outlives its deadline keeps the slot until it
/// actually exits: its result is discarded, and its exit lets the latest
/// obligation run.
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
    private let capture: @MainActor () -> EPUBPublicationCapture?
    private let commit: @MainActor (EPUBPublicationOutput) -> Void

    /// Advanced by every `setIdle(false)`.
    private var revision: UInt64 = 0
    private var isIdle = false
    private var active: Active?
    private var lastID = 0
    private(set) var hasObligation = false

    /// Whether a calculation this publication started has not exited yet.
    var isCalculating: Bool {
        active != nil
    }

    /// A calculation outlived its deadline and still holds the slot.
    var isOperationPending: Bool {
        active?.hasExpired == true
    }

    /// - Parameters:
    ///   - capture: the current spread's inputs, or `nil` while there is no
    ///     current spread or nothing current to read.
    ///   - commit: assigns a current result.
    init(
        scheduler: EPUBDeadlineScheduler,
        capture: @escaping @MainActor () -> EPUBPublicationCapture?,
        commit: @escaping @MainActor (EPUBPublicationOutput) -> Void
    ) {
        self.scheduler = scheduler
        self.capture = capture
        self.commit = commit
    }

    /// The navigator settled (`true`) or started navigating (`false`). Leaving
    /// idle keeps a calculation already running from committing, and keeps the
    /// obligation; settling runs retained work.
    func setIdle(_ idle: Bool) {
        isIdle = idle
        if idle {
            attemptDispatch()
        } else {
            revision &+= 1
        }
    }

    /// Asks for a publication, coalesced with any already retained.
    func request() {
        hasObligation = true
        attemptDispatch()
    }

    private func attemptDispatch() {
        guard hasObligation, isIdle, active == nil, let capture = capture() else {
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
