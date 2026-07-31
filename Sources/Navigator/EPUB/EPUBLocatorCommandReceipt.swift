//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Binds the world one locator command landed in, so a later step can prove it is still
/// acting on that world.
///
/// A precise landing does not end when the scroll settles. The caller still validates the
/// match's uniqueness and then paints a transient decoration, and both of those suspend.
/// Without a receipt each step re-derives the world from whatever is current when it
/// resumes, which is how a superseded command ends up painting over — or clearing — the
/// decoration of the command that replaced it.
///
/// The receipt is opaque to callers: it is carried from the landing to the step that acts
/// on it and handed back for revalidation. Nothing outside this module reads its parts.
public struct EPUBLocatorCommandReceipt: Equatable, Sendable {
    /// One snapshot of the render world — taken when the command lands, and again at each
    /// revalidation. Currency is the comparison of the two.
    struct World: Equatable, Sendable {
        /// The spread the command landed on, by position in the pagination view.
        let spreadIndex: Int
        /// The spread view object itself. An index alone cannot see a spread rebuilt in
        /// place, which is a different render surface with the same address in the list.
        let spreadIdentity: ObjectIdentifier
        /// The readiness generation at landing. Checked for non-regression only — see
        /// `isCurrent(in:)`.
        let generation: UInt64
        /// The child document the command actually landed in. Nil once that document is
        /// gone: replacement load, invalidation, `pagehide`, or failure.
        let frameCapability: EPUBSpreadFrameCapability?
        /// Whether the spread will accept a command at all right now.
        let isCommandReady: Bool
        /// Monotonic count of locator navigations this navigator has started. A newer
        /// navigation makes every older receipt stale, which is the property that stops a
        /// paused predecessor from acting after its successor has landed.
        let operationSequence: UInt64
    }

    let world: World

    /// Whether this receipt still describes `live`.
    ///
    /// Generation is deliberately NOT an equality gate. A position or decoration write
    /// advances the generation itself, so a receipt keyed on generation equality would be
    /// invalidated by the very write it exists to authorize. The frame capability is the
    /// document-lineage identity that survives a same-document mutation and changes for
    /// every replacement — so it, not the generation, answers "is this the same document?".
    /// Generation is still checked for non-regression: it cannot walk backwards within one
    /// readiness instance, so a lower value means the readiness was replaced.
    func isCurrent(in live: World) -> Bool {
        guard let liveCapability = live.frameCapability else { return false }
        return live.isCommandReady
            && live.operationSequence == world.operationSequence
            && live.spreadIndex == world.spreadIndex
            && live.spreadIdentity == world.spreadIdentity
            && liveCapability == world.frameCapability
            && live.generation >= world.generation
    }
}

/// A locator navigation's outcome together with the receipt for its landing.
///
/// The receipt is present only for `.landed`: a command that missed or was abandoned bound
/// no world, and handing one back would let a caller treat a non-landing as a landing.
public struct EPUBLocatorNavigationResult: Equatable, Sendable {
    public let outcome: LocatorNavigationOutcome
    public let receipt: EPUBLocatorCommandReceipt?

    /// A terminal outcome that bound no world.
    static func unreceipted(_ outcome: LocatorNavigationOutcome) -> Self {
        Self(outcome: outcome, receipt: nil)
    }
}

/// Carries one navigation's receipt out of the operation closure the supersession queue
/// runs.
///
/// The queue's terminal type is the outcome. Widening it to carry a receipt would put one
/// into every test of a primitive whose subject is supersession ordering, not receipts —
/// so the receipt travels beside the outcome instead. A slot is allocated per call and
/// captured by exactly that call's closure, so no other request can write it, and the
/// caller reads it only for a `.landed` outcome.
@MainActor
final class EPUBLocatorCommandReceiptSlot {
    private(set) var receipt: EPUBLocatorCommandReceipt?

    func record(_ receipt: EPUBLocatorCommandReceipt) {
        self.receipt = receipt
    }
}
