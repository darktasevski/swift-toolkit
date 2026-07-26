//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import XCTest

/// A precise landing does not end when the scroll settles. The command's caller still has
/// to validate uniqueness and then paint a transient decoration, and each of those steps
/// suspends. The receipt is what makes those later steps provable: it binds the world the
/// command landed in, so a step that resumes into a DIFFERENT world can refuse to act
/// instead of painting over whatever replaced it.
///
/// These pin the currency rules as pure arithmetic over two snapshots, so the judgment is
/// testable without a navigator, a pagination view, or a live WebView.
final class EPUBLocatorCommandReceiptTests: XCTestCase {
    /// Statics, not instance properties, so they can serve as default arguments below —
    /// which is what lets a caller pass `nil` to mean "the document is gone" rather than
    /// "give me the default". Coalescing a nil default back to a real capability would
    /// make the withdrawn-document case unexpressible, and its test vacuous.
    private static let spread = NSObject()
    private static let otherSpread = NSObject()
    private static let capability = EPUBSpreadFrameCapability()
    private static let otherCapability = EPUBSpreadFrameCapability()

    private func world(
        spreadIndex: Int = 3,
        spread: NSObject = EPUBLocatorCommandReceiptTests.spread,
        generation: UInt64 = 7,
        frameCapability: EPUBSpreadFrameCapability? = EPUBLocatorCommandReceiptTests.capability,
        isCommandReady: Bool = true,
        operationSequence: UInt64 = 42
    ) -> EPUBLocatorCommandReceipt.World {
        EPUBLocatorCommandReceipt.World(
            spreadIndex: spreadIndex,
            spreadIdentity: ObjectIdentifier(spread),
            generation: generation,
            frameCapability: frameCapability,
            isCommandReady: isCommandReady,
            operationSequence: operationSequence
        )
    }

    // MARK: - The receipt is current

    func testUnchangedWorldKeepsTheReceiptCurrent() {
        let receipt = EPUBLocatorCommandReceipt(world: world())
        XCTAssertTrue(receipt.isCurrent(in: world()))
    }

    /// The decoration write that the receipt exists to authorize ADVANCES the generation
    /// itself, so a receipt keyed on generation equality would be invalidated by the very
    /// write it is meant to span. The frame capability is the document-lineage identity
    /// that survives a same-document mutation, and the generation is checked only for
    /// non-regression.
    func testSameDocumentGenerationAdvanceKeepsTheReceiptCurrent() {
        let receipt = EPUBLocatorCommandReceipt(world: world(generation: 7))
        XCTAssertTrue(receipt.isCurrent(in: world(generation: 9)))
    }

    // MARK: - The receipt is stale

    /// The item's own proof obligation: B lands, and A — paused between its landing and
    /// its decoration — must not act. Every locator navigation bumps the sequence, so B
    /// landing is exactly what makes A's receipt stale.
    func testANewerLocatorOperationMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world(operationSequence: 42))
        XCTAssertFalse(receipt.isCurrent(in: world(operationSequence: 43)))
    }

    func testADifferentCurrentSpreadMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world(spreadIndex: 3))
        XCTAssertFalse(receipt.isCurrent(in: world(spreadIndex: 4)))
    }

    /// A spread view rebuilt at the SAME index is a different render surface, and the
    /// index alone cannot see that.
    func testASpreadViewReplacedAtTheSameIndexMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world())
        XCTAssertFalse(receipt.isCurrent(in: world(spread: Self.otherSpread)))
    }

    /// A reload or child self-navigation mints a fresh capability. This is also the
    /// backstop for the object-identity ABA hazard: a spread view deallocated and
    /// replaced at the same address carries a new capability regardless.
    func testAReplacedFrameDocumentMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world())
        XCTAssertFalse(receipt.isCurrent(in: world(frameCapability: Self.otherCapability)))
    }

    /// `pagehide`, invalidation, or a replacement load leave no capability at all.
    func testAWithdrawnFrameDocumentMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world())
        XCTAssertFalse(receipt.isCurrent(in: world(frameCapability: nil)))
    }

    func testALostCommandReadinessMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world())
        XCTAssertFalse(receipt.isCurrent(in: world(isCommandReady: false)))
    }

    /// Generation cannot walk backwards within one readiness instance, so this can only
    /// mean the readiness itself was replaced. The capability check already rejects that;
    /// the non-regression rule is the belt to its braces, and is asserted rather than
    /// assumed so a future refactor cannot quietly drop it.
    func testARegressedGenerationMakesTheReceiptStale() {
        let receipt = EPUBLocatorCommandReceipt(world: world(generation: 9))
        XCTAssertFalse(receipt.isCurrent(in: world(generation: 7)))
    }

    // MARK: - A receipt is minted only for a landing

    /// A command that missed or was abandoned has no world to bind: there is nothing for
    /// a later step to validate against, and handing back a receipt would let a caller
    /// treat a non-landing as a landing.
    func testOnlyALandedNavigationCarriesAReceipt() {
        XCTAssertNil(EPUBLocatorNavigationResult(outcome: .miss, receipt: nil).receipt)
        XCTAssertNil(EPUBLocatorNavigationResult(outcome: .cancelled, receipt: nil).receipt)
        XCTAssertEqual(EPUBLocatorNavigationResult(outcome: .miss, receipt: nil).outcome, .miss)
    }
}
