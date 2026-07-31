//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// What a decoration write on one resource should do.
enum EPUBDecorationWriteDisposition: Equatable, Sendable {
    /// The spread is the live document this transaction checked; write.
    case write
    /// There is nothing to write here and nothing was lost — the spread is not
    /// loaded, or has not yet published command readiness. Not a failure.
    case skip
    /// The document this transaction already wrote to is gone. The transaction's
    /// earlier writes went to a document that no longer exists, so this must fail
    /// and roll back rather than land on the replacement.
    case documentReplaced
}

/// Resolves "is this spread the live write target of THIS decoration transaction?"
/// once per spread and shares the answer across every resource the transaction
/// touches on it, including rollback.
///
/// A decoration transaction spans every affected resource, and several of those can
/// be backed by one spread — a two-page fixed-layout spread is two HREFs on one
/// document. Re-deriving readiness per HREF was not merely redundant: it accepted
/// whatever document happened to occupy the spread at that moment, so a replacement
/// mid-transaction let a later write land on a document the transaction never
/// checked while the earlier writes were lost with the old one, and the transaction
/// still committed its state as applied.
///
/// **Keyed on the frame capability, never the generation.** A decoration write
/// advances the generation itself: `acquirePositionWriter()` on a `.ready` spread
/// calls `beginMutation()`, which mints a fresh generation. A generation-keyed share
/// would therefore be invalidated by the very writes it exists to span, and every
/// two-page spread would fail its own transaction. The capability is the identity
/// that survives a same-document mutation and dies on replacement, invalidation, or
/// failure — exactly the "we advanced it" versus "it is gone" distinction, and the
/// same identity `waitForCommandReadiness(forDocument:)` follows.
///
/// This shares the readiness RESULT only. The writer lease stays per write: holding
/// one across a whole transaction would suppress readiness republication for its
/// duration, which trades a navigation that interleaves and lands today for one that
/// times out, and risks pinning a spread at `.initializing` for good if a lease ever
/// escaped its release.
@MainActor
final class EPUBDecorationWriteGate {
    private var checkedCapabilities: [ObjectIdentifier: EPUBSpreadFrameCapability] = [:]

    /// - Parameters:
    ///   - spread: identity of the spread backing this resource. Several resources in
    ///     one transaction can share it.
    ///   - isCommandReady: whether the spread currently publishes command readiness.
    ///   - currentCapability: the spread's live frame-document capability.
    func resolve(
        spread: ObjectIdentifier,
        isCommandReady: Bool,
        currentCapability: EPUBSpreadFrameCapability?
    ) -> EPUBDecorationWriteDisposition {
        // Replacement is checked FIRST, ahead of readiness: a spread that is both
        // replaced and not ready has still lost this transaction's earlier writes, so
        // reporting "nothing to do" there would commit state the DOM never received.
        if let checked = checkedCapabilities[spread], checked != currentCapability {
            return .documentReplaced
        }
        guard isCommandReady, let currentCapability else {
            // Recording nothing here is deliberate: a spread still initializing when
            // the transaction reached it can legitimately become a write target
            // moments later, and a pinned nil would reject it forever.
            return .skip
        }
        checkedCapabilities[spread] = currentCapability
        return .write
    }
}
