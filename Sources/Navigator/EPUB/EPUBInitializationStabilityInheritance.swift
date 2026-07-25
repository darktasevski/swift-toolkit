//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// The locator operation currently performing a cross-resource hop, published by the
/// navigator for the duration of that hop so the target spread's initialization can
/// spend the operation's remainder instead of a fresh allowance.
///
/// The operation is identified by its TARGET RESOURCE rather than by a spread view:
/// when the hop starts, the spread that will render it does not exist yet.
struct EPUBActiveLocatorOperation: Equatable, Sendable {
    /// Distinguishes this operation from a successor that replaced it. Locator
    /// navigation is latest-request-wins with a BOUNDED predecessor acknowledgement,
    /// so a superseded operation can still be unwinding while its successor owns the
    /// slot; it must clear only its own entry.
    let id: UUID

    /// The resource the operation is landing in.
    let readingOrderIndex: ReadingOrder.Index

    /// The one deadline every rung of the operation spends from.
    let deadline: EPUBLocatorOperationDeadline

    init(
        id: UUID = UUID(),
        readingOrderIndex: ReadingOrder.Index,
        deadline: EPUBLocatorOperationDeadline
    ) {
        self.id = id
        self.readingOrderIndex = readingOrderIndex
        self.deadline = deadline
    }
}

/// Decides the single instant a spread's stylesheet, font and geometry stabilization
/// must be finished by.
///
/// A spread initializes on its own load event, not from the call stack of the
/// navigation that asked for it, so an operation deadline cannot simply be passed down
/// to it. This resolves the two facts that ARE available at that moment — the stage's
/// own fresh cap, and which locator operation (if any) the load is the hop target of —
/// into one instant, so a cross-resource landing costs the operation's budget rather
/// than the operation's budget times the resources it passed through.
enum EPUBInitializationStabilityInheritance {
    /// The operation whose remainder this spread's initialization must spend, or nil
    /// when the load is not part of one.
    ///
    /// Membership in the spread's reading-order range decides, so a fixed-layout spread
    /// qualifies on either of its pages. A PRELOADED NEIGHBOUR loading during the same
    /// window is deliberately excluded: its initialization is not part of the operation,
    /// and bounding it by that operation's remainder would abort a healthy adjacent
    /// spread. This is why the navigator publishes a targeted operation rather than an
    /// ambient "current deadline", which cannot draw that distinction.
    static func operationDeadline(
        for spread: EPUBSpread,
        activeOperation: EPUBActiveLocatorOperation?
    ) -> EPUBLocatorOperationDeadline? {
        guard
            let activeOperation,
            spread.contains(index: activeOperation.readingOrderIndex)
        else {
            return nil
        }
        return activeOperation.deadline
    }

    /// Takes the EARLIER of the stage's own cap and the inherited operation deadline.
    ///
    /// Composition is one-directional, matching every other rung: an inherited deadline
    /// can only SHORTEN stabilization, and the stage's own cap can only shorten the
    /// operation. Neither re-arms the other, so an overrun operation hands on an already
    /// expired instant and the stage's remaining-budget guard rejects it immediately
    /// rather than starting a wait the operation cannot afford.
    static func resolve(
        ownCap: ContinuousClock.Instant,
        inheritedFrom operationDeadline: EPUBLocatorOperationDeadline?
    ) -> ContinuousClock.Instant {
        guard let operationDeadline else {
            return ownCap
        }
        return operationDeadline.effectiveDeadline(cappedBy: ownCap)
    }
}

/// Holds the one locator operation whose cross-resource hop is in flight, so the spread
/// that renders its target can read the operation's remaining budget back on its own
/// load event.
///
/// A slot rather than a plain property because the clear is identity-guarded. Locator
/// navigation is latest-request-wins with a bounded predecessor acknowledgement, so a
/// superseded operation can still be unwinding after its successor published here; an
/// unguarded clear would drop the successor's entry and silently restore the
/// fresh-budget behaviour for that landing.
@MainActor
final class EPUBActiveLocatorOperationSlot {
    private var current: EPUBActiveLocatorOperation?

    /// Publishes the hop that is starting. A successor deliberately replaces its
    /// predecessor: latest request wins.
    func publish(_ operation: EPUBActiveLocatorOperation) {
        current = operation
    }

    /// Withdraws an operation once its hop is done, only while that exact operation
    /// still owns the slot.
    func clear(_ operation: EPUBActiveLocatorOperation) {
        guard current?.id == operation.id else { return }
        current = nil
    }

    /// The deadline the given spread's initialization must finish within, or nil when
    /// this load is not the in-flight hop's target.
    func operationDeadline(for spread: EPUBSpread) -> EPUBLocatorOperationDeadline? {
        EPUBInitializationStabilityInheritance.operationDeadline(
            for: spread,
            activeOperation: current
        )
    }
}
