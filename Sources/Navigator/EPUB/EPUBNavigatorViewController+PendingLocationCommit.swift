//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared

/// Where the navigator's location stands once a pending commit settled.
public struct EPUBPendingLocationCommit: Equatable, Sendable {
    /// The navigator's `currentLocation` when the wait ended.
    public let location: Locator?
    /// Work was still outstanding at the deadline, so `location` is the last
    /// one committed before it.
    public let deadlinePassed: Bool
}

/// What a spread still owes the navigator's location publication.
enum EPUBSpreadLocationWork: Equatable, Sendable {
    /// Nothing to read.
    case idle
    /// A hint window, a read or an obligation.
    case working
    /// Nothing is read before a named event: the observation is unavailable,
    /// or its capability hand-off is missing.
    case blocked
}

public extension EPUBNavigatorViewController {
    /// Waits for the location the navigator is still calculating to commit,
    /// so a caller saving the position saves the place on screen rather than
    /// the one before a move. Returns at once when nothing is outstanding or
    /// nothing would publish before a named event, and at
    /// `EPUBLocationPublication.calculationBudget` otherwise, with the last
    /// committed location.
    func awaitPendingLocationCommit() async -> EPUBPendingLocationCommit {
        locationPublication.spreadWork = { [weak self] in
            self?.currentSpreadLocationWork() ?? .idle
        }
        let deadlinePassed = await locationPublication.awaitPendingCommit()
        return EPUBPendingLocationCommit(location: currentLocation, deadlinePassed: deadlinePassed)
    }
}

extension EPUBNavigatorViewController {
    /// The current spread's pending work. Read at each evaluation, so a spread
    /// change mid-wait is picked up: every change of the current spread asks
    /// the publication for a calculation, which evaluates the wait again.
    func currentSpreadLocationWork() -> EPUBSpreadLocationWork {
        guard
            let spread = paginationView?.currentView as? EPUBReflowableSpreadView,
            let observation = spread.builtLocationObservation
        else {
            return .idle
        }
        if observation.onPendingWorkChange == nil {
            observation.onPendingWorkChange = { [weak self] in
                self?.locationPublication.spreadWorkDidChange()
            }
        }
        return observation.pendingWork
    }
}
