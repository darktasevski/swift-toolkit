//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import WebKit
import XCTest

/// The message the page-world reflowable script posts its progression hints to.
private let progressionMessageName = "progressionChanged"

/// Regressions for the location a reflowable spread reports once a navigation
/// settles. The navigator tests host the public navigator in a key window and
/// let it initialize on its own: readiness, frame registration and progression
/// messages all come from the production lifecycle. The progression-read tests
/// load documents of known geometry into a bare web view carrying the locator
/// command script, and issue its frame capability directly; the isolation test
/// checks that script leaves the page's layout alone. The scroll-hint tests add
/// the page-world reflowable script to that web view and record what it posts.
@MainActor
final class EPUBSettledLocationReportingTests: XCTestCase {
    func test_commandTurnReportsMeasuredProgressionWithinSameResource() async throws {
        let reader = try await openReader()
        try await assertATurnReportsTheMeasuredProgression(in: reader)
    }

    /// The command's own settlement measures the turned page: with the page's
    /// hints silenced, the report still arrives.
    func test_commandTurnWithHintsSilencedReportsTheMeasuredProgression() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        spread.webView.configuration.userContentController.removeScriptMessageHandler(forName: progressionMessageName)
        try await assertATurnReportsTheMeasuredProgression(in: reader)
    }

    /// The host animates page turns when the reader picks the animated
    /// transition. An animated turn, the end of a native scroll animation and
    /// a locator jump each report the range they settle on; with the page's
    /// hints silenced, only those settlements measure.
    ///
    /// This test host never advances an animation, so a smooth scroll lands
    /// after a delay instead of moving, and the native scroll ends with the
    /// callback UIKit sends when an animation finishes.
    func test_animatedTurnScrollAndJumpEachReportTheSettledRange() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        spread.webView.configuration.userContentController.removeScriptMessageHandler(forName: progressionMessageName)
        try await makeSmoothScrollsLand(after: .milliseconds(200), in: spread)
        let href = Self.longChapterHREF.anyURL

        try await assertATurnReportsTheMeasuredProgression(in: reader, animated: true)
        XCTAssertEqual(
            spread.scrollAnimationCoordinator.lastSettlementForTesting,
            .finished,
            "The animated turn waited out the fallback timer instead of its scroll-quiet signal"
        )
        let turned = try XCTUnwrap(reader.spy.locations.last?.locations.progression)

        try await assertTheSettledRangeIsReported(
            by: reader,
            in: href,
            as: "report of the scrolled page",
            where: { ($0.locations.progression ?? 0) > turned }
        ) {
            let scrollView = spread.scrollView
            let start = try await reader.requireGeometry()
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x + scrollView.bounds.width, y: 0), animated: false)
            // An animation ends only once the page has moved.
            _ = try await reader.waitForOffset(differentFrom: start)
            spread.scrollViewDidEndScrollingAnimation(scrollView)
        }
        let scrolled = try XCTUnwrap(reader.spy.locations.last?.locations.progression)

        try await assertTheSettledRangeIsReported(
            by: reader,
            in: href,
            as: "report of the jump back to the turned page",
            where: { ($0.locations.progression ?? scrolled) < scrolled }
        ) {
            let target = Locator(href: href, mediaType: .html, locations: Locator.Locations(progression: turned))
            let jumped = await reader.navigator.go(to: target, options: NavigatorGoOptions(animated: true))
            XCTAssertTrue(jumped)
        }
        XCTAssertEqual(
            spread.scrollAnimationCoordinator.lastSettlementForTesting,
            .finished,
            "The animated jump waited out the fallback timer instead of its scroll-quiet signal"
        )
    }

    private func assertATurnReportsTheMeasuredProgression(
        in reader: Reader,
        animated: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let opening = try XCTUnwrap(reader.spy.locations.last, file: file, line: line)
        let openingProgression = try XCTUnwrap(opening.locations.progression, file: file, line: line)

        // Only an advancing report can stand for the turn: a late repeat of
        // the opening position would otherwise satisfy a correct fix's test
        // with the wrong report.
        try await assertTheSettledRangeIsReported(
            by: reader,
            in: opening.href,
            as: "advancing report in the same resource",
            where: { ($0.locations.progression ?? openingProgression) > openingProgression },
            file: file,
            line: line
        ) {
            let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: animated))
            XCTAssertTrue(moved, file: file, line: line)
        }
    }

    /// Runs `action`, waits for the viewport to move, and checks that a report
    /// matching `isTheMove` arrives and every report since describes the
    /// settled viewport.
    private func assertTheSettledRangeIsReported(
        by reader: Reader,
        in href: AnyURL,
        as description: String,
        where isTheMove: @escaping (Locator) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
        after action: () async throws -> Void
    ) async throws {
        let before = try await reader.requireGeometry()
        let report = reader.spy.expectLocation(description) {
            $0.href.isEquivalentTo(href) && isTheMove($0)
        }
        try await action()
        _ = try await reader.waitForOffset(differentFrom: before)

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        _ = try XCTUnwrap(reader.spy.matchedLocation, "No \(description) arrived", file: file, line: line)
        let atMatch = try await reader.requireGeometry()

        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let settled = try await reader.requireGeometry()
        assertSettledReports(
            reader.spy.locationsSinceArming,
            isIn: href,
            matchedAt: atMatch,
            settled: settled,
            file: file,
            line: line
        )
    }

    func test_boundaryTurnWithoutMovementInventsNoAdvancement() async throws {
        let reader = try await openReader(at: Self.nextChapterHREF, minimumScreens: 1)
        let before = try await reader.requireGeometry()
        let opening = try XCTUnwrap(reader.spy.locations.last)

        let invented = reader.spy.expectNoLocation("report of a move that did not happen") {
            !$0.href.isEquivalentTo(opening.href)
                || ($0.locations.progression ?? 0) > (opening.locations.progression ?? 0)
        }
        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))
        XCTAssertFalse(moved, "The last page of the last resource has nowhere to go")

        await fulfillment(of: [invented], timeout: Self.quietWindow)
        XCTAssertNil(reader.spy.matchedLocation, "A boundary turn reported an advancement")
        let after = try await reader.requireGeometry()
        XCTAssertEqual(after.scrollX, before.scrollX, "A boundary turn moved the viewport")

        // Positive control: silence only means no move was invented if this
        // session still reports a turn that does move.
        let control = reader.spy.expectLocation("report of a turn that did move") {
            $0.href.isEquivalentTo(Self.longChapterHREF.anyURL)
        }
        let movedBack = await reader.navigator.goBackward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(movedBack)
        await fulfillment(of: [control], timeout: Self.reportTimeout)
    }

    func test_crossResourceTurnReportsTheMeasuredDestination() async throws {
        let reader = try await openReader(at: Self.nextChapterHREF, minimumScreens: 1)
        let before = try await reader.requireGeometry()

        let report = reader.spy.expectLocation("report of the previous resource") {
            $0.href.isEquivalentTo(Self.longChapterHREF.anyURL)
        }
        let moved = await reader.navigator.goBackward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)
        _ = try await reader.waitForOffset(differentFrom: before)

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        _ = try XCTUnwrap(reader.spy.matchedLocation, "No destination location was reported")
        let atMatch = try await reader.requireGeometry()

        // Turning back lands on the previous resource's last page, so a report
        // of its start would be a fabricated position, not the destination.
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let settled = try await reader.requireGeometry()
        XCTAssertGreaterThan(settled.firstProgression, 0)
        assertSettledReports(
            reader.spy.locationsSinceArming,
            isIn: Self.longChapterHREF.anyURL,
            matchedAt: atMatch,
            settled: settled
        )
    }

    /// Checks every report since the action, not only the first match: once a
    /// navigation settles, only its final location may be delivered, so a
    /// stale or fabricated report arriving around the correct one is a defect.
    /// A geometry change after the match is a new observation that a later
    /// report may replace the earlier ones with, so then only the last report
    /// must describe the settled viewport.
    private func assertSettledReports(
        _ reports: [Locator],
        isIn href: AnyURL,
        matchedAt: PageGeometry,
        settled: PageGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(reports.isEmpty, "No report to check", file: file, line: line)
        let checked = settled == matchedAt ? reports : Array(reports.suffix(1))
        let progression = settled.firstProgression
        for (index, report) in checked.enumerated() {
            XCTAssertTrue(
                report.href.isEquivalentTo(href),
                "Report \(index) is for \(report.href), not \(href)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                report.locations.progression ?? -1,
                progression,
                accuracy: 0.000_001,
                "Report \(index) does not describe the settled viewport",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Publication currency

    /// A calculation still waiting on the table of contents when the page
    /// turns never delivers the geometry it started from; the turned page is
    /// what the reader reports.
    func test_aCalculationOutlivedByATurnDeliversOnlyTheTurnedPage() async throws {
        let contents = HeldTableOfContents()
        let reader = try await openReader(tableOfContents: contents)
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await reader.waitFor("a calculation of the opening page") { contents.wasAsked }
        let before = try await reader.requireGeometry()

        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)
        _ = try await reader.waitForOffset(differentFrom: before)
        try await reader.waitFor("the turned page's measurement") {
            (spread.builtLocationObservation?.currentObservation?.sample.range.lowerBound ?? 0) > 0
        }

        try await assertOnlyTheNewGeometryIsReported(by: reader, once: contents)
    }

    /// The same holds for a native scroll, which moves no navigator state: only
    /// the changed observation keeps the old calculation from committing.
    func test_aCalculationOutlivedByAScrollDeliversOnlyTheScrolledPage() async throws {
        let contents = HeldTableOfContents()
        let reader = try await openReader(tableOfContents: contents)
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await reader.waitFor("a calculation of the opening page") { contents.wasAsked }
        let before = try await reader.requireGeometry()

        spread.scrollView.contentOffset = CGPoint(x: spread.scrollView.bounds.width, y: 0)
        _ = try await reader.waitForOffset(differentFrom: before)
        try await reader.waitFor("the scrolled page's measurement") {
            (spread.builtLocationObservation?.currentObservation?.sample.range.lowerBound ?? 0) > 0
        }

        try await assertOnlyTheNewGeometryIsReported(by: reader, once: contents)
    }

    /// An equal re-measure of the page already reported reports nothing new.
    func test_anEqualReMeasureReportsNothingNew() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        let observation = try XCTUnwrap(spread.builtLocationObservation)
        let scene = try XCTUnwrap(reader.window.windowScene, "Setup: the reader's window has no scene")
        let accepted = try XCTUnwrap(observation.currentObservation, "Setup: the opening page has no accepted observation")
        let reported = reader.spy.locations.count
        let duplicate = reader.spy.expectNoLocation("a second report of the same page") { _ in true }

        observation.invalidate()
        spread.sceneDidActivate(Notification(name: UIScene.didActivateNotification, object: scene))
        try await reader.waitFor("the re-measure") { observation.currentObservation != nil }
        XCTAssertEqual(observation.currentObservation, accepted, "Setup: the re-measure was not equal")

        await fulfillment(of: [duplicate], timeout: Self.quietWindow)
        XCTAssertEqual(reader.spy.locations.count, reported)
    }

    /// Closing the reader while a calculation waits on the table of contents
    /// releases it before the contents answer.
    func test_aClosedReaderIsReleasedDespiteAHeldCalculation() async throws {
        let contents = HeldTableOfContents()
        defer { contents.release() }
        var reader: Reader? = try await openReader(tableOfContents: contents)
        try await reader?.waitFor("a calculation of the opening page") { contents.wasAsked }
        weak let weakNavigator = reader?.navigator
        // A visible window keeps its former root controller until hidden.
        reader?.window.isHidden = true
        reader?.window.rootViewController = nil
        reader = nil

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.reportTimeout))
        while weakNavigator != nil, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(weakNavigator, "A held calculation kept the closed reader alive")
    }

    // MARK: - Fixed layout

    /// A fixed-layout reader reports its opening page and the page a turn
    /// lands on.
    func test_aFixedLayoutTurnReportsTheDestinationPage() async throws {
        let reader = try await openReader(layout: .fixed, minimumScreens: 0)
        let opening = try XCTUnwrap(reader.spy.locations.last, "The opening page was not reported")
        XCTAssertTrue(opening.href.isEquivalentTo(Self.longChapterHREF.anyURL), "The opening report named \(opening.href)")
        let report = reader.spy.expectLocation("the turned page") { $0.href.isEquivalentTo(Self.nextChapterHREF.anyURL) }

        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))

        XCTAssertTrue(moved)
        await fulfillment(of: [report], timeout: Self.reportTimeout)
    }

    private func assertOnlyTheNewGeometryIsReported(
        by reader: Reader,
        once contents: HeldTableOfContents,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertEqual(reader.spy.locations.count, 0, "A location was delivered before the table of contents answered", file: file, line: line)
        let report = reader.spy.expectLocation("the new page") { ($0.locations.progression ?? 0) > 0 }

        contents.release()

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        XCTAssertTrue(
            reader.spy.locations.allSatisfy { ($0.locations.progression ?? 0) > 0 },
            "The outlived calculation delivered the opening page",
            file: file,
            line: line
        )
        let settled = try await reader.requireGeometry()
        let last = try XCTUnwrap(reader.spy.locations.last?.locations.progression, file: file, line: line)
        XCTAssertEqual(last, settled.firstProgression, accuracy: 0.000_001, file: file, line: line)
    }

    // MARK: - Isolated-world progression read

    func test_progressionReadMeasuresLeftToRightPages() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: 600, y: 0)

        try await assertSample(page.read(ProgressionPage.capability), first: 1.0 / 3, last: 2.0 / 3)
    }

    func test_progressionReadMeasuresRightToLeftPagesByTheirNegatedOffset() async throws {
        let page = try await openProgressionPage(.rightToLeftPages)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: -600, y: 0)

        try await assertSample(page.read(ProgressionPage.capability), first: 1.0 / 3, last: 2.0 / 3)
    }

    func test_progressionReadMeasuresVerticalScroll() async throws {
        let page = try await openProgressionPage(.verticalScroll)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: 0, y: 800)

        try await assertSample(page.read(ProgressionPage.capability), first: 0.25, last: 0.5)
    }

    /// Vertical writing advances horizontally even in scroll mode.
    func test_progressionReadMeasuresVerticalWritingHorizontally() async throws {
        let page = try await openProgressionPage(.verticalWritingScroll)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: -600, y: 0)

        try await assertSample(page.read(ProgressionPage.capability), first: 1.0 / 3, last: 2.0 / 3)
    }

    /// Every vertical writing mode advances horizontally, not only the
    /// right-to-left one.
    func test_progressionReadMeasuresLeftToRightVerticalWritingHorizontally() async throws {
        let page = try await openProgressionPage(.verticalLeftToRightWritingScroll)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: 600, y: 0)

        try await assertSample(page.read(ProgressionPage.capability), first: 1.0 / 3, last: 2.0 / 3)
    }

    func test_progressionReadRejectsMalformedGeometry() async throws {
        let cases: [(document: ProgressionDocument, stub: GeometryStub)] = [
            (.leftToRightPages, .window("innerWidth", "0")),
            (.leftToRightPages, .window("innerHeight", "0")),
            (.leftToRightPages, .window("innerWidth", "Infinity")),
            (.leftToRightPages, .window("scrollX", "NaN")),
            (.leftToRightPages, .root("scrollWidth", "0")),
            (.leftToRightPages, .noRoot),
            (.verticalScroll, .window("scrollY", "NaN")),
            (.verticalScroll, .root("scrollHeight", "0")),
        ]
        for (document, stub) in cases {
            let page = try await openProgressionPage(document)
            try await page.acceptCapability(ProgressionPage.capability)
            // Control: the null below is the stub's doing only if the same
            // document measures before it.
            let unstubbed = try await page.read(ProgressionPage.capability)
            XCTAssertNotNil(unstubbed, "Setup: \(document) produced no progression before \(stub)")

            let (observed, sample) = try await page.read(ProgressionPage.capability, stubbing: stub)
            XCTAssertEqual(observed, stub.value, "\(stub) did not take effect")
            XCTAssertNil(sample, "\(stub) on \(document) produced a progression")
        }
    }

    func test_progressionReadClampsFiniteOverscroll() async throws {
        let cases: [(document: ProgressionDocument, offset: String, first: Double, last: Double)] = [
            (.leftToRightPages, "1500", 5.0 / 6, 1),
            (.leftToRightPages, "-300", 0, 1.0 / 6),
            (.rightToLeftPages, "-1500", 5.0 / 6, 1),
            // A right-to-left start overscroll is a positive offset, before
            // the first page rather than inside the resource.
            (.rightToLeftPages, "300", 0, 1.0 / 6),
        ]
        for overscroll in cases {
            let page = try await openProgressionPage(overscroll.document)
            try await page.acceptCapability(ProgressionPage.capability)

            let stub = GeometryStub.window("scrollX", overscroll.offset)
            let (observed, sample) = try await page.read(ProgressionPage.capability, stubbing: stub)
            XCTAssertEqual(observed, stub.value, "\(stub) did not take effect")
            assertSample(sample, first: overscroll.first, last: overscroll.last)
        }
    }

    /// The read is an observation: it moves no viewport, announces no frame,
    /// and leaves a command in flight to finish as it would have.
    func test_progressionReadLeavesTheDocumentAndItsCommandsAlone() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.scroll(x: 600, y: 0)

        let observed = try await page.readCountingFrameAnnouncements(ProgressionPage.capability)
        XCTAssertEqual(observed.announcementsOnAccept, 1, "Setup: the announcement spy did not see the capability's")
        XCTAssertEqual(observed.announcementsOnRead, 0, "The read announced the frame")
        XCTAssertEqual(observed.offsetAfterRead, [600, 0], "The read moved the viewport")
        assertSample(observed.sample, first: 1.0 / 3, last: 2.0 / 3)

        let undisturbed = try await page.navigate(sequence: 1, alongside: .nothing)
        XCTAssertNotEqual(undisturbed, "cancelled", "Setup: the command does not finish on its own")
        let invalidated = try await page.navigate(sequence: 2, alongside: .invalidation)
        XCTAssertEqual(invalidated, "cancelled", "Setup: this command's cancellation is not observable")
        let alongsideRead = try await page.navigate(sequence: 3, alongside: .read(ProgressionPage.capability))
        XCTAssertEqual(alongsideRead, undisturbed, "The read disturbed the command in flight")
    }

    func test_progressionReadAnswersOnlyTheCurrentCapability() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        let unissued = try await page.read(ProgressionPage.capability)
        XCTAssertNil(unissued, "A document that was never issued a capability answered")
        let unissuedAbsent = try await page.read(NSNull())
        XCTAssertNil(unissuedAbsent, "A document that was never issued a capability answered a read with none")

        try await page.acceptCapability(ProgressionPage.capability)
        try await assertSample(page.read(ProgressionPage.capability), first: 0, last: 1.0 / 3)

        let mismatched = try await page.read("another-capability")
        XCTAssertNil(mismatched, "A read under the wrong capability answered")
        let numeric = try await page.read(NSNumber(value: 42))
        XCTAssertNil(numeric, "A read under a non-string capability answered")
        let absent = try await page.read(NSNull())
        XCTAssertNil(absent, "A read with no capability answered")
    }

    func test_progressionReadRefusesARevokedCapability() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.acceptCapability(ProgressionPage.capability)
        try await assertSample(page.read(ProgressionPage.capability), first: 0, last: 1.0 / 3)

        try await page.hide()

        let revoked = try await page.read(ProgressionPage.capability)
        XCTAssertNil(revoked, "A hidden document answered under its revoked capability")
    }

    func test_progressionReadRefusesACapabilityFromAReplacedSameURLDocument() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.acceptCapability(ProgressionPage.capability)
        try await assertSample(page.read(ProgressionPage.capability), first: 0, last: 1.0 / 3)
        try await page.markDocument()

        try await page.load(.leftToRightPages)
        let isSameDocument = try await page.isMarked()
        XCTAssertFalse(isSameDocument, "Setup: reloading the same URL kept the old document")

        let inherited = try await page.read(ProgressionPage.capability)
        XCTAssertNil(inherited, "The replacement document answered under its predecessor's capability")

        let successor = "successor-capability"
        try await page.acceptCapability(successor)
        try await assertSample(page.read(successor), capability: successor, first: 0, last: 1.0 / 3)
        let stale = try await page.read(ProgressionPage.capability)
        XCTAssertNil(stale, "The predecessor's capability still answers after the successor was issued")
    }

    /// The locator command script must not carry the page world's listeners
    /// into its own world. A two-column spread with an odd page count is the
    /// page script's cue to insert a virtual column, so a page left untouched
    /// shows the isolated world never ran that resize handling.
    func test_isolatedScriptLeavesThePageLayoutAlone() async throws {
        let page = try await openProgressionPage(.oddTwoColumnSpread)
        let layout = try await page.columnLayout()
        XCTAssertEqual(layout?.columnCount, "2", "Setup: the spread is not laid out in two columns")
        XCTAssertEqual(layout?.screens, 1.5, "Setup: the spread does not have an odd page count")

        try await Task.sleep(for: Self.isolationWatchWindow)

        let inserted = try await page.hasVirtualColumn()
        XCTAssertFalse(inserted, "The isolated world inserted a virtual column into the page")
    }

    // MARK: - Bridge progression read

    /// The real hand-off registers the main frame, and the bridge's read runs
    /// in it under the capability it was issued.
    func test_bridgeReadMeasuresTheRegisteredMainFrame() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        let capability = EPUBSpreadFrameCapability()
        try await page.register(capability)
        try await page.scroll(x: 600, y: 0)

        let outcome = try await page.readThroughBridge()

        XCTAssertEqual(outcome, .sample(EPUBProgressionSample(capability: capability, range: (1.0 / 3) ... (2.0 / 3))))
    }

    func test_bridgeReadOfUnmeasurableGeometryIsUnavailable() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        let capability = EPUBSpreadFrameCapability()
        try await page.register(capability)
        let measurable = try await page.readThroughBridge()
        XCTAssertEqual(
            measurable,
            .sample(EPUBProgressionSample(capability: capability, range: 0 ... (1.0 / 3))),
            "Setup: the page did not measure before the stub"
        )

        try await page.runInCommandWorld(#"Object.defineProperty(globalThis, "innerWidth", { value: 0, configurable: true });"#)
        let unmeasurable = try await page.readThroughBridge()

        XCTAssertEqual(unmeasurable, .unavailable)
    }

    /// An answer is current only if the document and its capability are the
    /// ones the read was started for.
    func test_bridgeReadAnsweredAfterTheDocumentOrCapabilityChangedIsCancelled() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        let acrossDocuments = BridgeReadOutcomes()
        XCTAssertEqual(try page.startBridgeRead(reportingTo: acrossDocuments), .started)
        page.bridge.beginDocument()
        let documentChanged = try await acrossDocuments.single()
        XCTAssertEqual(documentChanged, .cancelled, "A read answered for the previous document was accepted")

        try await page.register(EPUBSpreadFrameCapability())
        let acrossCapabilities = BridgeReadOutcomes()
        XCTAssertEqual(try page.startBridgeRead(reportingTo: acrossCapabilities), .started)
        page.bridge.setFrameCapability(EPUBSpreadFrameCapability())
        let capabilityChanged = try await acrossCapabilities.single()
        XCTAssertEqual(capabilityChanged, .cancelled, "A read answered under a superseded capability was accepted")
    }

    /// The capability alone does not name the frame, so an answer counts only
    /// while the frame it was read in is still the selected one. The page's
    /// real echo registers the frame; the read is held until the frame changes.
    func test_bridgeReadAnsweredAfterTheSelectedFrameChangedIsCancelled() async throws {
        let held = HeldScripts()
        let page = try await openProgressionPage(.leftToRightPages, invokeLocationScript: held.invocation)
        let capability = EPUBSpreadFrameCapability()
        page.bridge.setFrameCapability(capability)
        held.complete(0, with: .success(NSNull()))
        try await page.echo(capability)
        let answer: [String: Any] = ["capability": capability.id.uuidString, "first": 0, "last": 0.5]

        let unchanged = BridgeReadOutcomes()
        XCTAssertEqual(try page.startBridgeRead(reportingTo: unchanged), .started)
        held.complete(1, with: .success(answer))
        XCTAssertEqual(
            unchanged.received,
            [.sample(EPUBProgressionSample(capability: capability, range: 0 ... 0.5))],
            "Setup: the held answer was not accepted while the frame stayed selected"
        )

        let reselected = BridgeReadOutcomes()
        XCTAssertEqual(try page.startBridgeRead(reportingTo: reselected), .started)
        try await page.echo(capability)
        held.complete(2, with: .success(answer))

        XCTAssertEqual(reselected.received, [.cancelled])
    }

    /// The registration that ends a hand-off is the one reads and commands
    /// would select, and it ends it before its deadline.
    func test_aSelectableRegistrationEndsTheHandshake() async throws {
        let deadlines = ManualDeadlines()
        let page = try await openProgressionPage(.leftToRightPages, deadlineScheduler: deadlines.scheduler)
        let capability = EPUBSpreadFrameCapability()
        try await page.register(capability)
        try await page.waitUntilTheSlotIsAvailable()

        deadlines.advance(by: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds))

        XCTAssertEqual(page.transportEvents, [.slotAvailable], "A registered hand-off still reported a failure at its deadline")
    }

    /// A frame that echoes the capability but cannot be selected, here a main
    /// frame outside the publication's origin, is neither reported as the
    /// registration nor allowed to end the hand-off.
    func test_aRegistrationThatCannotBeSelectedIsNotReported() async throws {
        let deadlines = ManualDeadlines()
        let page = try await openProgressionPage(
            .leftToRightPages,
            deadlineScheduler: deadlines.scheduler,
            publicationBaseURL: "https://elsewhere.test/"
        )
        let capability = EPUBSpreadFrameCapability()
        page.bridge.setFrameCapability(capability)
        try await page.waitUntilTheDocumentHolds(capability)
        try await page.waitUntilTheSlotIsAvailable()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(page.registrations, [], "An unselectable frame was reported as registered")
        deadlines.advance(by: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds))
        XCTAssertEqual(page.transportEvents, [.slotAvailable, .handshakeFailed(capability, .registrationMissing)])
    }

    /// A read WebKit failed is `.failed`. One unanswered by its deadline is
    /// `.expired`, and its late answer is discarded.
    func test_bridgeReadReportsAFailedCallAndAnExpiredOne() async throws {
        let held = try await openHeldRegisteredPage()
        let failed = BridgeReadOutcomes()
        XCTAssertEqual(try held.startRead(reportingTo: failed), .started)
        held.scripts.complete(1, with: .failure(URLError(.cancelled)))
        XCTAssertEqual(failed.received, [.failed])

        let expired = BridgeReadOutcomes()
        XCTAssertEqual(try held.startRead(reportingTo: expired), .started)
        held.deadlines.advance(by: HeldProgressionPage.budget)
        XCTAssertEqual(expired.received, [.expired])
        held.scripts.complete(2, with: .success(NSNull()))

        XCTAssertEqual(expired.received, [.expired], "The expired read received its late answer")
        XCTAssertEqual(
            held.page.transportEvents,
            [.slotAvailable, .slotAvailable, .lateCompletion, .slotAvailable],
            "Expected the hand-off's, the failed read's and the expired read's freed slots"
        )
    }

    /// Currency outranks the answer: a read answered after its document or
    /// capability changed is `.cancelled` even when WebKit failed it or the
    /// page answered malformed.
    func test_bridgeReadAnsweredStaleIsCancelledWhateverItsAnswer() async throws {
        let held = try await openHeldRegisteredPage()
        let failedAcrossDocuments = BridgeReadOutcomes()
        XCTAssertEqual(try held.startRead(reportingTo: failedAcrossDocuments), .started)
        held.page.bridge.beginDocument()
        held.scripts.complete(1, with: .failure(URLError(.cancelled)))
        XCTAssertEqual(failedAcrossDocuments.received, [.cancelled], "A failed read of the previous document counted")

        try await held.register(EPUBSpreadFrameCapability())
        let malformedAcrossCapabilities = BridgeReadOutcomes()
        XCTAssertEqual(try held.startRead(reportingTo: malformedAcrossCapabilities), .started)
        held.page.bridge.setFrameCapability(EPUBSpreadFrameCapability())
        held.scripts.complete(3, with: .success(["first": "malformed"]))

        XCTAssertEqual(
            malformedAcrossCapabilities.received,
            [.cancelled],
            "A malformed answer under a superseded capability counted"
        )
    }

    /// Clearing the spread silences a read in flight: neither its deadline nor
    /// its late answer reaches the caller, and the owner hears only that the
    /// slot is free.
    func test_revokingTheCapabilitySilencesAReadInFlight() async throws {
        let held = try await openHeldRegisteredPage()
        let outcomes = BridgeReadOutcomes()
        XCTAssertEqual(try held.startRead(reportingTo: outcomes), .started)

        held.page.bridge.revokeFrameCapability()
        held.deadlines.advance(by: HeldProgressionPage.budget)
        held.scripts.complete(1, with: .success(NSNull()))

        XCTAssertEqual(outcomes.received, [])
        XCTAssertEqual(held.page.transportEvents, [.slotAvailable, .slotAvailable], "Expected only freed slots")
    }

    func test_bridgeReadPastItsDeadlineReachesNoScript() async throws {
        let held = try await openHeldRegisteredPage()
        let outcomes = BridgeReadOutcomes()
        let spent = EPUBLocatorOperationDeadline(startingAt: held.deadlines.now, budget: .zero)

        XCTAssertEqual(try held.startRead(until: spent, reportingTo: outcomes), .deadlinePassed)

        XCTAssertEqual(held.scripts.count, 1, "A read past its deadline reached WebKit")
        XCTAssertEqual(outcomes.received, [])
    }

    func test_bridgeReadStartsNothingWithoutAFrameOrBesideAnotherCall() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        XCTAssertEqual(try page.startBridgeRead(reportingTo: BridgeReadOutcomes()), .frameUnavailable)

        try await page.register(EPUBSpreadFrameCapability())
        let first = BridgeReadOutcomes()
        XCTAssertEqual(try page.startBridgeRead(reportingTo: first), .started)
        XCTAssertEqual(try page.startBridgeRead(reportingTo: BridgeReadOutcomes()), .transportOccupied)
        _ = try await first.single()
    }

    /// A retried hand-off echoes the same capability again from a new frame
    /// handle. The main frame is replaced, not registered twice, so it stays
    /// selectable.
    func test_aRepeatedEchoOfTheCurrentCapabilityReplacesTheMainFrame() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        let capability = EPUBSpreadFrameCapability()
        try await page.register(capability)

        try await page.register(capability)
        let outcome = try await page.readThroughBridge()

        XCTAssertEqual(page.registrations, [capability, capability])
        XCTAssertEqual(outcome, .sample(EPUBProgressionSample(capability: capability, range: 0 ... (1.0 / 3))))
    }

    // MARK: - Settlement signals in a real reader

    /// Any page script can post `progressionChanged`, with any numbers. They
    /// are never reported: the message only asks the spread to measure.
    func test_aPageWorldProgressionMessageIsMeasuredNotTrusted() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        let observation = try XCTUnwrap(spread.builtLocationObservation)
        let settled = try await reader.requireGeometry()
        observation.invalidate()
        let forged = reader.spy.expectNoLocation("report of the page world's numbers") {
            ($0.locations.progression ?? 0) > 0.5
        }

        _ = try await spread.webView.evaluateJavaScript(
            "webkit.messageHandlers.progressionChanged.postMessage({first: 0.9, last: 0.95}); true"
        )

        await fulfillment(of: [forged], timeout: Self.quietWindow)
        try await reader.waitFor("the measurement the message asked for") { observation.currentObservation != nil }
        XCTAssertEqual(
            spread.progression(in: spread.spread.first.index).lowerBound,
            settled.firstProgression,
            accuracy: 0.000_001,
            "The spread reported the page world's numbers"
        )
    }

    /// Only the scene showing the reader measures again when it becomes
    /// active; an activation from any other sender leaves it alone.
    func test_onlyTheOwningSceneBecomingActiveMeasuresAgain() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        let observation = try XCTUnwrap(spread.builtLocationObservation)
        let scene = try XCTUnwrap(reader.window.windowScene, "Setup: the reader's window has no scene")
        observation.invalidate()

        // Delivered by hand: posting an activation whose object is not a
        // scene aborted the test host. A grant starts a read or retains an
        // obligation at once.
        spread.sceneDidActivate(Notification(name: UIScene.didActivateNotification, object: NSObject()))
        spread.sceneDidActivate(Notification(name: UIScene.didActivateNotification, object: nil))
        XCTAssertFalse(observation.isReading || observation.hasObligation, "Another sender's activation measured the reader")

        spread.sceneDidActivate(Notification(name: UIScene.didActivateNotification, object: scene))
        XCTAssertTrue(observation.isReading || observation.hasObligation, "The owning scene's activation asked for nothing")
        try await reader.waitFor("a fresh measurement") { observation.currentObservation != nil }
    }

    // MARK: - Page-world scroll hint

    /// Scroll events within one frame coalesce into a single hint carrying the
    /// latest measurement.
    func test_scrollHintPostsTheLatestMeasurementOncePerFrame() async throws {
        let page = try await openProgressionPage(.leftToRightPages, carryingReflowableScript: true)

        let hints = try await page.hintsPosted(running: """
        scrollTo(300, 0);
        dispatchEvent(new Event("scroll"));
        scrollTo(600, 0);
        dispatchEvent(new Event("scroll"));
        """)

        XCTAssertEqual(hints.count, 1, "Expected one hint for one frame, got \(hints)")
        assertSample(hints.first, capability: nil, first: 1.0 / 3, last: 2.0 / 3)
    }

    /// Fixed layout posts no hint, and neither does geometry that cannot be
    /// measured, including geometry that stops being measurable after a hint
    /// was scheduled within the same frame.
    func test_scrollHintPostsNothingForFixedLayoutOrUnmeasurableGeometry() async throws {
        let page = try await openProgressionPage(.leftToRightPages, carryingReflowableScript: true)
        let control = try await page.hintsPosted(running: """
        scrollTo(600, 0);
        dispatchEvent(new Event("scroll"));
        """)
        XCTAssertFalse(control.isEmpty, "Setup: a measurable scroll posted no hint")

        let fixedLayout = try await page.hintsPosted(running: """
        readium.isFixedLayout = true;
        scrollTo(300, 0);
        dispatchEvent(new Event("scroll"));
        """)
        XCTAssertTrue(fixedLayout.isEmpty, "A fixed-layout scroll posted \(fixedLayout)")

        let unmeasurableWithinFrame = try await page.hintsPosted(running: """
        readium.isFixedLayout = false;
        scrollTo(900, 0);
        dispatchEvent(new Event("scroll"));
        Object.defineProperty(window, "innerWidth", { value: 0, configurable: true });
        dispatchEvent(new Event("scroll"));
        """)
        XCTAssertTrue(
            unmeasurableWithinFrame.isEmpty,
            "Geometry that became unmeasurable before the frame posted \(unmeasurableWithinFrame)"
        )

        let unmeasurable = try await page.hintsPosted(running: """
        scrollTo(1200, 0);
        dispatchEvent(new Event("scroll"));
        """)
        XCTAssertTrue(unmeasurable.isEmpty, "Unmeasurable geometry posted \(unmeasurable)")
    }

    /// A read returns exactly the capability it answered under and the
    /// measured range, and a page-world hint (`capability` nil) the range
    /// alone; anything more or less is malformed.
    private func assertSample(
        _ value: Any?,
        capability: String? = ProgressionPage.capability,
        first: Double,
        last: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let sample = value as? [String: Any] else {
            XCTFail("Expected a progression sample, got \(String(describing: value))", file: file, line: line)
            return
        }
        let expectedKeys: Set<String> = capability == nil ? ["first", "last"] : ["capability", "first", "last"]
        XCTAssertEqual(Set(sample.keys), expectedKeys, file: file, line: line)
        XCTAssertEqual(sample["capability"] as? String, capability, file: file, line: line)
        XCTAssertEqual((sample["first"] as? NSNumber)?.doubleValue ?? -1, first, accuracy: 0.000_001, "first", file: file, line: line)
        XCTAssertEqual((sample["last"] as? NSNumber)?.doubleValue ?? -1, last, accuracy: 0.000_001, "last", file: file, line: line)
    }

    // MARK: - Fixture

    /// The production debounce is 300 ms; a report that has not arrived well
    /// past it is missing, not late.
    private static let reportTimeout: TimeInterval = 10

    /// How long an absent report is watched for. Several times the production
    /// debounce, so a late report of an invented move would land inside it.
    private static let quietWindow: TimeInterval = 2

    /// Page-world resize handling runs within a frame or two of load; the
    /// window is many times that.
    private static let isolationWatchWindow: Duration = .seconds(1)

    private static let longChapterHREF = RelativeURL(path: "long.html")!
    private static let nextChapterHREF = RelativeURL(path: "next.html")!

    private func openReader(
        at href: RelativeURL = longChapterHREF,
        layout: ReadiumShared.Layout = .reflowable,
        minimumScreens: Int = 3,
        tableOfContents: HeldTableOfContents? = nil
    ) async throws -> Reader {
        let initialLocation = Locator(
            href: href.anyURL,
            mediaType: .html,
            locations: Locator.Locations(progression: 0)
        )
        let navigator = try EPUBNavigatorViewController(
            publication: makePublication(layout: layout, tableOfContents: tableOfContents),
            initialLocation: initialLocation,
            config: EPUBNavigatorViewController.Configuration()
        )
        let spy = LocationReportSpy()
        navigator.delegate = spy

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        window.rootViewController = navigator
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }

        let reader = Reader(window: window, navigator: navigator, spy: spy)
        // A held table of contents holds the opening report too.
        let requiringReport = tableOfContents == nil
        try await reader.waitUntilUsable(minimumScreens: minimumScreens, requiringReport: requiringReport)
        if requiringReport {
            try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        }
        return reader
    }

    /// This host never advances an animation: a UIKit or WebKit smooth scroll
    /// leaves the offset where it was. So a smooth scroll the page asks for
    /// lands at once after `delay`, as an animation lands after its duration;
    /// an instant one lands immediately.
    private func makeSmoothScrollsLand(after delay: Duration, in spread: EPUBSpreadView) async throws {
        _ = try await spread.webView.callAsyncJavaScript(
            """
            const landing = original => function (options) {
                if (options?.behavior !== 'smooth') {
                    return original.call(this, options);
                }
                setTimeout(() => original.call(this, { ...options, behavior: 'instant' }), delayMilliseconds);
            };
            window.scrollBy = landing(window.scrollBy).bind(window);
            Element.prototype.scrollTo = landing(Element.prototype.scrollTo);
            return true;
            """,
            arguments: ["delayMilliseconds": Double(delay.components.seconds * 1000) + Double(delay.components.attoseconds) / 1e15],
            in: nil,
            contentWorld: .page
        )
    }

    private func openProgressionPage(
        _ document: ProgressionDocument,
        carryingReflowableScript: Bool = false,
        invokeLocationScript: EPUBLocatorCommandBridge.LocationScriptInvocation? = nil,
        deadlineScheduler: EPUBDeadlineScheduler? = nil,
        publicationBaseURL: String = "https://readium.test/"
    ) async throws -> ProgressionPage {
        let page = try ProgressionPage(
            carryingReflowableScript: carryingReflowableScript,
            invokeLocationScript: invokeLocationScript,
            deadlineScheduler: deadlineScheduler,
            publicationBaseURL: publicationBaseURL
        )
        addTeardownBlock { @MainActor in
            page.window.isHidden = true
            page.window.rootViewController = nil
        }
        try await page.load(document)
        if carryingReflowableScript {
            try await page.waitForLoadHintsToSettle()
        }
        return page
    }

    /// A page whose location calls and deadlines the test controls, registered
    /// through its real echo. Its hand-off was location call 0.
    private func openHeldRegisteredPage() async throws -> HeldProgressionPage {
        let scripts = HeldScripts()
        let deadlines = ManualDeadlines()
        let page = try await openProgressionPage(
            .leftToRightPages,
            invokeLocationScript: scripts.invocation,
            deadlineScheduler: deadlines.scheduler
        )
        let held = HeldProgressionPage(page: page, scripts: scripts, deadlines: deadlines)
        try await held.register(EPUBSpreadFrameCapability())
        return held
    }

    private func makePublication(layout: ReadiumShared.Layout = .reflowable, tableOfContents: HeldTableOfContents? = nil) -> Publication {
        let paragraphs = (1 ... 160)
            .map { "<p>Synthetic paragraph \($0). The quick brown fox jumps over the lazy dog, again and again, to fill the page.</p>" }
            .joined()
        let longChapter = "<!doctype html><html><head><title>Long</title></head><body>\(paragraphs)</body></html>"
        let nextChapter = "<!doctype html><html><head><title>Next</title></head><body><p>Next chapter.</p></body></html>"
        let readingOrder = [
            Link(href: Self.longChapterHREF.string, mediaType: .html),
            Link(href: Self.nextChapterHREF.string, mediaType: .html),
        ]
        return Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Settled location reporting", layout: layout),
                readingOrder: readingOrder
            ),
            container: CompositeContainer(
                SingleResourceContainer(
                    resource: DataResource(string: longChapter),
                    at: Self.longChapterHREF.anyURL
                ),
                SingleResourceContainer(
                    resource: DataResource(string: nextChapter),
                    at: Self.nextChapterHREF.anyURL
                )
            ),
            servicesBuilder: PublicationServicesBuilder { builder in
                if let tableOfContents {
                    builder.setTableOfContentsServiceFactory { _ in tableOfContents }
                }
            }
        )
    }
}

/// The hosted navigator plus the independent DOM oracle the assertions compare
/// against. The oracle reads the web view's geometry in its own content world,
/// so nothing it does can be mistaken for a navigator progression message.
@MainActor
private struct Reader {
    let window: UIWindow
    let navigator: EPUBNavigatorViewController
    let spy: LocationReportSpy

    /// Liveness backstop for setup, not a performance bound.
    private static let setupTimeout: Duration = .seconds(30)

    var currentSpread: EPUBSpreadView? {
        navigator.paginationView?.currentView as? EPUBSpreadView
    }

    /// Waits for a ready spread whose paginated content spans enough screens,
    /// and for the navigator's opening report, so the turn under test starts
    /// from a settled page and cannot be confused with the opening.
    func waitUntilUsable(minimumScreens: Int, requiringReport: Bool = true) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var lastGeometry: PageGeometry?
        while clock.now < deadline {
            if
                !requiringReport || !spy.locations.isEmpty,
                let spread = currentSpread,
                spread.readiness.isCommandReady,
                let geometry = try await geometry()
            {
                lastGeometry = geometry
                if geometry.innerWidth > 0, geometry.scrollWidth >= geometry.innerWidth * Double(minimumScreens) {
                    return
                }
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let diagnosis = """
        reports=\(spy.locations.count), \
        state=\(currentSpread.map { "\($0.readiness.state)" } ?? "no spread"), \
        isLoading=\(currentSpread.map { "\($0.webView.isLoading)" } ?? "no spread"), \
        geometry=\(lastGeometry.map { "\($0)" } ?? "unmeasured")
        """

        // Skip only on the #1693 signature: a WebContent process that stopped
        // answering mid-load leaves readiness `.loading` while WebKit still
        // reports loading, and answers no script. A process that answers has a
        // load the navigator left pending; that and every other expiry is a
        // navigator defect.
        if
            let spread = currentSpread,
            case .loading = spread.readiness.state,
            spread.webView.isLoading,
            try await !contentProcessAnswers(spread.webView)
        {
            throw XCTSkip(
                "Setup: WebContent process is not answering (see #1693). \(diagnosis)"
            )
        }
        XCTFail("Setup: the reader never reached a usable paginated viewport with an opening report. \(diagnosis)")
        throw SetupTimeout()
    }

    /// Waits until no location has been reported for `window`, so the checks
    /// that follow see the navigator's final word on the current page.
    func waitForReportsToSettle(quietFor window: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var reportCount = spy.locations.count
        var lastReport = clock.now
        while clock.now < deadline {
            if spy.locations.count != reportCount {
                reportCount = spy.locations.count
                lastReport = clock.now
            } else if lastReport.duration(to: clock.now) >= window {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Location reports never went quiet for \(window); reports=\(spy.locations.count)")
        throw SetupTimeout()
    }

    func requireGeometry() async throws -> PageGeometry {
        let measured = try await geometry()
        return try XCTUnwrap(measured, "Setup: the current spread's geometry is not measurable")
    }

    /// Polls until `condition` holds, failing with `description` otherwise.
    func waitFor(_ description: String, until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while clock.now < deadline {
            if condition() {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(description)")
        throw SetupTimeout()
    }

    /// Waits for the DOM to show the turn actually moved the viewport, so a
    /// missing report cannot be explained away by a turn that did nothing.
    func waitForOffset(differentFrom before: PageGeometry) async throws -> PageGeometry {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while clock.now < deadline {
            if let geometry = try await geometry(), geometry.scrollX != before.scrollX {
                return geometry
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("The turn returned success but the viewport offset never changed from \(before.scrollX)")
        throw SetupTimeout()
    }

    private func geometry() async throws -> PageGeometry? {
        guard let webView = currentSpread?.webView else {
            return nil
        }
        let value = try await webView.callAsyncJavaScript(
            """
            const root = document.scrollingElement;
            return root ? [window.scrollX, window.innerWidth, root.scrollWidth] : null;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let numbers = value as? [NSNumber], numbers.count == 3 else {
            return nil
        }
        return PageGeometry(
            scrollX: numbers[0].doubleValue,
            innerWidth: numbers[1].doubleValue,
            scrollWidth: numbers[2].doubleValue
        )
    }
}

private struct PageGeometry: Equatable, CustomStringConvertible {
    let scrollX: Double
    let innerWidth: Double
    let scrollWidth: Double

    /// The paginated (LTR or RTL) start of the viewport within the resource.
    var firstProgression: Double {
        abs(scrollX) / scrollWidth
    }

    var description: String {
        "scrollX=\(scrollX), innerWidth=\(innerWidth), scrollWidth=\(scrollWidth)"
    }
}

private struct SetupTimeout: Error {}

/// Whether the web view's content process answers a trivial script within
/// `timeout`. The #1693 hang leaves it unanswered; a live process answers at
/// once even while a load is pending.
@MainActor
private func contentProcessAnswers(_ webView: WKWebView, within timeout: Duration = .seconds(5)) async throws -> Bool {
    let answer = ScriptAnswer()
    webView.evaluateJavaScript("1") { _, _ in
        answer.isReceived = true
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !answer.isReceived, clock.now < deadline {
        try await clock.sleep(for: .milliseconds(20))
    }
    return answer.isReceived
}

@MainActor
private final class ScriptAnswer {
    var isReceived = false
}

/// Documents whose geometry is fixed by construction, so every expected
/// progression is a constant rather than something read back from the page.
/// All but the odd spread fill a 600×800 viewport three or four times over
/// along one axis; the odd spread lays out three 300 px columns, one and a
/// half screens.
private enum ProgressionDocument {
    case leftToRightPages
    case rightToLeftPages
    case verticalScroll
    case verticalWritingScroll
    case verticalLeftToRightWritingScroll
    case oddTwoColumnSpread

    var html: String {
        switch self {
        case .leftToRightPages:
            Self.page(rootAttributes: "", width: 1800, height: 800)
        case .rightToLeftPages:
            Self.page(rootAttributes: #"dir="rtl""#, width: 1800, height: 800)
        case .verticalScroll:
            Self.page(rootAttributes: #"style="--USER__view: readium-scroll-on""#, width: 600, height: 3200)
        case .verticalWritingScroll:
            Self.page(
                rootAttributes: #"style="writing-mode: vertical-rl; --USER__view: readium-scroll-on""#,
                width: 1800,
                height: 800
            )
        case .verticalLeftToRightWritingScroll:
            Self.page(
                rootAttributes: #"style="writing-mode: vertical-lr; --USER__view: readium-scroll-on""#,
                width: 1800,
                height: 800
            )
        case .oddTwoColumnSpread:
            Self.page(
                rootAttributes: #"style="height: 800px; column-count: 2; column-gap: 0; column-fill: auto""#,
                width: 600,
                height: 2400
            )
        }
    }

    private static func page(rootAttributes: String, width: Int, height: Int) -> String {
        """
        <!doctype html><html \(rootAttributes)><head>\
        <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, shrink-to-fit=no">\
        <style>html, body { margin: 0; padding: 0; }</style>\
        </head><body><div style="width: \(width)px; height: \(height)px"></div></body></html>
        """
    }
}

/// One geometry input replaced, in the read's own content world, just before
/// the read. The page reports the input back, so a stub that did not take
/// effect cannot pass as a rejection.
private enum GeometryStub: CustomStringConvertible {
    case window(String, String)
    case root(String, String)
    case noRoot

    var owner: String {
        switch self {
        case .window: "window"
        case .root: "root"
        case .noRoot: "document"
        }
    }

    var property: String {
        switch self {
        case let .window(name, _), let .root(name, _): name
        case .noRoot: "scrollingElement"
        }
    }

    var value: String {
        switch self {
        case let .window(_, value), let .root(_, value): value
        case .noRoot: "null"
        }
    }

    var description: String {
        "\(owner).\(property) = \(value)"
    }
}

/// A bare web view carrying the locator command script, hosted at the
/// navigator tests' 600×800 size. Nothing here mints readiness or registers a
/// frame: the capability is issued straight to the document under test. On
/// request it also carries the page-world reflowable script, injected as a
/// spread injects it, with every message that script posts recorded and none
/// acted on.
@MainActor
private final class ProgressionPage {
    static let capability = "settled-location-test-capability"
    private static let url = URL(string: "https://readium.test/chapter.xhtml")!
    private static let setupTimeout: Duration = .seconds(30)

    /// A hint is scheduled for the next animation frame, so a quarter second
    /// without one means none is coming.
    private static let hintQuietWindow: Duration = .milliseconds(250)

    let window: UIWindow
    let webView: WKWebView
    /// Installed and attached as a reflowable spread installs it, so its
    /// hand-off and reads run against this page. No capability is issued
    /// through it unless a test registers one.
    let bridge: EPUBLocatorCommandBridge
    private let loads = LoadObserver()
    private let pageMessages = PageMessageRecorder()
    private(set) var registrations: [EPUBSpreadFrameCapability] = []
    private(set) var transportEvents: [EPUBLocationTransportEvent] = []

    /// - Parameters:
    ///   - invokeLocationScript: replaces the bridge's location calls, for a
    ///     test that must hold one open while the page changes under it.
    ///   - deadlineScheduler: replaces the bridge's deadlines, for a test that
    ///     must pass one without waiting it out.
    ///   - publicationBaseURL: the bridge's publication origin; another origin
    ///     makes the page's main frame register as cross-origin.
    init(
        carryingReflowableScript: Bool = false,
        invokeLocationScript: EPUBLocatorCommandBridge.LocationScriptInvocation? = nil,
        deadlineScheduler: EPUBDeadlineScheduler? = nil,
        publicationBaseURL: String = "https://readium.test/"
    ) throws {
        bridge = try EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: XCTUnwrap(HTTPURL(string: publicationBaseURL)),
            deadlineScheduler: deadlineScheduler,
            invokeLocationScript: invokeLocationScript
        )
        let configuration = WKWebViewConfiguration()
        // iPad's desktop-class default scales wide content down to fit, which
        // would change the viewport the expected progressions are built on.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        bridge.install(in: configuration)
        if carryingReflowableScript {
            configuration.userContentController.addUserScript(WKUserScript(
                source: EPUBSpreadView.loadScript(named: "readium-reflowable"),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            for name in PageMessageRecorder.names {
                configuration.userContentController.add(pageMessages, name: name)
            }
        }
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        webView = WKWebView(frame: window.bounds, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = loads
        let host = UIViewController()
        host.view.addSubview(webView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        bridge.attach(to: webView)
        bridge.onFrameRegistered = { [unowned self] capability in
            registrations.append(capability)
        }
        bridge.onLocationTransportEvent = { [unowned self] event in
            transportEvents.append(event)
        }
    }

    /// Issues `capability` through the bridge's hand-off and waits for the
    /// page's main frame to register under it.
    func register(_ capability: EPUBSpreadFrameCapability) async throws {
        let before = registrations.count
        bridge.setFrameCapability(capability)
        try await waitUntil("the main frame registers") {
            self.registrations.count > before && self.registrations.last == capability
        }
    }

    /// Starts a bridge read of this page's resource, by default with the full
    /// budget from now.
    func startBridgeRead(
        until deadline: EPUBLocatorOperationDeadline? = nil,
        reportingTo outcomes: BridgeReadOutcomes
    ) throws -> EPUBLocatorCommandBridge.ProgressionReadStart {
        try bridge.readProgression(
            targetHREF: XCTUnwrap(AnyURL(string: "chapter.xhtml")),
            deadline: deadline ?? EPUBLocatorOperationDeadline(
                startingAt: ContinuousClock().now,
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            ),
            completion: { outcomes.received.append($0) }
        )
    }

    /// Reads this page's resource through the bridge and waits for the one
    /// outcome the started read owes.
    func readThroughBridge() async throws -> EPUBProgressionReadOutcome {
        let outcomes = BridgeReadOutcomes()
        let start = try startBridgeRead(reportingTo: outcomes)
        XCTAssertEqual(start, .started, "Setup: the bridge read did not start")
        return try await outcomes.single()
    }

    /// Runs `script` in the locator command world of this page.
    func runInCommandWorld(_ script: String, arguments: [String: Any] = [:]) async throws {
        _ = try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
    }

    /// Waits until the document answers a read under `capability`, which it
    /// can do only once the hand-off has reached it.
    func waitUntilTheDocumentHolds(_ capability: EPUBSpreadFrameCapability) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while try await read(capability.id.uuidString) == nil {
            guard clock.now < deadline else {
                XCTFail("Setup: the document never received the capability")
                throw SetupTimeout()
            }
            try await clock.sleep(for: .milliseconds(20))
        }
    }

    /// Waits until the bridge reports a freed location slot.
    func waitUntilTheSlotIsAvailable() async throws {
        try await waitUntil("the location slot is reported available") {
            self.transportEvents.contains(.slotAvailable)
        }
    }

    /// Hands `capability` to the document directly, as an injection would, and
    /// waits for the registration its echo produces.
    func echo(_ capability: EPUBSpreadFrameCapability) async throws {
        let before = registrations.count
        try await runInCommandWorld(
            "readerLocatorCommands.acceptFrameCapability(capability);",
            arguments: ["capability": capability.id.uuidString]
        )
        try await waitUntil("the echo registers") {
            self.registrations.count > before
        }
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Setup: timed out waiting until \(description)")
                throw SetupTimeout()
            }
            try await clock.sleep(for: .milliseconds(20))
        }
    }

    /// Loads `document` at the same URL every time, so a second load is a
    /// same-URL replacement of the first document.
    func load(_ document: ProgressionDocument) async throws {
        let navigation = webView.loadHTMLString(document.html, baseURL: Self.url)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while clock.now < deadline, !loads.hasFinished(navigation) {
            try await clock.sleep(for: .milliseconds(20))
        }
        guard loads.hasFinished(navigation) else {
            let diagnosis = "isLoading=\(webView.isLoading), progress=\(webView.estimatedProgress)"
            // Same earned skip as the navigator setup: only a pending load whose
            // content process answers no script points at the #1693 hang.
            if webView.isLoading, try await !contentProcessAnswers(webView) {
                throw XCTSkip("Setup: WebContent process is not answering (see #1693). \(diagnosis)")
            }
            XCTFail("Setup: the document never finished loading. \(diagnosis)")
            throw SetupTimeout()
        }
        let viewport = try await webView.callAsyncJavaScript(
            "return [innerWidth, innerHeight];",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? [NSNumber]
        guard viewport?.map(\.doubleValue) == [600, 800] else {
            XCTFail("Setup: the expected progressions assume a 600×800 viewport, got \(String(describing: viewport))")
            throw SetupTimeout()
        }
        try await waitForCommittedContentSize()
    }

    /// Waits until the scroll view holds the document's content size. The
    /// first commit that brings it sets the document's initial scroll origin,
    /// which returns a right-to-left document scrolled before then to 0.
    private func waitForCommittedContentSize() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var documentSize: [Double]?
        while clock.now < deadline {
            documentSize = try await (webView.callAsyncJavaScript(
                "const root = document.scrollingElement; return [root.scrollWidth, root.scrollHeight];",
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            ) as? [NSNumber])?.map(\.doubleValue)
            let contentSize = webView.scrollView.contentSize
            if documentSize == [contentSize.width, contentSize.height] {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail(
            "Setup: the scroll view never took the document's size \(String(describing: documentSize)); " +
                "it holds \(webView.scrollView.contentSize)"
        )
        throw SetupTimeout()
    }

    func acceptCapability(_ capability: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "readerLocatorCommands.acceptFrameCapability(capability);",
            arguments: ["capability": capability],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
    }

    func scroll(x: Double, y: Double) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var offset: [Double]?
        while clock.now < deadline {
            offset = try await (webView.callAsyncJavaScript(
                "window.scrollTo(x, y); return [scrollX, scrollY];",
                arguments: ["x": x, "y": y],
                in: nil,
                contentWorld: .defaultClient
            ) as? [NSNumber])?.map(\.doubleValue)
            if offset == [x, y] {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Setup: the page never scrolled to (\(x), \(y)); offset=\(String(describing: offset))")
        throw SetupTimeout()
    }

    func read(_ capability: Any) async throws -> Any? {
        let value = try await webView.callAsyncJavaScript(
            "return readerLocatorCommands.readProgression(expectedCapability);",
            arguments: ["expectedCapability": capability],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return value is NSNull ? nil : value
    }

    /// Applies `stub` and reads under `capability` in one call, returning what
    /// the stubbed input reads back as alongside the read's result.
    func read(_ capability: String, stubbing stub: GeometryStub) async throws -> (observed: String?, sample: Any?) {
        let value = try await webView.callAsyncJavaScript(
            """
            const target = owner === "root" ? document.scrollingElement
                : owner === "document" ? document : globalThis;
            Object.defineProperty(target, property, {
                value: owner === "document" ? null : Number(value),
                configurable: true,
            });
            return {
                observed: String(target[property]),
                sample: readerLocatorCommands.readProgression(expectedCapability),
            };
            """,
            arguments: [
                "owner": stub.owner,
                "property": stub.property,
                "value": stub.value,
                "expectedCapability": capability,
            ],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? [String: Any]
        let sample = value?["sample"]
        return (value?["observed"] as? String, sample is NSNull ? nil : sample)
    }

    /// Issues `capability`, then reads under it, counting the frame-ready
    /// announcements each step posts and recording the offset the read leaves.
    func readCountingFrameAnnouncements(_ capability: String) async throws -> FrameAnnouncementObservation {
        let value = try await webView.callAsyncJavaScript(
            """
            const handler = webkit.messageHandlers.readerLocatorFrameReady;
            const post = handler.postMessage.bind(handler);
            let announcements = 0;
            handler.postMessage = (body) => {
                announcements += 1;
                return post(body);
            };
            readerLocatorCommands.acceptFrameCapability(capability);
            const onAccept = announcements;
            const sample = readerLocatorCommands.readProgression(capability);
            return {
                onAccept,
                onRead: announcements - onAccept,
                offset: [scrollX, scrollY],
                sample,
            };
            """,
            arguments: ["capability": capability],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? [String: Any]
        let sample = value?["sample"]
        return FrameAnnouncementObservation(
            announcementsOnAccept: (value?["onAccept"] as? NSNumber)?.intValue,
            announcementsOnRead: (value?["onRead"] as? NSNumber)?.intValue,
            offsetAfterRead: (value?["offset"] as? [NSNumber])?.map(\.doubleValue),
            sample: sample is NSNull ? nil : sample
        )
    }

    enum CommandCompanion {
        case nothing
        case invalidation
        case read(String)
    }

    /// Starts a navigation command to the document's only element and, in the
    /// same turn, before the command can reach its first animation frame, does
    /// `companion`. Returns the command's outcome.
    func navigate(sequence: Int, alongside companion: CommandCompanion) async throws -> String? {
        let (companionKind, capability): (String, String) = switch companion {
        case .nothing: ("nothing", "")
        case .invalidation: ("invalidation", "")
        case let .read(capability): ("read", capability)
        }
        return try await webView.callAsyncJavaScript(
            """
            const token = {
                webViewInstanceID: "settled-location-test",
                documentEpoch: 0,
                operationKind: "navigation",
                sequence,
                budgetMilliseconds: 10000,
            };
            const pending = readerLocatorCommands.execute(
                { kind: "navigateLocator", payload: locator, animated: false },
                token
            );
            if (companionKind === "invalidation") {
                readerLocatorCommands.invalidate(token);
            } else if (companionKind === "read") {
                readerLocatorCommands.readProgression(capability);
            }
            return (await pending).outcome;
            """,
            arguments: [
                "sequence": sequence,
                "locator": #"{"href":"chapter.xhtml","locations":{"cssSelector":"body > div"}}"#,
                "companionKind": companionKind,
                "capability": capability,
            ],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? String
    }

    /// Waits out the hint the load itself posts: the reflowable script
    /// measures once its resize observer first fires.
    func waitForLoadHintsToSettle() async throws {
        try await waitForHintsToSettle(after: 0, requiringOne: true)
    }

    /// Runs `script` in the page world and returns every progression hint
    /// posted from then until the hints go quiet.
    func hintsPosted(running script: String) async throws -> [Any] {
        let start = pageMessages.hints.count
        _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        try await waitForHintsToSettle(after: start, requiringOne: false)
        return Array(pageMessages.hints[start...])
    }

    private func waitForHintsToSettle(after start: Int, requiringOne: Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var count = pageMessages.hints.count
        var lastChange = clock.now
        while clock.now < deadline {
            if pageMessages.hints.count != count {
                count = pageMessages.hints.count
                lastChange = clock.now
            } else if
                lastChange.duration(to: clock.now) >= Self.hintQuietWindow,
                !requiringOne || count > start
            {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Setup: progression hints never settled; hints=\(pageMessages.hints.count - start)")
        throw SetupTimeout()
    }

    func columnLayout() async throws -> (columnCount: String, screens: Double)? {
        let value = try await webView.callAsyncJavaScript(
            """
            const root = document.scrollingElement;
            return [getComputedStyle(document.documentElement).columnCount, root.scrollWidth / innerWidth];
            """,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? [Any]
        guard let columnCount = value?.first as? String, let screens = value?.last as? NSNumber else {
            return nil
        }
        return (columnCount, screens.doubleValue)
    }

    func hasVirtualColumn() async throws -> Bool {
        try await webView.callAsyncJavaScript(
            #"return document.getElementById("readium-virtual-page") !== null;"#,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? Bool == true
    }

    /// Fires the `pagehide` the document receives when it stops being current.
    func hide() async throws {
        _ = try await webView.callAsyncJavaScript(
            #"window.dispatchEvent(new PageTransitionEvent("pagehide"));"#,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    func markDocument() async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.settledLocationTestMarker = true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    func isMarked() async throws -> Bool {
        try await webView.callAsyncJavaScript(
            "return window.settledLocationTestMarker === true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? Bool == true
    }
}

/// A progression page whose bridge reaches no real location call: each one is
/// held until the test answers it, and its deadlines pass only when the test
/// advances them.
@MainActor
private struct HeldProgressionPage {
    static let budget: Duration = .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)

    let page: ProgressionPage
    let scripts: HeldScripts
    let deadlines: ManualDeadlines

    /// Hands `capability` off with the slot free, answers the held injection,
    /// and waits for the page's real echo to register it.
    func register(_ capability: EPUBSpreadFrameCapability) async throws {
        page.bridge.setFrameCapability(capability)
        scripts.complete(scripts.count - 1, with: .success(NSNull()))
        try await page.echo(capability)
    }

    /// Starts a bridge read, by default with the full budget from the held now.
    func startRead(
        until deadline: EPUBLocatorOperationDeadline? = nil,
        reportingTo outcomes: BridgeReadOutcomes
    ) throws -> EPUBLocatorCommandBridge.ProgressionReadStart {
        try page.startBridgeRead(
            until: deadline ?? EPUBLocatorOperationDeadline(startingAt: deadlines.now, budget: Self.budget),
            reportingTo: outcomes
        )
    }
}

/// The outcomes a bridge read delivered, in order.
@MainActor
private final class BridgeReadOutcomes {
    var received: [EPUBProgressionReadOutcome] = []

    /// Waits for the started read's outcome, then confirms no second one
    /// follows it.
    func single() async throws -> EPUBProgressionReadOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while received.isEmpty {
            guard clock.now < deadline else {
                XCTFail("The started bridge read never delivered an outcome")
                throw SetupTimeout()
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        try await clock.sleep(for: .milliseconds(100))
        XCTAssertEqual(received.count, 1, "The bridge read delivered more than one outcome: \(received)")
        return received[0]
    }
}

private struct FrameAnnouncementObservation {
    let announcementsOnAccept: Int?
    let announcementsOnRead: Int?
    let offsetAfterRead: [Double]?
    let sample: Any?
}

/// Records the page-world script's progression hints. Every message name the
/// reflowable script posts to is registered, so no post throws for want of a
/// handler.
@MainActor
private final class PageMessageRecorder: NSObject, WKScriptMessageHandler {
    static let names = [
        "decorationActivated",
        "imageActivated",
        "keyEventReceived",
        "log",
        "logError",
        "pointerEventReceived",
        progressionMessageName,
        "selectionChanged",
        "spreadLoadStarted",
        "spreadLoaded",
        "tap",
        "visibleAnchorChanged",
    ]

    private(set) var hints: [Any] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == progressionMessageName {
            hints.append(message.body)
        }
    }
}

@MainActor
private final class LoadObserver: NSObject, WKNavigationDelegate {
    private var finished: [ObjectIdentifier] = []

    func hasFinished(_ navigation: WKNavigation?) -> Bool {
        navigation.map { finished.contains(ObjectIdentifier($0)) } ?? false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation {
            finished.append(ObjectIdentifier(navigation))
        }
    }
}

/// Records every delegated location and fulfills one armed expectation with the
/// first location delivered after arming that satisfies its predicate. Arming
/// happens immediately before the action under test, so the opening report can
/// never satisfy it.
@MainActor
private final class LocationReportSpy: EPUBNavigatorDelegate {
    private(set) var locations: [Locator] = []
    private(set) var matchedLocation: Locator?
    private var pending: (predicate: (Locator) -> Bool, expectation: XCTestExpectation)?
    private var armedIndex = 0

    /// Every location delivered since the last expectation was armed.
    var locationsSinceArming: [Locator] {
        Array(locations[armedIndex...])
    }

    func expectLocation(
        _ description: String,
        where predicate: @escaping (Locator) -> Bool
    ) -> XCTestExpectation {
        arm(XCTestExpectation(description: description), predicate)
    }

    /// An inverted expectation: waiting on it fails if a matching location is
    /// delivered within the timeout.
    func expectNoLocation(
        _ description: String,
        where predicate: @escaping (Locator) -> Bool
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        expectation.isInverted = true
        return arm(expectation, predicate)
    }

    private func arm(
        _ expectation: XCTestExpectation,
        _ predicate: @escaping (Locator) -> Bool
    ) -> XCTestExpectation {
        matchedLocation = nil
        armedIndex = locations.count
        pending = (predicate, expectation)
        return expectation
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locations.append(locator)
        guard let pending, pending.predicate(locator) else {
            return
        }
        self.pending = nil
        matchedLocation = locator
        pending.expectation.fulfill()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
}

/// A table of contents that answers only once the test releases it.
@MainActor
private final class HeldTableOfContents: TableOfContentsService {
    private(set) var wasAsked = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        isReleased = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }

    nonisolated func tableOfContents() async -> ReadResult<[Link]> {
        await waitForRelease()
        return .success([])
    }

    private func waitForRelease() async {
        wasAsked = true
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}
