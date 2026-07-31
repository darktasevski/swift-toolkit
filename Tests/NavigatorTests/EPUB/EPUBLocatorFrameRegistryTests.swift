//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// Frame registration binds to an unforgeable per-document capability, not a
/// document epoch stamped at message-receipt time. A frame whose echoed
/// capability differs from the one the current spread generation minted — a
/// delayed old document, a same-URL reload, or a nested/self-navigated frame —
/// can never be selected as the command target.
final class EPUBLocatorFrameRegistryTests: XCTestCase {
    func test_reflowableSelectsExactlyOneCurrentSameOriginMainFrame() {
        let capability = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .reflowable)
        registry.register(
            id: "main",
            href: "chapter.xhtml",
            capability: capability,
            isMainFrame: true,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .selected("main")
        )
    }

    func test_fixedLayoutRejectsWrapperMainFrameAndSelectsResourceChildFrame() {
        let capability = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .fixed)
        registry.register(
            id: "wrapper",
            href: "chapter.xhtml",
            capability: capability,
            isMainFrame: true,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .miss(.fixedLayoutIneligible)
        )

        registry.register(
            id: "resource",
            href: "chapter.xhtml",
            capability: capability,
            isMainFrame: false,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .selected("resource")
        )
    }

    func test_duplicateEligibleFramesFailClosed() {
        let capability = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .fixed)
        for id in ["left", "right"] {
            registry.register(
                id: id,
                href: "chapter.xhtml",
                capability: capability,
                isMainFrame: false,
                isSameOrigin: true
            )
        }

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .miss(.duplicateFrame)
        )
    }

    /// The load-bearing fix: a frame registered under a superseded capability
    /// (a delayed old document) is isolated out, and the frame that echoed the
    /// current capability is selected — even though both share the same href.
    func test_supersededCapabilityFrameIsIsolatedFromCurrent() {
        let stale = EPUBSpreadFrameCapability()
        let current = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .reflowable)
        registry.register(
            id: "stale",
            href: "chapter.xhtml",
            capability: stale,
            isMainFrame: true,
            isSameOrigin: true
        )
        registry.register(
            id: "current",
            href: "chapter.xhtml",
            capability: current,
            isMainFrame: true,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: current),
            .selected("current")
        )
    }

    func test_staleCapabilityAndCrossOriginFramesFailClosed() {
        let stale = EPUBSpreadFrameCapability()
        let current = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .reflowable)
        registry.register(
            id: "stale",
            href: "chapter.xhtml",
            capability: stale,
            isMainFrame: true,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: current),
            .miss(.staleDocument)
        )

        registry.register(
            id: "foreign",
            href: "chapter.xhtml",
            capability: current,
            isMainFrame: true,
            isSameOrigin: false
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: current),
            .miss(.crossOriginFrame)
        )
    }

    /// A `nil` current capability (no document has yet received one from the
    /// native side) matches no entry and fails closed.
    func test_nilCurrentCapabilityFailsClosed() {
        let stale = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .reflowable)
        registry.register(
            id: "stale",
            href: "chapter.xhtml",
            capability: stale,
            isMainFrame: true,
            isSameOrigin: true
        )

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: nil),
            .miss(.staleDocument)
        )
    }

    func test_unknownHrefFailsClosed() {
        let capability = EPUBSpreadFrameCapability()
        let registry = EPUBLocatorFrameRegistry(layout: .reflowable)

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .miss(.frameMissing)
        )
    }

    func test_repeatedReadyMessageForSameFrameDoesNotCreateDuplicate() {
        let capability = EPUBSpreadFrameCapability()
        var registry = EPUBLocatorFrameRegistry(layout: .reflowable)
        for _ in 0 ..< 2 {
            registry.register(
                id: "main",
                href: "chapter.xhtml",
                capability: capability,
                isMainFrame: true,
                isSameOrigin: true
            )
        }

        XCTAssertEqual(
            registry.select(href: "chapter.xhtml", capability: capability),
            .selected("main")
        )
    }

    @MainActor
    func test_setFrameCapabilityStoresCurrentCapability() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        XCTAssertNil(bridge.currentFrameCapability)

        let capability = EPUBSpreadFrameCapability()
        bridge.setFrameCapability(capability)

        XCTAssertEqual(bridge.currentFrameCapability, capability)
    }

    @MainActor
    func test_beginDocumentClearsCurrentFrameCapability() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        bridge.setFrameCapability(EPUBSpreadFrameCapability())
        XCTAssertNotNil(bridge.currentFrameCapability)

        bridge.beginDocument()

        XCTAssertNil(bridge.currentFrameCapability)
    }

    // MARK: - Frame-ready capability gate (bridge `didReceive` seam)

    /// The incoming frame-ready gate registers a frame only when it echoes the
    /// exact current capability for its own request URL. `resolveFrameReady`
    /// is the content-free seam `didReceive` calls after extracting the message
    /// fields (the `WKFrameInfo`-bearing effect stays in `didReceive`).
    @MainActor
    func test_resolveFrameReadyRegistersOnlyOnExactCapabilityEcho() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        let capability = EPUBSpreadFrameCapability()
        bridge.setFrameCapability(capability)

        let requestURL = try XCTUnwrap(URL(string: "https://readium/chapter.xhtml"))

        // Success: the announcement echoes the current capability for its own URL.
        let registration = bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: capability.id.uuidString,
            requestURL: requestURL,
            frameID: "frame-1"
        )
        XCTAssertEqual(registration?.id, "frame-1")
        XCTAssertEqual(registration?.capability, capability)
        XCTAssertTrue(registration?.isSameOrigin == true)

        // No echoed capability → reject.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: nil,
            requestURL: requestURL,
            frameID: "frame-1"
        ))

        // A forged / stale capability that is not the current one → reject.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: EPUBSpreadFrameCapability().id.uuidString,
            requestURL: requestURL,
            frameID: "frame-1"
        ))

        // The announced href does not match the frame's own request URL → reject.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/other.xhtml",
            announcedCapability: capability.id.uuidString,
            requestURL: requestURL,
            frameID: "frame-1"
        ))

        // An oversized href (> 4 KiB, the content-free boundary cap) is rejected before any URL
        // parse, even with the correct capability for its own request URL.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/" + String(repeating: "a", count: 5000),
            announcedCapability: capability.id.uuidString,
            requestURL: requestURL,
            frameID: "frame-1"
        ))

        // A missing request URL (WebKit gave no `frameInfo.request.url`) is rejected.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: capability.id.uuidString,
            requestURL: nil,
            frameID: "frame-1"
        ))
    }

    /// line-450 regression matrix "Frame identity": the four named threats — a delayed old-document
    /// announcement, a same-URL child reload, a nested substitution, and a child self-navigation —
    /// can never register as the current command target. Each reduces to echoing a superseded or
    /// absent capability, which the gate rejects; only the frame echoing the CURRENT capability
    /// registers. (Test_2's `forwardsCapabilityOneHopToChildFrameNeverGrandchild` proves the nested
    /// case at the live cross-frame level; this pins the gate contract for all four deterministically.)
    @MainActor
    func test_frameIdentityThreatsCannotRegisterUnderStaleOrAbsentCapability() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        let requestURL = try XCTUnwrap(URL(string: "https://readium/chapter.xhtml"))

        // A delayed old document / same-URL reload: the current generation minted a NEW capability,
        // so a frame echoing the SUPERSEDED capability is rejected.
        let superseded = EPUBSpreadFrameCapability()
        bridge.setFrameCapability(superseded)
        let current = EPUBSpreadFrameCapability()
        bridge.setFrameCapability(current)
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: superseded.id.uuidString,
            requestURL: requestURL,
            frameID: "delayed-or-reloaded"
        ))

        // A nested substitution / child self-navigation never received ANY capability, so its
        // announcement carries none and is rejected.
        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: nil,
            requestURL: requestURL,
            frameID: "nested-or-self-navigated"
        ))

        // Only the frame echoing the current capability registers.
        XCTAssertNotNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: current.id.uuidString,
            requestURL: requestURL,
            frameID: "current"
        ))
    }

    /// With no current capability (a torn-down or not-yet-injected spread), even
    /// a correct-looking echo cannot register — the gate fails closed.
    @MainActor
    func test_resolveFrameReadyFailsClosedWithoutCurrentCapability() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        // A capability the caller might replay after the spread was torn down.
        let stale = EPUBSpreadFrameCapability()
        bridge.setFrameCapability(stale)
        bridge.revokeFrameCapability()

        XCTAssertNil(bridge.resolveFrameReady(
            announcedHREF: "https://readium/chapter.xhtml",
            announcedCapability: stale.id.uuidString,
            requestURL: URL(string: "https://readium/chapter.xhtml"),
            frameID: "frame-1"
        ))
    }

    /// Revocation on spread teardown (`EPUBSpreadView.clear()`, removal, or
    /// disappearance) drops the current capability so a delayed, reloaded, or
    /// self-navigated document can never register or be selected afterwards.
    /// Unlike `beginDocument()` it does not advance the command epoch — teardown
    /// is not the start of a new document, and the readiness authority already
    /// owns in-flight command cancellation.
    @MainActor
    func test_revokeFrameCapabilityClearsCapabilityWithoutAdvancingEpoch() throws {
        let baseURL = try XCTUnwrap(HTTPURL(string: "https://readium/"))
        let bridge = EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: baseURL
        )
        bridge.setFrameCapability(EPUBSpreadFrameCapability())
        let epochBeforeRevoke = bridge.documentEpoch
        XCTAssertNotNil(bridge.currentFrameCapability)

        bridge.revokeFrameCapability()

        XCTAssertNil(bridge.currentFrameCapability)
        XCTAssertEqual(bridge.documentEpoch, epochBeforeRevoke)
    }
}
