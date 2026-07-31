//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// A decoration transaction spans every affected resource, and several of those
/// resources can be backed by ONE spread — a two-page fixed-layout spread is two
/// HREFs on one document. Re-deriving "is this a live, command-ready write target"
/// per HREF is not just redundant: it silently accepted a DIFFERENT document for the
/// second HREF, so a replacement mid-transaction let the later write land on a
/// document the transaction never checked while the earlier writes were lost, and the
/// transaction still committed its state as applied.
///
/// These pin the shared resolution and, more importantly, what it is keyed on.
@MainActor
final class EPUBDecorationWriteGateTests: XCTestCase {
    private let capability = EPUBSpreadFrameCapability()
    private let replacement = EPUBSpreadFrameCapability()
    /// The identified objects are held for the test's lifetime on purpose.
    /// `ObjectIdentifier(NSObject())` on a temporary identifies an address that is
    /// free again immediately, so two such identifiers can compare EQUAL through
    /// address reuse — which silently collapses the per-spread scoping this suite is
    /// checking. Production keys on live spread views, which the pagination view
    /// retains for the transaction.
    private let spreadObject = NSObject()
    private let otherSpreadObject = NSObject()
    private var spread: ObjectIdentifier {
        ObjectIdentifier(spreadObject)
    }

    private var otherSpread: ObjectIdentifier {
        ObjectIdentifier(otherSpreadObject)
    }

    func testAReadySpreadIsResolvedAsAWriteTarget() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
    }

    /// The property the whole design rests on: the resolution is keyed on the frame
    /// CAPABILITY, never the generation. A decoration write advances the generation
    /// itself — `acquirePositionWriter()` on a ready spread calls `beginMutation()` —
    /// so a generation-keyed share would be invalidated by the very writes it exists
    /// to span, and every two-page spread would fail its own transaction.
    func testAWriteThatAdvancedTheGenerationStillSharesTheSameResolution() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
        // Same document, generation advanced by the write above.
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
    }

    /// The case the shared resolution exists to catch: the document this transaction
    /// checked was replaced, so a later HREF must not be written as though the earlier
    /// ones had landed on it.
    func testAReplacedDocumentIsRejectedEvenWhileTheSpreadReportsReady() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: replacement),
            .documentReplaced
        )
    }

    /// A torn-down document (invalidation, failure, reload) drops the capability
    /// entirely. Having checked one, nil is a replacement, not a "not ready yet".
    func testALostCapabilityIsAReplacementRatherThanASkip() {
        let gate = EPUBDecorationWriteGate()
        _ = gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability)
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: false, currentCapability: nil),
            .documentReplaced
        )
    }

    /// Replacement outranks readiness: a spread that is both replaced and not ready
    /// must report the replacement, because the transaction's earlier writes went to
    /// the document that is gone and it has to roll back rather than quietly skip.
    func testReplacementOutranksNotBeingReady() {
        let gate = EPUBDecorationWriteGate()
        _ = gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability)
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: false, currentCapability: replacement),
            .documentReplaced
        )
    }

    /// A spread that never became a write target is skipped, not failed — there is
    /// nothing to write and nothing was lost.
    func testASpreadThatWasNeverAWriteTargetIsSkipped() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: false, currentCapability: nil),
            .skip
        )
    }

    /// Ready without a capability is unrepresentable in the readiness state machine
    /// (`.ready` carries one). Fail safe rather than write blind if it ever becomes
    /// representable.
    func testReadyWithoutACapabilityIsSkippedRatherThanWritten() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: nil),
            .skip
        )
    }

    /// A skip must not pin anything: a spread still initializing when the transaction
    /// reached it can legitimately become a write target moments later.
    func testASkipDoesNotPinTheSpreadAgainstALaterResolution() {
        let gate = EPUBDecorationWriteGate()
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: false, currentCapability: nil),
            .skip
        )
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
    }

    /// Resolutions are per spread. One spread's replacement must not fail a sibling
    /// spread that is still the document the transaction checked.
    func testResolutionsAreScopedToTheirOwnSpread() {
        let gate = EPUBDecorationWriteGate()
        _ = gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability)
        XCTAssertEqual(
            gate.resolve(spread: otherSpread, isCommandReady: true, currentCapability: replacement),
            .write
        )
        XCTAssertEqual(
            gate.resolve(spread: spread, isCommandReady: true, currentCapability: capability),
            .write
        )
    }
}
