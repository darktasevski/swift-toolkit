//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

@MainActor
final class EPUBLocationPublicationTests: XCTestCase {
    // MARK: - Idle

    func test_aRequestWhileIdleCalculatesAndCommits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")

        fixture.publication.request()

        XCTAssertEqual(fixture.dispatched, ["a"])
        a.release()
        try await fixture.waitUntil { fixture.committed == ["a"] }
        XCTAssertFalse(fixture.publication.hasObligation)
    }

    func test_aRequestWhileNavigatingWaitsUntilIdle() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()

        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, [])
        XCTAssertTrue(fixture.publication.hasObligation)

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    func test_repeatedRequestsWhileNavigatingCalculateOnce() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()
        fixture.publication.request()
        fixture.publication.request()
        fixture.publication.request()

        fixture.publication.setIdle(true)
        try await fixture.waitUntil { fixture.committed == ["a"] }
        fixture.publication.setIdle(false)
        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
    }

    func test_settlingWithoutAnObligationCalculatesNothing() throws {
        let fixture = try PublicationFixture()
        fixture.offer("a")

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, [])
    }

    /// A committed result discharges the obligation, so settling again after
    /// another navigation needs a new request.
    func test_aCommittedResultDischargesTheObligation() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.offer("a").release()
        fixture.publication.request()
        try await fixture.waitUntil { fixture.committed == ["a"] }

        fixture.publication.setIdle(false)
        fixture.offer("b")
        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
    }

    /// An obligation retained while navigating survives a further navigation
    /// and runs once, when the navigator first settles.
    func test_anObligationSurvivesAnotherNavigationBeforeSettling() async throws {
        let fixture = try PublicationFixture()
        fixture.offer("a").release()
        fixture.publication.request()
        fixture.publication.setIdle(false)
        XCTAssertEqual(fixture.dispatched, [])

        fixture.publication.setIdle(true)

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    /// Idle with nothing current to read retains the obligation; the request
    /// that comes with publishable inputs runs it once.
    func test_anObligationWaitsForPublishableInputs() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)

        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, [])
        XCTAssertTrue(fixture.publication.hasObligation)

        fixture.offer("a").release()
        fixture.publication.request()

        XCTAssertEqual(fixture.dispatched, ["a"])
        try await fixture.waitUntil { fixture.committed == ["a"] }
    }

    // MARK: - One calculation at a time

    /// Requests while a calculation runs neither start a second one nor
    /// supersede it; they retain exactly one follow-up.
    func test_requestsDuringACalculationCoalesceIntoOneFollowUp() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()

        fixture.publication.request()
        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, ["a"], "A second calculation started beside the first")

        let followUp = fixture.offer("a-again")
        a.release()
        try await fixture.waitUntil { followUp.started }
        followUp.release()
        try await fixture.waitUntil { fixture.committed == ["a", "a-again"] }
        XCTAssertEqual(fixture.dispatched, ["a", "a-again"])
        XCTAssertFalse(fixture.publication.hasObligation)
    }

    // MARK: - Currency

    /// Navigating while A computes keeps A's result from committing, even when
    /// the navigator is idle again by then; the latest inputs are calculated
    /// and committed instead.
    func test_aCalculationOutlivedByANavigationCommitsNothingAndTheLatestDoes() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        fixture.publication.setIdle(false)
        let b = fixture.offer("b")
        fixture.publication.setIdle(true)
        a.release()

        try await fixture.waitUntil { b.started }
        XCTAssertEqual(fixture.committed, [], "A calculation outlived by a navigation committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
    }

    /// A capture that stopped being current (new geometry, or another spread
    /// at the same index) commits nothing, with no navigation needed.
    func test_aCaptureThatStoppedBeingCurrentCommitsNothing() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        a.isCurrent = false
        let b = fixture.offer("b")
        a.release()

        try await fixture.waitUntil { b.started }
        XCTAssertEqual(fixture.committed, [], "A result that was no longer current committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
    }

    func test_aNewObservationOfTheSameSpreadIsANewKey() {
        let capability = EPUBSpreadFrameCapability()
        let spread = ObjectIdentifier(NSObject())
        let before = EPUBPublicationKey(spread: spread, spreadIndex: 2, capability: capability, stamp: 4)

        XCTAssertNotEqual(before, EPUBPublicationKey(spread: spread, spreadIndex: 2, capability: capability, stamp: 5))
        XCTAssertEqual(before, EPUBPublicationKey(spread: spread, spreadIndex: 2, capability: capability, stamp: 4))
    }

    func test_aReplacedSpreadAtTheSameIndexIsANewKey() {
        let capability = EPUBSpreadFrameCapability()
        let old = NSObject()
        let replacement = NSObject()

        XCTAssertNotEqual(
            EPUBPublicationKey(spread: ObjectIdentifier(old), spreadIndex: 2, capability: capability, stamp: 4),
            EPUBPublicationKey(spread: ObjectIdentifier(replacement), spreadIndex: 2, capability: capability, stamp: 4)
        )
        XCTAssertNotEqual(
            EPUBPublicationKey(spread: ObjectIdentifier(old), spreadIndex: 2, capability: capability, stamp: 4),
            EPUBPublicationKey(spread: ObjectIdentifier(old), spreadIndex: 2, capability: EPUBSpreadFrameCapability(), stamp: 4)
        )
    }

    // MARK: - Deadline and actual exit

    /// A calculation past its deadline keeps the slot: no replacement starts
    /// until it actually exits, its result is discarded, and then the latest
    /// obligation runs and commits.
    func test_anExpiredCalculationKeepsItsSlotUntilItExits() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        let a = fixture.offer("a")
        fixture.publication.request()
        try await fixture.waitUntil { a.started }

        fixture.deadlines.advance(by: EPUBLocationPublication.calculationBudget)
        XCTAssertTrue(fixture.publication.isOperationPending)
        XCTAssertTrue(fixture.publication.hasObligation, "Expiry dropped the obligation")
        let b = fixture.offer("b")
        fixture.publication.request()
        XCTAssertEqual(fixture.dispatched, ["a"], "A replacement started beside the expired calculation")

        a.release()
        try await fixture.waitUntil { b.started }
        XCTAssertEqual(fixture.committed, [], "The expired result committed")
        b.release()
        try await fixture.waitUntil { fixture.committed == ["b"] }
        XCTAssertFalse(fixture.publication.isOperationPending)
    }

    func test_aCalculationThatExitsInTimeLeavesNoDeadlineArmed() async throws {
        let fixture = try PublicationFixture()
        fixture.publication.setIdle(true)
        fixture.offer("a").release()

        fixture.publication.request()
        try await fixture.waitUntil { fixture.committed == ["a"] }

        XCTAssertEqual(fixture.deadlines.armedCount, 0)
        XCTAssertFalse(fixture.publication.isCalculating)
    }
}

// MARK: - Fixtures

/// A calculation held open until the test releases it.
@MainActor
private final class Calculation {
    let name: String
    let href: AnyURL
    var isCurrent = true
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(name: String, href: AnyURL) {
        self.name = name
        self.href = href
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func run() async -> EPUBPublicationOutput {
        started = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return EPUBPublicationOutput(
            locator: Locator(href: href, mediaType: .html, title: name),
            viewport: NavigatorViewport(resources: [], progression: 0 ... 0, positions: nil)
        )
    }
}

/// A publication whose inputs, calculations and commits the test controls.
@MainActor
private final class PublicationFixture {
    let deadlines = ManualDeadlines()
    private let href: AnyURL
    /// What the navigator would capture now; `nil` while it cannot publish.
    var current: Calculation?
    private(set) var dispatched: [String] = []
    private(set) var committed: [String] = []

    lazy var publication = EPUBLocationPublication(
        scheduler: deadlines.scheduler,
        capture: { [unowned self] in
            guard let calculation = current else {
                return nil
            }
            dispatched.append(calculation.name)
            return EPUBPublicationCapture(
                isCurrent: { calculation.isCurrent },
                calculate: { await calculation.run() }
            )
        },
        commit: { [unowned self] in committed.append($0.locator?.title ?? "nil") }
    )

    init() throws {
        href = try XCTUnwrap(RelativeURL(path: "chapter.html")).anyURL
    }

    @discardableResult
    func offer(_ name: String) -> Calculation {
        let calculation = Calculation(name: name, href: href)
        current = calculation
        return calculation
    }

    func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if condition() {
                return
            }
            try await clock.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true before timeout", file: file, line: line)
        throw PublicationTimeout()
    }
}

private struct PublicationTimeout: Error {}
