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

/// Makes every smooth scroll `world` asks for land at once after `delay`, and
/// counts the scroll writes it asks for. The test host never advances a scroll
/// animation, so a smooth scroll would otherwise never move.
@MainActor
private func landSmoothScrolls(after delay: Duration, in webView: WKWebView, world: WKContentWorld) async throws {
    _ = try await webView.callAsyncJavaScript(
        """
        globalThis.__scrollWrites = 0;
        const landing = original => function (options) {
            globalThis.__scrollWrites += 1;
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
        contentWorld: world
    )
}

/// The scroll writes `world` asked for since `landSmoothScrolls(after:in:world:)`.
@MainActor
private func countedScrollWrites(in webView: WKWebView, world: WKContentWorld) async throws -> Int {
    let value = try await webView.callAsyncJavaScript(
        "return globalThis.__scrollWrites;",
        arguments: [:],
        in: nil,
        contentWorld: world
    )
    return try XCTUnwrap(value as? Int, "Setup: the scroll writes of a world were not counted")
}

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
        XCTAssertNil(spread.scrollAnimationCoordinator.lastSettlementForTesting, "Setup: a scroll animation settled before the turn")

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
    }

    /// UIKit moves the scroll view and calls the end delegate in one pass,
    /// while WebKit tells the page its new offset afterwards. The read that a
    /// scroll's end starts must still measure where the page came to rest.
    /// With the page's hints silenced, a read of the previous offset would
    /// equal the opening report and publish nothing.
    func test_aScrollEndReportsTheOffsetTheScrollViewEndedAt() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        spread.webView.configuration.userContentController.removeScriptMessageHandler(forName: progressionMessageName)
        let opening = try XCTUnwrap(reader.spy.locations.last?.locations.progression)
        let report = reader.spy.expectLocation("report of the page the scroll ended on") {
            ($0.locations.progression ?? opening) > opening
        }

        let scrollView = spread.scrollView
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x + scrollView.bounds.width, y: 0), animated: false)
        spread.scrollViewDidEndScrollingAnimation(scrollView)

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        let settled = try await reader.requireGeometry()
        let reported = try XCTUnwrap(reader.spy.matchedLocation?.locations.progression, "No report of the page the scroll ended on")
        XCTAssertEqual(reported, settled.firstProgression, accuracy: 0.000_001)
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

    /// An animated jump to the page already showing writes nothing and returns
    /// at once. No scroll starts, so nothing could end a wait for one before
    /// the scroll-animation fallback, which holds the navigator meanwhile.
    func test_anAnimatedJumpToTheShowingPageReturnsWithoutWriting() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await makeSmoothScrollsLand(after: .milliseconds(200), in: spread)
        let opening = try await reader.requireGeometry()
        let turned = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(turned, "Setup: the turn to the second page failed")
        let showing = try await reader.waitForOffset(differentFrom: opening)
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let writesBefore = try await scrollWrites(in: spread)

        let clock = ContinuousClock()
        let started = clock.now
        let jumped = await reader.navigator.go(
            to: Locator(
                href: Self.longChapterHREF.anyURL,
                mediaType: .html,
                locations: Locator.Locations(progression: showing.firstProgression)
            ),
            options: NavigatorGoOptions(animated: true)
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertTrue(jumped)
        XCTAssertLessThan(elapsed, Self.scrollAnimationFallback, "The jump waited for a scroll that never started")
        let writes = try await scrollWrites(in: spread)
        XCTAssertEqual(writes, writesBefore, "The jump wrote the offset it was already at")
        let settled = try await reader.requireGeometry()
        XCTAssertEqual(settled, showing)
    }

    /// A smooth scroll that outlasts the scroll-animation fallback still
    /// settles where it lands. With the page's hints silenced, a jump that
    /// settled on the fallback would measure the page it left and report
    /// nothing, or report a page the scroll was passing.
    func test_aJumpWhoseScrollOutlastsTheAnimationFallbackReportsWhereItLands() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        spread.webView.configuration.userContentController.removeScriptMessageHandler(forName: progressionMessageName)
        try await makeSmoothScrollsLand(after: Self.scrollAnimationFallback + .milliseconds(300), in: spread)
        let href = Self.longChapterHREF.anyURL
        let opening = try XCTUnwrap(reader.spy.locations.last?.locations.progression)

        try await assertTheSettledRangeIsReported(
            by: reader,
            in: href,
            as: "report of the page the jump landed on",
            where: { ($0.locations.progression ?? opening) > opening }
        ) {
            let jumped = await reader.navigator.go(
                to: Locator(href: href, mediaType: .html, locations: Locator.Locations(progression: 0.5)),
                options: NavigatorGoOptions(animated: true)
            )
            XCTAssertTrue(jumped)
        }
    }

    /// A jump still moves the page when no frame of the current document is
    /// registered: before the frame hand-off finishes, or once it has failed.
    /// The bridge's frames are emptied here as an unfinished hand-off leaves
    /// them. The jump runs in the main frame's command world, as a registered
    /// one does, and writes nothing in the page world, where a book's script
    /// could replace what the scroll calls.
    func test_aJumpWithNoRegisteredFrameStillMovesThePage() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await makeSmoothScrollsLand(after: .milliseconds(400), in: spread)
        let opening = try await reader.requireGeometry()
        spread.locatorCommandBridge.revokeFrameCapability()

        let jumped = await reader.navigator.go(
            to: Locator(href: Self.longChapterHREF.anyURL, mediaType: .html, locations: Locator.Locations(progression: 0.5)),
            options: NavigatorGoOptions(animated: true)
        )

        XCTAssertTrue(jumped)
        let pageWorldWrites = try await countedScrollWrites(in: spread.webView, world: .page)
        let commandWorldWrites = try await countedScrollWrites(in: spread.webView, world: EPUBLocatorCommandBridge.contentWorld)
        XCTAssertEqual(pageWorldWrites, 0, "The jump scrolled in the page world")
        XCTAssertEqual(commandWorldWrites, 1, "The jump did not scroll in the command world")
        let moved = try await reader.requireGeometry()
        XCTAssertNotEqual(moved.scrollX, opening.scrollX, "The jump returned success without moving the page")
        XCTAssertEqual(moved.scrollX.truncatingRemainder(dividingBy: moved.innerWidth), 0, "The jump did not land on a page start")
    }

    /// A jump fails when its command misses: only an applied command is a
    /// landing. Here the command world measures no scroll width, so the
    /// command misses at once, before writing, with the position deadline
    /// still ahead for the steps after it.
    func test_aJumpWhoseCommandMissesFails() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        _ = try await spread.webView.callAsyncJavaScript(
            #"Object.defineProperty(document.scrollingElement, "scrollWidth", { value: 0, configurable: true });"#,
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        let opening = try await reader.requireGeometry()

        let jumped = await reader.navigator.go(
            to: Locator(href: Self.longChapterHREF.anyURL, mediaType: .html, locations: Locator.Locations(progression: 0.5)),
            options: NavigatorGoOptions(animated: false)
        )

        XCTAssertFalse(jumped, "The jump succeeded though its command missed")
        let after = try await reader.requireGeometry()
        XCTAssertEqual(after.scrollX, opening.scrollX, "Setup: something other than the command moved the page")
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

    // MARK: - Writers

    /// A writer that joins a turn's generation and outlives the turn's writer
    /// keeps the turned page unread and unreported until it releases; then
    /// the turned page, measured after the release, is all that is reported.
    func test_aWriterHeldPastATurnDefersTheReportToTheLastRelease() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let opening = try XCTUnwrap(reader.spy.locations.last)
        let openingProgression = try XCTUnwrap(opening.locations.progression)
        let before = try await reader.requireGeometry()
        let observation = try XCTUnwrap(spread.builtLocationObservation)
        try await reader.waitFor("the opening's reads to end") {
            !observation.isReading && !observation.hasObligation
        }
        let transport = TransportEventTap(spread.locatorCommandBridge)
        let joining = ExtraWriter(joiningTheNextGenerationOf: spread.readiness)
        let early = reader.spy.expectNoLocation("a report before the last writer released") { _ in true }

        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))

        XCTAssertTrue(moved)
        let extra = try XCTUnwrap(joining.lease, "Setup: no writer joined the turn's generation while its writer was held")
        _ = try await reader.waitForOffset(differentFrom: before)
        await fulfillment(of: [early], timeout: Self.quietWindow)
        XCTAssertEqual(transport.events, [], "The turned page was read while a writer was held")

        XCTAssertEqual(
            spread.readiness.state,
            .initializing(generation: extra.generation, activeWriterLeases: 1),
            "Setup: the extra writer is not the last one held"
        )
        let report = reader.spy.expectLocation("report of the turned page") {
            $0.href.isEquivalentTo(opening.href) && ($0.locations.progression ?? openingProgression) > openingProgression
        }
        spread.readiness.release(extra)
        await fulfillment(of: [report], timeout: Self.reportTimeout)
        _ = try XCTUnwrap(reader.spy.matchedLocation, "No report of the turned page arrived")
        let atMatch = try await reader.requireGeometry()
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let settled = try await reader.requireGeometry()
        assertSettledReports(reader.spy.locationsSinceArming, isIn: opening.href, matchedAt: atMatch, settled: settled)
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

    /// A turn into another resource replaces the current spread. A calculation
    /// still waiting on the table of contents then delivers neither the
    /// replaced resource's page nor anything the reader did not settle on.
    func test_aCalculationOutlivedByASpreadChangeDeliversOnlyTheNewResource() async throws {
        let contents = HeldTableOfContents()
        let reader = try await openReader(at: Self.nextChapterHREF, minimumScreens: 1, tableOfContents: contents)
        let opening = try XCTUnwrap(reader.currentSpread)
        try await reader.waitFor("a calculation of the opening page") { contents.wasAsked }

        let moved = await reader.navigator.goBackward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)
        try await reader.waitFor("the previous resource's spread") {
            reader.currentSpread.map { $0 !== opening } == true
        }
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        try await reader.waitFor("the previous resource's measurement") {
            (spread.builtLocationObservation?.currentObservation?.sample.range.lowerBound ?? 0) > 0
        }

        try await assertOnlyTheNewGeometryIsReported(by: reader, once: contents)
        XCTAssertTrue(
            reader.spy.locations.allSatisfy { $0.href.isEquivalentTo(Self.longChapterHREF.anyURL) },
            "The outlived calculation delivered the replaced resource: \(reader.spy.locations.map(\.href))"
        )
    }

    /// Page hints arriving faster than the hint window neither extend nor
    /// restart it, so a native scroll that only hints can measure is still
    /// reported. That an equal re-measure reports nothing new is
    /// `test_anEqualReMeasureReportsNothingNew`'s claim.
    func test_aFloodOfEqualHintsStillReportsANativeScroll() async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView)
        _ = try await spread.webView.callAsyncJavaScript(
            """
            window.__hintPosts = 0;
            window.__hintFlood = setInterval(() => {
                window.__hintPosts += 1;
                webkit.messageHandlers.\(progressionMessageName).postMessage({ first: 0, last: 0 });
            }, 5);
            return true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        addTeardownBlock { @MainActor in
            _ = try? await spread.webView.callAsyncJavaScript(
                "clearInterval(window.__hintFlood); return true;", arguments: [:], in: nil, contentWorld: .page
            )
        }
        let opening = try XCTUnwrap(reader.spy.locations.last?.locations.progression)

        try await assertTheSettledRangeIsReported(
            by: reader,
            in: Self.longChapterHREF.anyURL,
            as: "report of the scrolled page",
            where: { ($0.locations.progression ?? opening) > opening }
        ) {
            spread.scrollView.contentOffset = CGPoint(x: spread.scrollView.bounds.width, y: 0)
        }
        let posts = try await spread.webView.callAsyncJavaScript(
            "return window.__hintPosts;", arguments: [:], in: nil, contentWorld: .page
        ) as? NSNumber
        XCTAssertGreaterThan(posts?.intValue ?? 0, 100, "Setup: the page did not flood hints")
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

    // MARK: - Isolated-world progression jump

    /// A jump lands on the start of the page holding its progression, in the
    /// geometry the progression read measures: a progression rounding left
    /// half a pixel short of a page start stays on that page, right-to-left
    /// pages scroll to a negated offset while right-to-left scroll mode
    /// scrolls down, vertical writing advances horizontally in either
    /// direction, scroll mode does not snap to pages, and a progression past
    /// the last full viewport lands on it.
    func test_progressionJumpLandsOnThePageHoldingTheProgression() async throws {
        for testCase in Self.progressionJumpCases {
            let label = "\(testCase.document) to \(testCase.progression)"
            let page = try await openProgressionPage(testCase.document)
            try await page.register(EPUBSpreadFrameCapability())

            let result = try await page.jump(to: testCase.progression)

            assertApplied(result, label)
            let offset = try await page.offset()
            XCTAssertEqual(offset, testCase.offset, label)
        }
    }

    private static let progressionJumpCases: [(document: ProgressionDocument, progression: Double, offset: [Double])] = [
        (.leftToRightPages, 0.5, [600, 0]),
        (.leftToRightPages, 599.5 / 1800, [600, 0]),
        (.rightToLeftPages, 0.5, [-600, 0]),
        (.verticalScroll, 0.4, [0, 1280]),
        (.rightToLeftScroll, 0.4, [0, 1280]),
        (.verticalWritingScroll, 0.5, [-900, 0]),
        (.verticalLeftToRightWritingScroll, 0.5, [900, 0]),
        (.verticalLeftToRightWritingRightToLeftDirectionScroll, 0.5, [900, 0]),
        (.leftToRightPages, 1, [1200, 0]),
    ]

    /// A jump to the page already showing writes nothing, so it never waits
    /// for a scroll that would not start.
    func test_progressionJumpToTheShowingPageWritesNothing() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        try await page.scroll(x: 600, y: 0)
        try await page.landCommandWorldSmoothScrolls(after: .seconds(2))

        let result = try await page.jump(to: 0.4, animated: true)

        assertApplied(result)
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 0, "The jump wrote the offset it was already at")
        let offset = try await page.offset()
        XCTAssertEqual(offset, [600, 0])
    }

    /// A smooth jump answers once its scroll lands, not when it asks for it.
    func test_progressionJumpAnswersOnceItsSmoothScrollLands() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        let landing: Duration = .milliseconds(400)
        try await page.landCommandWorldSmoothScrolls(after: landing)
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await page.jump(to: 0.5, animated: true)

        let elapsed = started.duration(to: clock.now)
        assertApplied(result)
        XCTAssertGreaterThanOrEqual(elapsed, landing, "The jump answered before its scroll landed")
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 1)
        let offset = try await page.offset()
        XCTAssertEqual(offset, [600, 0])
    }

    /// A placement can run before its document's frame registers. The jump
    /// then runs in the main frame, in the same world and geometry, so it
    /// lands where a registered one does.
    func test_progressionJumpBeforeItsFrameRegistersLandsWhereARegisteredOneDoes() async throws {
        for testCase in Self.progressionJumpCases {
            let label = "\(testCase.document) to \(testCase.progression)"
            let page = try await openProgressionPage(testCase.document)

            let result = try await page.jump(to: testCase.progression)

            assertApplied(result, label)
            let offset = try await page.offset()
            XCTAssertEqual(offset, testCase.offset, label)
        }
    }

    /// A main frame showing another document is not the resource: the jump
    /// before registration runs nothing there.
    func test_progressionJumpBeforeRegistrationRunsNothingInAnotherDocument() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.landCommandWorldSmoothScrolls(after: .zero)

        let result = try await page.jump(to: 0.5, targetHREF: "other.xhtml")

        XCTAssertEqual(result.outcome, .miss)
        XCTAssertEqual(result.reason, .frameMissing)
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 0, "The jump scrolled a document that is not its resource")
    }

    /// A jump past the last full viewport answers on it. The web process
    /// reports an overscrolled write's offset unclamped until the UI process
    /// clamps it, so a target past the end would read as reached at an offset
    /// the page then leaves; the offset is read in the task the jump answers in.
    func test_progressionJumpToTheEndAnswersWhereThePageStays() async throws {
        let page = try await openProgressionPage(.leftToRightPages)

        let answer = try await page.executeProgressionJump(to: 1)

        XCTAssertEqual(answer.outcome, "applied")
        XCTAssertEqual(answer.scrollX, 1200, "The jump answered at an offset the page does not keep")
    }

    /// A frame later than one frame's wait does not end a jump waiting for its
    /// landing: only the command's deadline does, because a failed position
    /// command fails its document.
    func test_aLateFrameDoesNotEndAJumpWaitingToLand() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.register(EPUBSpreadFrameCapability())
        try await page.landCommandWorldSmoothScrolls(after: .milliseconds(400))
        try await page.holdCommandWorldFrames()

        let result = try await page.jump(to: 0.5, animated: true)

        let held = try await page.heldCommandWorldFrames()
        XCTAssertGreaterThan(held, 0, "Setup: no frame of the jump's wait was held")
        assertApplied(result)
        let offset = try await page.offset()
        XCTAssertEqual(offset, [600, 0])
    }

    /// A jump whose scroll never lands answers `paintTimeout` at its deadline.
    /// Past the deadline every frame wait answers at once, so a landing wait
    /// that kept going would spin the web process and never answer; the
    /// expectation bounds a call that cannot observe cancellation.
    func test_aJumpThatNeverLandsMissesAtItsDeadline() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.runInCommandWorld(ProgressionPage.droppingScrollWrites)
        let budgetMilliseconds = 300
        let answered = XCTestExpectation(description: "the jump answers")
        let clock = ContinuousClock()
        let started = clock.now
        let jump = Task {
            defer { answered.fulfill() }
            return try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: budgetMilliseconds)
        }

        let waited = await XCTWaiter().fulfillment(of: [answered], timeout: 3)

        guard waited == .completed else {
            return XCTFail("The jump never answered once its deadline passed")
        }
        let answer = try await jump.value
        XCTAssertEqual(answer, ["miss", "paintTimeout"])
        XCTAssertGreaterThanOrEqual(
            started.duration(to: clock.now),
            .milliseconds(budgetMilliseconds),
            "The jump missed before its deadline"
        )
    }

    /// A frame later than one frame's wait does not end a jump waiting for a
    /// usable viewport either: the jump runs once the viewport has a size.
    func test_aLateFrameDoesNotEndAJumpWaitingForItsViewport() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.emptyCommandWorldViewport(restoringAfterMilliseconds: 400)
        try await page.holdCommandWorldFrames()

        let answer = try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: 3000)

        let held = try await page.heldCommandWorldFramesAtViewportRestore()
        XCTAssertGreaterThan(held, 0, "Setup: no frame of the jump's viewport wait was held")
        XCTAssertEqual(answer, ["applied", "none"])
        let offset = try await page.offset()
        XCTAssertEqual(offset, [600, 0])
    }

    /// A jump whose viewport keeps no size while its frames arrive misses as
    /// not ready, without moving the page.
    func test_aJumpWhoseViewportNeverGetsASizeMissesAsNotReady() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.emptyCommandWorldViewport()

        let answer = try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: 5000)

        XCTAssertEqual(answer, ["miss", "viewportNotReady"])
        let offset = try await page.offset()
        XCTAssertEqual(offset, [0, 0])
    }

    /// A jump whose viewport keeps no size while every frame comes late misses
    /// at its deadline, not at its first late frame.
    func test_aJumpWaitingForItsViewportMissesAtItsDeadline() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.emptyCommandWorldViewport()
        try await page.holdCommandWorldFrames()
        let budgetMilliseconds = 1000
        let clock = ContinuousClock()
        let started = clock.now

        let answer = try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: budgetMilliseconds)

        let held = try await page.heldCommandWorldFrames()
        XCTAssertGreaterThan(held, 0, "Setup: no frame of the jump's viewport wait was held")
        XCTAssertEqual(answer, ["miss", "paintTimeout"])
        XCTAssertGreaterThanOrEqual(
            started.duration(to: clock.now),
            .milliseconds(budgetMilliseconds),
            "The jump missed before its deadline"
        )
    }

    /// An invalidated jump waiting for its viewport writes nothing, even when
    /// the viewport gets its size in the same turn.
    func test_anInvalidatedJumpWaitingForItsViewportWritesNothing() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.landCommandWorldSmoothScrolls(after: .zero)
        try await page.emptyCommandWorldViewport()
        try await page.holdCommandWorldFrames()

        let jump = Task { try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: 5000) }
        try await waitUntil("the jump waits for its viewport") {
            try await page.heldCommandWorldFrames() > 0
        }
        let invalidated = try await page.restoreViewportAndInvalidateTheJump()
        let answer = try await jump.value

        XCTAssertTrue(invalidated, "Setup: no jump was in flight to invalidate")
        XCTAssertEqual(answer, ["cancelled", "staleToken"])
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 0, "The invalidated jump wrote its offset")
        let offset = try await page.offset()
        XCTAssertEqual(offset, [0, 0])
    }

    /// A jump superseded, not aborted, while it waits for its viewport is
    /// cancelled at its late frame and writes nothing, though the viewport has
    /// its size by then: a superseded command never misses.
    func test_aSupersededJumpWaitingForItsViewportIsCancelledAndWritesNothing() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.landCommandWorldSmoothScrolls(after: .zero)
        try await page.emptyCommandWorldViewport()
        try await page.holdCommandWorldFrames()

        let jump = Task { try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: 5000) }
        try await waitUntil("the jump waits for its viewport") {
            try await page.heldCommandWorldFrames() > 0
        }
        let successor = try await page.restoreViewportAndSupersedeTheJump()
        let answer = try await jump.value

        XCTAssertEqual(successor, ["applied", "none"], "Setup: the superseding jump did not run")
        XCTAssertEqual(answer, ["cancelled", "staleToken"])
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 0, "The superseded jump wrote its offset")
        let offset = try await page.offset()
        XCTAssertEqual(offset, [0, 0])
    }

    /// Locator navigation keeps ending its viewport wait at the first late
    /// frame: its miss releases only its writer, so it need not wait out its
    /// deadline as a jump does.
    func test_aLateFrameEndsALocatorNavigationWaitingForItsViewport() async throws {
        let page = try await openProgressionPage(.leftToRightPages, holdingCommandWorldFrames: true)
        try await page.landCommandWorldSmoothScrolls(after: .zero)
        try await page.emptyCommandWorldViewport()
        // The navigation's frame before its scroll arrives; its viewport wait's do not.
        try await page.holdCommandWorldFrames(afterDelivering: 1)
        let budgetMilliseconds = 3000
        let clock = ContinuousClock()
        let started = clock.now

        let answer = try await page.executeLocatorNavigation(budgetMilliseconds: budgetMilliseconds)

        let elapsed = started.duration(to: clock.now)
        let framesLeft = try await page.framesLeftBeforeHolding()
        XCTAssertEqual(framesLeft, 0, "Setup: the navigation's frame before its scroll was not delivered")
        let widthReads = try await page.commandWorldViewportWidthReads()
        XCTAssertGreaterThan(widthReads, 0, "Setup: the navigation never reached its viewport wait")
        let writes = try await page.commandWorldScrollWrites()
        XCTAssertEqual(writes, 0, "Setup: the navigation scrolled before its viewport wait ended")
        XCTAssertEqual(answer, ["miss", "paintTimeout"])
        let held = try await page.heldCommandWorldFrames()
        XCTAssertEqual(held, 1, "The viewport wait asked for another frame after its late one")
        XCTAssertLessThan(elapsed, .milliseconds(budgetMilliseconds / 2), "The navigation waited out its deadline")
    }

    /// A jump misses as unverifiable when the geometry stops supporting one,
    /// before it writes or while it waits to land.
    func test_aJumpWhoseGeometryCannotBeMeasuredMisses() async throws {
        let cases: [(label: String, setup: String)] = [
            ("before the write", #"Object.defineProperty(document.scrollingElement, "scrollWidth", { value: 0, configurable: true });"#),
            (
                "while landing",
                """
                Element.prototype.scrollTo = function () {
                    Object.defineProperty(document.scrollingElement, "scrollWidth", { value: 0, configurable: true });
                };
                """
            ),
        ]
        for testCase in cases {
            let page = try await openProgressionPage(.leftToRightPages)
            try await page.runInCommandWorld(testCase.setup)

            let answer = try await page.executeProgressionJump(to: 0.5, budgetMilliseconds: 3000)

            XCTAssertEqual(answer, ["miss", "geometryUnverifiable"], testCase.label)
        }
    }

    /// A newer navigation supersedes a jump still waiting for its landing.
    func test_aNewerNavigationSupersedesAJumpWaitingToLand() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        let landing: Duration = .seconds(3)
        try await page.landCommandWorldSmoothScrolls(after: landing)
        let clock = ContinuousClock()

        let superseded = Task { try await page.jump(to: 0.5, animated: true) }
        try await waitUntil("the superseded jump asks for its scroll") {
            try await page.commandWorldScrollWrites() == 1
        }
        let started = clock.now
        let newer = try await page.jump(to: 1)
        let supersededResult = try await superseded.value

        assertApplied(newer, "the newer jump")
        assertCancelled(supersededResult, "the superseded jump")
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1), "The superseded jump waited for its landing")
    }

    /// A page script's own `pagehide` aborts no command: a jump waiting for its
    /// landing still lands. A failed position command fails its document, so
    /// a page that could abort one could stop every later page turn.
    func test_aPageScriptsPagehideLeavesAJumpLanding() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        try await page.landCommandWorldSmoothScrolls(after: .milliseconds(400))

        let jump = Task { try await page.jump(to: 0.5, animated: true) }
        try await waitUntil("the jump asks for its scroll") {
            try await page.commandWorldScrollWrites() == 1
        }
        try await page.dispatchPageScriptPagehide()
        let result = try await jump.value

        assertApplied(result, "the jump the page script tried to abort")
        let offset = try await page.offset()
        XCTAssertEqual(offset, [600, 0])
    }

    /// Cancelling the task of a jump waiting for its landing ends the wait.
    func test_cancellingAJumpWaitingToLandEndsItsWait() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        let landing: Duration = .seconds(3)
        try await page.landCommandWorldSmoothScrolls(after: landing)
        let clock = ContinuousClock()

        let jump = Task { try await page.jump(to: 0.5, animated: true) }
        try await waitUntil("the jump asks for its scroll") {
            try await page.commandWorldScrollWrites() == 1
        }
        let cancelledAt = clock.now
        jump.cancel()
        let result = try await jump.value

        assertCancelled(result, "the cancelled jump")
        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1), "The cancelled jump waited for its landing")
    }

    /// The bridge's in-flight relay cancels a jump waiting for its landing, with
    /// neither the jump's task cancelled nor a newer navigation issued: the
    /// path a superseding request takes before its own command runs.
    func test_theInFlightRelayCancelsAJumpWaitingToLand() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        try await page.landCommandWorldSmoothScrolls(after: .seconds(3))
        let clock = ContinuousClock()

        let jump = Task { try await page.jump(to: 0.5, animated: true) }
        try await waitUntil("the jump asks for its scroll") {
            try await page.commandWorldScrollWrites() == 1
        }
        let relayedAt = clock.now
        await page.bridge.cancelInFlightNavigation(
            deadline: EPUBLocatorOperationDeadline(startingAt: relayedAt, budget: .seconds(1))
        )
        let result = try await jump.value

        assertCancelled(result, "the relayed jump")
        XCTAssertLessThan(relayedAt.duration(to: clock.now), .seconds(1), "The relayed jump waited for its landing")
    }

    /// A superseded jump that returns leaves its successor as the navigation
    /// the relay cancels.
    func test_theRelayCancelsTheJumpThatSupersededAnother() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.register(EPUBSpreadFrameCapability())
        try await page.landCommandWorldSmoothScrolls(after: .seconds(3))
        let clock = ContinuousClock()

        let superseded = Task { try await page.jump(to: 0.5, animated: true) }
        try await waitUntil("the first jump asks for its scroll") {
            try await page.commandWorldScrollWrites() == 1
        }
        let successor = Task { try await page.jump(to: 1, animated: true) }
        let supersededResult = try await superseded.value
        try await waitUntil("the successor asks for its scroll") {
            try await page.commandWorldScrollWrites() == 2
        }
        let relayedAt = clock.now
        await page.bridge.cancelInFlightNavigation(
            deadline: EPUBLocatorOperationDeadline(startingAt: relayedAt, budget: .seconds(1))
        )
        let successorResult = try await successor.value

        assertCancelled(supersededResult, "the superseded jump")
        assertCancelled(successorResult, "the relayed successor")
        XCTAssertLessThan(relayedAt.duration(to: clock.now), .seconds(1), "The relayed successor waited for its landing")
    }

    private func assertApplied(
        _ result: EPUBLocatorCommandResult,
        _ label: String = "the jump",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.outcome, .applied, "Expected \(label) to apply, got \(result)", file: file, line: line)
    }

    private func assertCancelled(
        _ result: EPUBLocatorCommandResult,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.outcome, .cancelled, "Expected \(label) to be cancelled, got \(result)", file: file, line: line)
    }

    /// Polls `condition` for up to two seconds without failing: the caller
    /// asserts what it finds.
    private func pollBriefly(until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
        }
    }

    /// Polls `condition` until it holds, failing with `description` otherwise.
    private func waitUntil(_ description: String, _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if try await condition() {
                return
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting until \(description)")
        throw SetupTimeout()
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

    /// Right-to-left scroll mode advances down, so its offset is not negated.
    func test_progressionReadMeasuresRightToLeftScrollVertically() async throws {
        let page = try await openProgressionPage(.rightToLeftScroll)
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

    /// A right-to-left `direction` turns only the inline axis, which vertical
    /// writing lays out vertically, so vertical-lr still advances right from 0.
    func test_progressionReadMeasuresRightToLeftDirectionInLeftToRightVerticalWritingWithoutNegating() async throws {
        let page = try await openProgressionPage(.verticalLeftToRightWritingRightToLeftDirectionScroll)
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

    /// Every content world receives a DOM event, so a page script can dispatch
    /// `pagehide` itself. Only the browser's own revokes the capability: the
    /// document is still current, and so is its capability.
    func test_aPageScriptsPagehideLeavesTheCapabilityAnswering() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.acceptCapability(ProgressionPage.capability)

        try await page.dispatchPageScriptPagehide()

        try await assertSample(page.read(ProgressionPage.capability), first: 0, last: 1.0 / 3)
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

    /// A direct same-origin child frame that holds the capability answers a
    /// read with its own geometry; the bridge still reads the main frame it
    /// selected.
    func test_bridgeReadIgnoresAChildFrameHoldingTheCapability() async throws {
        let page = try await openServedProgressionPage(.leftToRightPagesWithChildFrame)
        let capability = EPUBSpreadFrameCapability()
        try await page.register(capability)
        try await page.scroll(x: 600, y: 0)
        try await page.waitForChildFrameCommandWorld()
        try await page.handChildFrame(capability)
        let child = try await page.waitForChildFrameSample(capability)
        XCTAssertEqual(child.first, 0, accuracy: 0.000_001, "Setup: the child frame did not measure its own geometry")
        XCTAssertEqual(child.last, 1.0 / 6, accuracy: 0.000_001, "Setup: the child frame did not measure its own geometry")

        let outcome = try await page.readThroughBridge()

        XCTAssertEqual(outcome, .sample(EPUBProgressionSample(capability: capability, range: (1.0 / 3) ... (2.0 / 3))))
    }

    /// A reflowable command target is the main frame, so its hand-off keeps
    /// the capability out of child frames, where a page script listening on
    /// the child's window would see it.
    func test_aReflowableHandOffKeepsTheCapabilityOutOfChildFrames() async throws {
        let page = try await openServedProgressionPage(.leftToRightPagesWithChildFrame)
        try await page.waitForChildFrameCommandWorld()
        let capability = EPUBSpreadFrameCapability()

        try await page.register(capability)

        try await ContinuousClock().sleep(for: .milliseconds(500))
        let child = try await page.childFrameRead(capability)
        XCTAssertNil(child, "The child frame received the reflowable capability")
        try await page.handChildFrame(capability)
        _ = try await page.waitForChildFrameSample(capability)
    }

    /// A child frame accepts a capability only as a real message from its
    /// parent: one a page script dispatches on the child's window, however it
    /// names its source, hands it nothing.
    func test_aPageScriptsCapabilityMessageHandsTheChildFrameNothing() async throws {
        let page = try await openServedProgressionPage(.leftToRightPagesWithChildFrame)
        try await page.waitForChildFrameCommandWorld()
        let capability = EPUBSpreadFrameCapability()

        try await page.dispatchPageScriptCapabilityMessage(capability)

        try await ContinuousClock().sleep(for: .milliseconds(200))
        let child = try await page.childFrameRead(capability)
        XCTAssertNil(child, "A page script's own message handed the child frame a capability")
        try await page.postCapabilityMessage(capability)
        _ = try await page.waitForChildFrameSample(capability)
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
        let answer: [String: Any] = ["capability": capability.id.uuidString, "first": 0, "last": 0.5, "scrollX": 0, "scrollY": 0]

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
        XCTAssertEqual(page.transportEvents, [.slotAvailable, .handshakeFailed(capability)])
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

    // MARK: - Observation over the bridge

    /// A read answered after an authoritative change describes what was shown
    /// before it: it is read again, not accepted. One answered after the
    /// spread was cleared reaches nothing.
    func test_aReadAnsweredAfterTheSpreadChangedIsNeverAccepted() async throws {
        let observed = try await openObservedHeldPage()
        let scripts = observed.held.scripts
        let observation = observed.observation
        XCTAssertTrue(observation.isReading, "Setup: the registration started no read")
        XCTAssertEqual(scripts.count, 2, "Setup: expected the hand-off and one read")

        observation.invalidate()
        observed.complete(1, with: .success(observed.answer(0.5 ... 1)))
        XCTAssertEqual(observed.accepted, [], "A read answered after the change was accepted")
        XCTAssertEqual(scripts.count, 3, "The change's obligation was not read again")
        observed.complete(2, with: .success(observed.answer(0 ... 0.5)))
        XCTAssertEqual(observed.accepted.map(\.sample.range), [0 ... 0.5])

        observation.request()
        XCTAssertEqual(scripts.count, 4, "Setup: the request started no read")
        let answerBeforeTheClear = observed.answer(0.5 ... 1)
        observed.clear()
        observed.complete(3, with: .success(answerBeforeTheClear))

        XCTAssertEqual(observed.accepted.map(\.sample.range), [0 ... 0.5], "A read answered after the clear was accepted")
        XCTAssertFalse(observation.isReading || observation.hasObligation, "The clear left work behind")
    }

    /// A read the page never answers expires for the observation, but its
    /// physical call keeps the transport: hints arm nothing, a new document's
    /// hand-off waits for the late answer, and no second call starts beside
    /// it. The late answer frees the slot for that hand-off, and the new
    /// document then reports.
    func test_anExpiredReadKeepsItsCallThroughHintsAndADocumentChange() async throws {
        let observed = try await openObservedHeldPage()
        let held = observed.held
        let observation = observed.observation
        XCTAssertTrue(observation.isReading, "Setup: the registration started no read")
        XCTAssertEqual(held.scripts.count, 2, "Setup: expected the hand-off and one read")

        held.deadlines.advance(by: EPUBLocationObservation.readBudget)
        XCTAssertEqual(observation.unavailability, .operationPending)
        for _ in 0 ..< 100 {
            observation.hint()
        }
        XCTAssertEqual(held.deadlines.armedCount, 0, "A hint armed a timer while the read was pending")
        held.deadlines.advance(by: EPUBLocationObservation.recoveryCeiling)
        let next = EPUBSpreadFrameCapability()
        observed.open(next)

        XCTAssertEqual(held.scripts.count, 2, "A second physical call started beside the expired read")
        XCTAssertFalse(observation.isReading)
        XCTAssertTrue(observation.hasObligation, "The new document's obligation was dropped")

        observed.complete(1, with: .success(NSNull()))
        XCTAssertEqual(held.scripts.injectedCapabilities.last, next, "The late answer did not free the slot for the hand-off")
        observed.complete(2, with: .success(NSNull()))
        try await held.page.echo(next)
        XCTAssertEqual(held.scripts.count, 4, "The new document's registration started no read")
        observed.complete(3, with: .success(observed.answer(0 ... 0.5)))
        XCTAssertEqual(observed.accepted.map(\.sample), [EPUBProgressionSample(capability: next, range: 0 ... 0.5)])
    }

    /// A hand-off whose injection fails is re-issued once; a registration
    /// that then arrives after the re-issue's deadline still ends it, and a
    /// repeated echo of the same capability leaves one selectable frame, so
    /// each registration's read reports.
    func test_aFailedHandshakeRecoversOnceAndARepeatedEchoKeepsOneFrame() async throws {
        let observed = try await makeObservedHeldPage()
        let held = observed.held
        let observation = observed.observation
        let capability = EPUBSpreadFrameCapability()
        observed.open(capability)
        observed.complete(0, with: .failure(URLError(.cannotConnectToHost)))

        held.deadlines.advance(by: EPUBLocationObservation.retryGap)
        XCTAssertEqual(held.scripts.injectedCapabilities, [capability, capability], "The failed hand-off was not re-issued once")
        observed.complete(1, with: .success(NSNull()))
        held.deadlines.advance(by: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds))
        XCTAssertTrue(observation.isRegistrationMissing, "Setup: the re-issue did not miss its registration")
        held.deadlines.advance(by: EPUBLocationObservation.recoveryCeiling)
        XCTAssertEqual(held.scripts.count, 2, "The hand-off was re-issued past its one retry")

        try await held.page.echo(capability)
        XCTAssertEqual(held.scripts.count, 3, "The late registration started no read")
        observed.complete(2, with: .success(observed.answer(0 ... 0.5)))
        try await held.page.runInCommandWorld(
            "readerLocatorCommands.acceptFrameCapability(capability);",
            arguments: ["capability": capability.id.uuidString]
        )
        try await pollBriefly { held.page.registrations.count == 2 }
        XCTAssertEqual(held.page.registrations, [capability, capability], "The repeated echo left no selectable frame")
        XCTAssertEqual(held.scripts.count, 4, "The repeated echo started no read")
        observed.complete(3, with: .success(observed.answer(0 ... 0.5)))

        let sample = EPUBProgressionSample(capability: capability, range: 0 ... 0.5)
        XCTAssertEqual(observed.accepted.map(\.sample), [sample, sample])
        XCTAssertEqual(Set(observed.accepted.map(\.stamp)).count, 1, "An equal sample advanced the stamp")
    }

    // MARK: - Settlement signals in a real reader

    /// Any page script can post `progressionChanged`, with any numbers. They
    /// are never reported: the message only asks the spread to measure.
    func test_aPageWorldProgressionMessageIsMeasuredNotTrusted() async throws {
        try await assertAPageWorldProgressionMessageIsMeasuredNotTrusted(holdingASample: false)
    }

    /// The same holds while the spread holds a sample it could publish at
    /// once, before the message's own measurement replaces it.
    func test_aPageWorldProgressionMessageBesideAPublishableSampleIsNotReported() async throws {
        try await assertAPageWorldProgressionMessageIsMeasuredNotTrusted(holdingASample: true)
    }

    private func assertAPageWorldProgressionMessageIsMeasuredNotTrusted(
        holdingASample: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let reader = try await openReader()
        let spread = try XCTUnwrap(reader.currentSpread as? EPUBReflowableSpreadView, file: file, line: line)
        let observation = try XCTUnwrap(spread.builtLocationObservation, file: file, line: line)
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        try await reader.waitFor("the opening's reads to end") {
            !observation.isReading && !observation.hasObligation
        }
        let settled = try await reader.requireGeometry()
        if !holdingASample {
            observation.invalidate()
        }
        let transport = TransportEventTap(spread.locatorCommandBridge)
        let forged = reader.spy.expectNoLocation("report of the page world's numbers") {
            ($0.locations.progression ?? 0) > 0.5
        }

        _ = try await spread.webView.evaluateJavaScript(
            "webkit.messageHandlers.\(progressionMessageName).postMessage({first: 0.9, last: 0.95}); true"
        )

        try await reader.waitFor("the measurement the message asked for") {
            transport.events.contains(.slotAvailable)
        }
        await fulfillment(of: [forged], timeout: Self.quietWindow)
        let published = try XCTUnwrap(
            spread.publicationInput()?.progressions[spread.spread.first.index],
            "The spread has nothing to publish after its measurement",
            file: file,
            line: line
        )
        XCTAssertEqual(
            published.lowerBound,
            settled.firstProgression,
            accuracy: 0.000_001,
            "The spread would publish the page world's numbers",
            file: file,
            line: line
        )
        XCTAssertEqual(
            published.upperBound,
            settled.lastProgression,
            accuracy: 0.000_001,
            "The spread would publish \(published), not the page it measured (\(settled))",
            file: file,
            line: line
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
        let expectedKeys: Set<String> = capability == nil ? ["first", "last"] : ["capability", "first", "last", "scrollX", "scrollY"]
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

    /// How long `EPUBScrollAnimationCoordinator` waits for a smooth scroll's
    /// quiet signal before it gives up.
    private static let scrollAnimationFallback: Duration = .milliseconds(800)

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
    /// an instant one lands immediately. Each content world has its own
    /// prototypes, so both scrolling worlds are patched, and each counts the
    /// scroll writes it is asked for (`scrollWrites(in:)`).
    private func makeSmoothScrollsLand(after delay: Duration, in spread: EPUBSpreadView) async throws {
        for world in Self.scrollingWorlds {
            try await landSmoothScrolls(after: delay, in: spread.webView, world: world)
        }
    }

    /// The page world, where page turns scroll, and the locator command world,
    /// where progression jumps scroll.
    private static let scrollingWorlds: [WKContentWorld] = [.page, EPUBLocatorCommandBridge.contentWorld]

    /// The scroll writes both scrolling worlds were asked for since
    /// `makeSmoothScrollsLand(after:in:)`.
    private func scrollWrites(in spread: EPUBSpreadView) async throws -> Int {
        var writes = 0
        for world in Self.scrollingWorlds {
            writes += try await countedScrollWrites(in: spread.webView, world: world)
        }
        return writes
    }

    private func openProgressionPage(
        _ document: ProgressionDocument,
        carryingReflowableScript: Bool = false,
        invokeLocationScript: EPUBLocatorCommandBridge.LocationScriptInvocation? = nil,
        deadlineScheduler: EPUBDeadlineScheduler? = nil,
        publicationBaseURL: String = "https://readium.test/",
        holdingCommandWorldFrames: Bool = false
    ) async throws -> ProgressionPage {
        let page = try ProgressionPage(
            carryingReflowableScript: carryingReflowableScript,
            invokeLocationScript: invokeLocationScript,
            deadlineScheduler: deadlineScheduler,
            publicationBaseURL: publicationBaseURL,
            holdingCommandWorldFrames: holdingCommandWorldFrames
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

    /// A page served from its own `readium://` route through the navigator's
    /// `WebViewServer`, so a child frame can load a sibling resource of the
    /// same origin.
    private func openServedProgressionPage(_ document: ProgressionDocument) async throws -> ProgressionPage {
        let server = WebViewServer(scheme: "readium", formatSniffer: DefaultFormatSniffer())
        let baseURL = server.serve(at: UUID().uuidString) { href -> (Resource, MediaType)? in
            let html: String
            switch href.string {
            case "chapter.xhtml": html = document.html
            case "child.xhtml": html = ProgressionDocument.childFrame
            default: return nil
            }
            return (DataResource(string: html), .html)
        }
        let page = try ProgressionPage(publicationBaseURL: baseURL.string, server: server)
        addTeardownBlock { @MainActor in
            page.window.isHidden = true
            page.window.rootViewController = nil
        }
        try await page.load(servedFrom: baseURL)
        return page
    }

    /// A held page with an observation over its bridge and no document open.
    private func makeObservedHeldPage() async throws -> ObservedHeldPage {
        let scripts = HeldScripts()
        let deadlines = ManualDeadlines()
        let page = try await openProgressionPage(
            .leftToRightPages,
            invokeLocationScript: scripts.invocation,
            deadlineScheduler: deadlines.scheduler
        )
        return try ObservedHeldPage(HeldProgressionPage(page: page, scripts: scripts, deadlines: deadlines))
    }

    /// An observed held page whose document is ready and registered: the
    /// hand-off was location call 0, and the registration's read is call 1,
    /// still held.
    private func openObservedHeldPage() async throws -> ObservedHeldPage {
        let observed = try await makeObservedHeldPage()
        let capability = EPUBSpreadFrameCapability()
        observed.open(capability)
        observed.held.scripts.complete(0, with: .success(NSNull()))
        try await observed.held.page.echo(capability)
        return observed
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

    /// The paginated end of the viewport within the resource, unclamped
    /// (`progression.js` § `measureProgression` clamps it to 1).
    var lastProgression: Double {
        (abs(scrollX) + innerWidth) / scrollWidth
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
    case rightToLeftScroll
    case verticalWritingScroll
    case verticalLeftToRightWritingScroll
    case verticalLeftToRightWritingRightToLeftDirectionScroll
    case oddTwoColumnSpread
    /// Left-to-right pages with a direct child frame loading the sibling
    /// `child.xhtml`, 300 wide and fixed over the first page. Only a served page
    /// can load it.
    case leftToRightPagesWithChildFrame

    /// The child frame's document: 1800 wide, so the 300-wide frame measures
    /// a range of its own.
    static let childFrame = page(rootAttributes: "", width: 1800, height: 200)

    var html: String {
        switch self {
        case .leftToRightPages:
            Self.page(rootAttributes: "", width: 1800, height: 800)
        case .rightToLeftPages:
            Self.page(rootAttributes: #"dir="rtl""#, width: 1800, height: 800)
        case .verticalScroll:
            Self.page(rootAttributes: #"style="--USER__view: readium-scroll-on""#, width: 600, height: 3200)
        case .rightToLeftScroll:
            Self.page(rootAttributes: #"dir="rtl" style="--USER__view: readium-scroll-on""#, width: 600, height: 3200)
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
        case .verticalLeftToRightWritingRightToLeftDirectionScroll:
            Self.page(
                rootAttributes: #"dir="rtl" style="writing-mode: vertical-lr; --USER__view: readium-scroll-on""#,
                width: 1800,
                height: 800
            )
        case .oddTwoColumnSpread:
            Self.page(
                rootAttributes: #"style="height: 800px; column-count: 2; column-gap: 0; column-fill: auto""#,
                width: 600,
                height: 2400
            )
        case .leftToRightPagesWithChildFrame:
            Self.page(rootAttributes: "", width: 1800, height: 800, childFrameSource: "child.xhtml")
        }
    }

    private static func page(rootAttributes: String, width: Int, height: Int, childFrameSource: String? = nil) -> String {
        let childFrame = childFrameSource.map {
            #"<iframe src="\#($0)" style="position: fixed; left: 0; top: 0; width: 300px; height: 200px; border: 0"></iframe>"#
        } ?? ""
        return """
        <!doctype html><html \(rootAttributes)><head>\
        <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, shrink-to-fit=no">\
        <style>html, body { margin: 0; padding: 0; }</style>\
        </head><body><div style="width: \(width)px; height: \(height)px"></div>\(childFrame)</body></html>
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
    private static let frameHoldingScript = """
    globalThis.__deliverFrame = globalThis.requestAnimationFrame.bind(globalThis);
    globalThis.__heldFrames = null;
    globalThis.__framesBeforeHolding = 0;
    globalThis.requestAnimationFrame = (callback) => {
        if (globalThis.__heldFrames && globalThis.__framesBeforeHolding > 0) {
            globalThis.__framesBeforeHolding -= 1;
        } else if (globalThis.__heldFrames) {
            globalThis.__heldFrames.push(callback);
            return 0;
        }
        return globalThis.__deliverFrame(callback);
    };
    """
    /// The document's only element, as a locator command payload.
    private static let elementLocator = #"{"href":"chapter.xhtml","locations":{"cssSelector":"body > div"}}"#
    /// Drops every scroll write the command world asks for, so a jump never lands.
    static let droppingScrollWrites = "Element.prototype.scrollTo = function () {};"

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
    ///   - server: serves the page's resources, as the navigator serves a
    ///     publication, for a page loaded with `load(servedFrom:)`.
    ///   - holdingCommandWorldFrames: installs, ahead of the command script, an
    ///     animation-frame request the test can hold (`holdCommandWorldFrames()`).
    init(
        carryingReflowableScript: Bool = false,
        invokeLocationScript: EPUBLocatorCommandBridge.LocationScriptInvocation? = nil,
        deadlineScheduler: EPUBDeadlineScheduler? = nil,
        publicationBaseURL: String = "https://readium.test/",
        server: WebViewServer? = nil,
        holdingCommandWorldFrames: Bool = false
    ) throws {
        bridge = try EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: XCTUnwrap(AnyURL(string: publicationBaseURL)?.absoluteURL),
            deadlineScheduler: deadlineScheduler,
            invokeLocationScript: invokeLocationScript
        )
        let configuration = WKWebViewConfiguration()
        // iPad's desktop-class default scales wide content down to fit, which
        // would change the viewport the expected progressions are built on.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        if let server {
            configuration.setURLSchemeHandler(server, forURLScheme: server.scheme)
        }
        if holdingCommandWorldFrames {
            // Added first, so the command script binds this request when it loads.
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.frameHoldingScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: EPUBLocatorCommandBridge.contentWorld
            ))
        }
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

    /// Waits until the direct child frame answers a read under `capability`,
    /// in the locator command world reached through its same-origin window,
    /// and returns its range.
    /// Waits until the child frame has loaded the locator command script.
    func waitForChildFrameCommandWorld() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while clock.now < deadline {
            let loaded = try await webView.callAsyncJavaScript(
                "return document.querySelector('iframe')?.contentWindow?.readerLocatorCommands !== undefined;",
                arguments: [:],
                in: nil,
                contentWorld: EPUBLocatorCommandBridge.contentWorld
            ) as? Bool
            if loaded == true {
                return
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Setup: the child frame never loaded its command script")
        throw SetupTimeout()
    }

    /// Hands `capability` to the child frame's command world directly, as no
    /// reflowable hand-off does.
    func handChildFrame(_ capability: EPUBSpreadFrameCapability) async throws {
        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('iframe').contentWindow.readerLocatorCommands.acceptFrameCapability(capability, false);",
            arguments: ["capability": capability.id.uuidString],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
    }

    /// Dispatches, from the parent's page world, a capability message on the
    /// child frame's window that names the parent as its source, as a book's
    /// own script can.
    func dispatchPageScriptCapabilityMessage(_ capability: EPUBSpreadFrameCapability) async throws {
        _ = try await webView.callAsyncJavaScript(
            """
            const child = document.querySelector('iframe').contentWindow;
            child.dispatchEvent(new MessageEvent("message", {
                data: { type: "readium.locator.frameCapability", capability },
                origin: location.origin,
                source: window,
            }));
            """,
            arguments: ["capability": capability.id.uuidString],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    /// Posts the same capability message from the parent's page world: a
    /// real message, which the child accepts.
    func postCapabilityMessage(_ capability: EPUBSpreadFrameCapability) async throws {
        _ = try await webView.callAsyncJavaScript(
            """
            document.querySelector('iframe').contentWindow.postMessage(
                { type: "readium.locator.frameCapability", capability },
                location.origin
            );
            """,
            arguments: ["capability": capability.id.uuidString],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    /// The child frame's own read under `capability`, or `nil` when it does
    /// not hold it.
    func childFrameRead(_ capability: EPUBSpreadFrameCapability) async throws -> [String: Any]? {
        try await webView.callAsyncJavaScript(
            "return document.querySelector('iframe').contentWindow.readerLocatorCommands.readProgression(expectedCapability);",
            arguments: ["expectedCapability": capability.id.uuidString],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? [String: Any]
    }

    func waitForChildFrameSample(_ capability: EPUBSpreadFrameCapability) async throws -> (first: Double, last: Double) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        while clock.now < deadline {
            let sample = try await childFrameRead(capability)
            if
                let sample,
                sample["capability"] as? String == capability.id.uuidString,
                let first = (sample["first"] as? NSNumber)?.doubleValue,
                let last = (sample["last"] as? NSNumber)?.doubleValue
            {
                return (first, last)
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Setup: the child frame never answered under the capability it was handed")
        throw SetupTimeout()
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
        try await finishLoading(webView.loadHTMLString(document.html, baseURL: Self.url))
    }

    /// Loads `chapter.xhtml` from the server the page was built with.
    func load(servedFrom baseURL: AbsoluteURL) async throws {
        let url = try XCTUnwrap(baseURL.resolve(XCTUnwrap(RelativeURL(path: "chapter.xhtml")))?.url)
        try await finishLoading(webView.load(URLRequest(url: url)))
    }

    private func finishLoading(_ navigation: WKNavigation?) async throws {
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

    /// `[scrollX, scrollY]`.
    func offset() async throws -> [Double] {
        let value = try await webView.callAsyncJavaScript(
            "return [scrollX, scrollY];",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        return try XCTUnwrap(value as? [NSNumber], "Setup: the page offset was unreadable").map(\.doubleValue)
    }

    /// Jumps this page's resource to `progression` through the bridge, with
    /// the full budget from now.
    func jump(
        to progression: Double,
        animated: Bool = false,
        targetHREF: String = "chapter.xhtml"
    ) async throws -> EPUBLocatorCommandResult {
        try await bridge.navigate(
            toProgression: progression,
            targetHREF: XCTUnwrap(AnyURL(string: targetHREF)),
            animated: animated,
            deadline: EPUBLocatorOperationDeadline(
                startingAt: ContinuousClock().now,
                budget: .milliseconds(EPUBLocatorCommandBridge.totalCommandDeadlineMilliseconds)
            )
        )
    }

    /// Makes the command world's smooth scrolls land after `delay` and starts
    /// counting its scroll writes.
    func landCommandWorldSmoothScrolls(after delay: Duration) async throws {
        try await landSmoothScrolls(after: delay, in: webView, world: EPUBLocatorCommandBridge.contentWorld)
    }

    /// The command world's scroll writes since `landCommandWorldSmoothScrolls(after:)`.
    func commandWorldScrollWrites() async throws -> Int {
        try await countedScrollWrites(in: webView, world: EPUBLocatorCommandBridge.contentWorld)
    }

    /// Gives the document no viewport size in the command world, restored
    /// after `milliseconds` when given, and counts the reads of its width. A
    /// timer restores it, so the restore does not wait on animation frames a
    /// test holds.
    func emptyCommandWorldViewport(restoringAfterMilliseconds milliseconds: Int? = nil) async throws {
        try await runInCommandWorld(
            """
            globalThis.__viewportWidthReads = 0;
            Object.defineProperty(document.documentElement, "clientWidth", {
                get() {
                    globalThis.__viewportWidthReads += 1;
                    return 0;
                },
                configurable: true,
            });
            if (milliseconds !== null) {
                setTimeout(() => {
                    globalThis.__heldFramesAtViewportRestore = globalThis.__heldFrames?.length ?? 0;
                    delete document.documentElement.clientWidth;
                }, milliseconds);
            }
            """,
            arguments: ["milliseconds": milliseconds.map { $0 as Any } ?? NSNull()]
        )
    }

    /// Holds every animation frame the command world asks for from now on,
    /// after delivering the first `deliveredFrames`. Needs a page opened
    /// `holdingCommandWorldFrames`.
    func holdCommandWorldFrames(afterDelivering deliveredFrames: Int = 0) async throws {
        try await runInCommandWorld(
            "globalThis.__framesBeforeHolding = deliveredFrames; globalThis.__heldFrames = [];",
            arguments: ["deliveredFrames": deliveredFrames]
        )
    }

    /// How often the command world read the width
    /// `emptyCommandWorldViewport(restoringAfterMilliseconds:)` emptied.
    func commandWorldViewportWidthReads() async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__viewportWidthReads ?? 0;",
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? Int, "Setup: the viewport width reads were not counted")
    }

    /// How many of the frames `holdCommandWorldFrames(afterDelivering:)` was
    /// to deliver have not been asked for yet.
    func framesLeftBeforeHolding() async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__framesBeforeHolding;",
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? Int, "Setup: the frames left before holding were not counted")
    }

    /// Gives the document its viewport size back and invalidates the jump
    /// `executeProgressionJump(to:budgetMilliseconds:)` started, in one turn.
    /// Answers whether a command in flight was invalidated.
    func restoreViewportAndInvalidateTheJump() async throws -> Bool {
        let value = try await webView.callAsyncJavaScript(
            """
            delete document.documentElement.clientWidth;
            return readerLocatorCommands.invalidate({
                webViewInstanceID: "settled-location-test",
                documentEpoch: 0,
                operationKind: "navigation",
                sequence: 1,
                budgetMilliseconds: 0,
            }).invalidated;
            """,
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? Bool, "Setup: the invalidation's answer was unreadable")
    }

    /// Gives the document its viewport size back and, in the same turn,
    /// supersedes the jump `executeProgressionJump(to:budgetMilliseconds:)`
    /// started with a jump to the showing page, which writes nothing. Answers
    /// the superseding jump's `[outcome, reasonCode]`.
    func restoreViewportAndSupersedeTheJump() async throws -> [String] {
        let value = try await webView.callAsyncJavaScript(
            """
            delete document.documentElement.clientWidth;
            const result = await readerLocatorCommands.execute(
                { kind: "navigateProgression", progression: 0, animated: false },
                {
                    webViewInstanceID: "settled-location-test",
                    documentEpoch: 0,
                    operationKind: "navigation",
                    sequence: 2,
                    budgetMilliseconds: 5000,
                }
            );
            return [result.outcome, result.reasonCode];
            """,
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? [String], "Setup: the superseding jump's answer was unreadable")
    }

    /// Runs an instant navigation to the document's only element straight
    /// through the command world with `budgetMilliseconds` to spend, and
    /// answers its `[outcome, reasonCode]`.
    func executeLocatorNavigation(budgetMilliseconds: Int) async throws -> [String] {
        let value = try await webView.callAsyncJavaScript(
            """
            const result = await readerLocatorCommands.execute(
                { kind: "navigateLocator", payload: locator, animated: false },
                {
                    webViewInstanceID: "settled-location-test",
                    documentEpoch: 0,
                    operationKind: "navigation",
                    sequence: 1,
                    budgetMilliseconds,
                }
            );
            return [result.outcome, result.reasonCode];
            """,
            arguments: [
                "locator": Self.elementLocator,
                "budgetMilliseconds": budgetMilliseconds,
            ],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? [String], "Setup: the navigation's answer was unreadable")
    }

    /// How many animation frames the command world had been held from when
    /// `emptyCommandWorldViewport(restoringAfterMilliseconds:)` restored the
    /// viewport: the viewport wait's alone, before any landing frame.
    func heldCommandWorldFramesAtViewportRestore() async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__heldFramesAtViewportRestore ?? 0;",
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? Int, "Setup: the frames held at the viewport's restore were not counted")
    }

    /// How many animation frames the command world has been held from.
    func heldCommandWorldFrames() async throws -> Int {
        let value = try await webView.callAsyncJavaScript(
            "return globalThis.__heldFrames?.length ?? 0;",
            arguments: [:],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? Int, "Setup: the held frames were not counted")
    }

    /// Runs an instant progression jump straight through the command world and
    /// reads `scrollX` in the task the jump answers in, before a later task can
    /// move it.
    func executeProgressionJump(to progression: Double) async throws -> (outcome: String, scrollX: Double) {
        let value = try await webView.callAsyncJavaScript(
            """
            const result = await readerLocatorCommands.execute(
                { kind: "navigateProgression", progression, animated: false },
                {
                    webViewInstanceID: "settled-location-test",
                    documentEpoch: 0,
                    operationKind: "navigation",
                    sequence: 1,
                    budgetMilliseconds: 10000,
                }
            );
            return [result.outcome, scrollX];
            """,
            arguments: ["progression": progression],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        ) as? [Any]
        let outcome = try XCTUnwrap(value?.first as? String, "Setup: the jump's outcome was unreadable")
        let scrollX = try XCTUnwrap((value?.last as? NSNumber)?.doubleValue, "Setup: the jump's offset was unreadable")
        return (outcome, scrollX)
    }

    /// Runs an instant progression jump straight through the command world
    /// with `budgetMilliseconds` to spend, and answers its
    /// `[outcome, reasonCode]`.
    func executeProgressionJump(to progression: Double, budgetMilliseconds: Int) async throws -> [String] {
        let value = try await webView.callAsyncJavaScript(
            """
            const result = await readerLocatorCommands.execute(
                { kind: "navigateProgression", progression, animated: false },
                {
                    webViewInstanceID: "settled-location-test",
                    documentEpoch: 0,
                    operationKind: "navigation",
                    sequence: 1,
                    budgetMilliseconds,
                }
            );
            return [result.outcome, result.reasonCode];
            """,
            arguments: ["progression": progression, "budgetMilliseconds": budgetMilliseconds],
            in: nil,
            contentWorld: EPUBLocatorCommandBridge.contentWorld
        )
        return try XCTUnwrap(value as? [String], "Setup: the jump's answer was unreadable")
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
                "locator": Self.elementLocator,
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

    /// Dispatches a `pagehide` from the page world, as a book's own script
    /// can, while the document stays current.
    func dispatchPageScriptPagehide() async throws {
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

/// A real observation reading a held page through its real bridge. The bridge's
/// registrations, transport events and the readiness the test stands in for
/// (`open(_:)`, `clear()`) reach it through the observation's own spread-event
/// entry points, as `EPUBReflowableSpreadView` routes them.
@MainActor
private final class ObservedHeldPage {
    let held: HeldProgressionPage
    private(set) var accepted: [EPUBAcceptedObservation] = []
    /// The capability of the ready document, under which reads are eligible.
    private var capability: EPUBSpreadFrameCapability?
    /// Built once `self` exists, so its closures can reach it.
    private var builtObservation: EPUBLocationObservation!

    var observation: EPUBLocationObservation {
        builtObservation
    }

    init(_ held: HeldProgressionPage) throws {
        self.held = held
        let bridge = held.page.bridge
        let target = try XCTUnwrap(AnyURL(string: "chapter.xhtml"))
        builtObservation = EPUBLocationObservation(
            scheduler: held.deadlines.scheduler,
            eligibility: { [weak self] in
                self?.capability.map { .eligible($0) } ?? .unsettled
            },
            documentCapability: { [weak self] in
                self?.capability
            },
            nativeScrollOffset: { nil },
            read: { deadline, completion in
                bridge.readProgression(targetHREF: target, deadline: deadline, completion: completion)
            },
            reissueHandshake: { capability in
                bridge.setFrameCapability(capability)
            },
            onAccepted: { [weak self] accepted in
                self?.accepted.append(accepted)
            }
        )
        let registered = bridge.onFrameRegistered
        bridge.onFrameRegistered = { [weak self] capability in
            registered?(capability)
            self?.builtObservation.grant(.registration)
        }
        let reported = bridge.onLocationTransportEvent
        bridge.onLocationTransportEvent = { [weak self] event in
            reported?(event)
            self?.builtObservation.transportDidReport(event)
        }
    }

    private var generation: EPUBSpreadReadiness.Generation = 0

    /// A new document holding `capability` loads, hands it off and becomes
    /// ready, as the spread's readiness reports each step.
    func open(_ capability: EPUBSpreadFrameCapability) {
        generation += 1
        observation.readinessDidChange(to: .loading(generation: generation))
        held.page.bridge.beginDocument()
        held.page.bridge.setFrameCapability(capability)
        self.capability = capability
        observation.readinessDidChange(to: .ready(generation: generation, frameCapability: capability))
    }

    /// The spread is cleared, as `EPUBReflowableSpreadView.clear()` clears it.
    func clear() {
        capability = nil
        observation.readinessDidChange(to: .unavailable(generation: generation))
        held.page.bridge.revokeFrameCapability()
        observation.reset()
    }

    /// Answers location call `index`, failing rather than trapping when no
    /// such call was made.
    func complete(
        _ index: Int,
        with result: Result<Any, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard index < held.scripts.count else {
            return XCTFail("Location call \(index) was never made", file: file, line: line)
        }
        held.scripts.complete(index, with: result)
    }

    /// What the page answers a read of the ready document with.
    func answer(_ range: ClosedRange<Double>) -> [String: Any] {
        ["capability": capability?.id.uuidString ?? "", "first": range.lowerBound, "last": range.upperBound, "scrollX": 0, "scrollY": 0]
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

/// Records the location transport events a spread's bridge reports from now
/// on, still passing each to the spread. `.slotAvailable` follows any call's
/// actual completion, a read's, a capability injection's or a late one, and
/// only when nothing took the freed slot: a read whose completion starts a
/// pending hand-off reports none.
@MainActor
private final class TransportEventTap {
    private(set) var events: [EPUBLocationTransportEvent] = []

    init(_ bridge: EPUBLocatorCommandBridge) {
        let forward = bridge.onLocationTransportEvent
        bridge.onLocationTransportEvent = { [weak self] event in
            self?.events.append(event)
            forward?(event)
        }
    }
}

/// Joins the first initialization generation a spread's readiness enters from
/// now on as an extra writer. It joins on the main actor's next turn, which
/// comes at that generation's writer's first suspension: a readiness consumer
/// must not mutate readiness from its state callback.
@MainActor
private final class ExtraWriter {
    private(set) var lease: EPUBSpreadReadiness.WriterLease?
    private var hasJoined = false

    init(joiningTheNextGenerationOf readiness: EPUBSpreadReadiness) {
        let forward = readiness.onStateChange
        readiness.onStateChange = { [weak self, weak readiness] state in
            forward?(state)
            guard
                let self,
                let readiness,
                !hasJoined,
                case let .initializing(generation, _) = state
            else {
                return
            }
            hasJoined = true
            Task { @MainActor in
                self.lease = readiness.acquireWriterLease(for: generation)
            }
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
