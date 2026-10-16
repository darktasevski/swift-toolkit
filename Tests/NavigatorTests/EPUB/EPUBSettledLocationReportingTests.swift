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

/// Regressions for the location a reflowable spread reports once a navigation
/// settles. The navigator tests host the public navigator in a key window and
/// let it initialize on its own: readiness, frame registration and progression
/// messages all come from the production lifecycle. The progression-read tests
/// load documents of known geometry into a bare web view carrying the locator
/// command script, and issue its frame capability directly.
@MainActor
final class EPUBSettledLocationReportingTests: XCTestCase {
    func test_commandTurnReportsMeasuredProgressionWithinSameResource() async throws {
        let reader = try await openReader()
        let opening = try XCTUnwrap(reader.spy.locations.last)
        let openingProgression = try XCTUnwrap(opening.locations.progression)
        let before = try await reader.requireGeometry()

        // Only an advancing report can stand for the turn: a late repeat of
        // the opening position would otherwise satisfy a correct fix's test
        // with the wrong report.
        let report = reader.spy.expectLocation("advancing report in the same resource") {
            $0.href.isEquivalentTo(opening.href)
                && $0.locations.progression.map { $0 > openingProgression } == true
        }
        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)
        _ = try await reader.waitForOffset(differentFrom: before)

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        _ = try XCTUnwrap(reader.spy.matchedLocation, "No advancing location was reported after the turn")

        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let settled = try await reader.requireGeometry()
        assertEveryReport(reader.spy.locationsSinceArming, isIn: opening.href, at: settled.firstProgression)
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

        // Turning back lands on the previous resource's last page, so a report
        // of its start would be a fabricated position, not the destination.
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        let settled = try await reader.requireGeometry()
        XCTAssertGreaterThan(settled.firstProgression, 0)
        assertEveryReport(
            reader.spy.locationsSinceArming,
            isIn: Self.longChapterHREF.anyURL,
            at: settled.firstProgression
        )
    }

    /// Checks every report since the action, not only the first match: once a
    /// navigation settles, only its final location may be delivered, so a
    /// stale or fabricated report arriving around the correct one is a defect.
    private func assertEveryReport(
        _ reports: [Locator],
        isIn href: AnyURL,
        at progression: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(reports.isEmpty, "No report to check", file: file, line: line)
        for (index, report) in reports.enumerated() {
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

    // MARK: - Isolated-world progression read

    func test_progressionReadMeasuresLeftToRightPages() async throws {
        let page = try await openProgressionPage(.leftToRightPages)
        try await page.acceptCapability(ProgressionPage.capability)
        try await page.scroll(x: 600, y: 0)

        try await assertSample(page.read(ProgressionPage.capability), first: 1.0 / 3, last: 2.0 / 3)
    }

    func test_progressionReadMeasuresRightToLeftPagesByTheirAbsoluteOffset() async throws {
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

    func test_progressionReadRejectsMalformedGeometry() async throws {
        let stubs: [GeometryStub] = [
            .window("innerWidth", "0"),
            .window("innerHeight", "0"),
            .window("innerWidth", "Infinity"),
            .window("scrollX", "NaN"),
            .root("scrollWidth", "0"),
            .noRoot,
        ]
        for stub in stubs {
            let page = try await openProgressionPage(.leftToRightPages)
            try await page.acceptCapability(ProgressionPage.capability)

            let (observed, sample) = try await page.read(ProgressionPage.capability, stubbing: stub)
            XCTAssertEqual(observed, stub.value, "\(stub) did not take effect")
            XCTAssertNil(sample, "\(stub) produced a progression")
        }
    }

    func test_progressionReadClampsFiniteOverscroll() async throws {
        let cases: [(offset: String, first: Double, last: Double)] = [
            ("1500", 5.0 / 6, 1),
            ("-300", 0, 1.0 / 6),
        ]
        for overscroll in cases {
            let page = try await openProgressionPage(.leftToRightPages)
            try await page.acceptCapability(ProgressionPage.capability)

            let stub = GeometryStub.window("scrollX", overscroll.offset)
            let (observed, sample) = try await page.read(ProgressionPage.capability, stubbing: stub)
            XCTAssertEqual(observed, stub.value, "\(stub) did not take effect")
            assertSample(sample, first: overscroll.first, last: overscroll.last)
        }
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

    /// The read returns exactly the capability it answered under and the
    /// measured range; anything more or less is a malformed sample.
    private func assertSample(
        _ value: Any?,
        capability: String = ProgressionPage.capability,
        first: Double,
        last: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let sample = value as? [String: Any] else {
            XCTFail("Expected a progression sample, got \(String(describing: value))", file: file, line: line)
            return
        }
        XCTAssertEqual(Set(sample.keys), ["capability", "first", "last"], file: file, line: line)
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
        minimumScreens: Int = 3
    ) async throws -> Reader {
        let initialLocation = Locator(
            href: href.anyURL,
            mediaType: .html,
            locations: Locator.Locations(progression: 0)
        )
        let navigator = try EPUBNavigatorViewController(
            publication: makePublication(),
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
        try await reader.waitUntilUsable(minimumScreens: minimumScreens)
        try await reader.waitForReportsToSettle(quietFor: .seconds(Self.quietWindow))
        return reader
    }

    private func openProgressionPage(_ document: ProgressionDocument) async throws -> ProgressionPage {
        let page = try ProgressionPage()
        addTeardownBlock { @MainActor in
            page.window.isHidden = true
            page.window.rootViewController = nil
        }
        try await page.load(document)
        return page
    }

    private func makePublication() -> Publication {
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
                metadata: Metadata(title: "Settled location reporting", layout: .reflowable),
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
            )
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
    func waitUntilUsable(minimumScreens: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.setupTimeout)
        var lastGeometry: PageGeometry?
        while clock.now < deadline {
            if
                !spy.locations.isEmpty,
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
        // reports loading. Every other expiry is a navigator defect.
        if let spread = currentSpread, case .loading = spread.readiness.state, spread.webView.isLoading {
            throw XCTSkip(
                "Setup: WebContent process is not making progress (see #1693). \(diagnosis)"
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

/// Documents whose geometry is fixed by construction, so every expected
/// progression is a constant rather than something read back from the page.
/// The first four fill a 600×800 viewport three or four times over along one
/// axis; the odd spread lays out three 300 px columns, one and a half screens.
private enum ProgressionDocument {
    case leftToRightPages
    case rightToLeftPages
    case verticalScroll
    case verticalWritingScroll
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

/// A bare web view carrying only the locator command script, hosted at the
/// navigator tests' 600×800 size. Nothing here mints readiness or registers a
/// frame: the capability is issued straight to the document under test.
@MainActor
private final class ProgressionPage {
    static let capability = "settled-location-test-capability"
    private static let url = URL(string: "https://readium.test/chapter.xhtml")!
    private static let setupTimeout: Duration = .seconds(30)

    let window: UIWindow
    let webView: WKWebView
    private let loads = LoadObserver()

    init() throws {
        let bridge = try EPUBLocatorCommandBridge(
            layout: .reflowable,
            publicationBaseURL: XCTUnwrap(HTTPURL(string: "https://readium.test/"))
        )
        let configuration = WKWebViewConfiguration()
        // iPad's desktop-class default scales wide content down to fit, which
        // would change the viewport the expected progressions are built on.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        bridge.install(in: configuration)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        webView = WKWebView(frame: window.bounds, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = loads
        let host = UIViewController()
        host.view.addSubview(webView)
        window.rootViewController = host
        window.makeKeyAndVisible()
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
            // Same earned skip as the navigator setup: only a load WebKit still
            // believes is in progress points at the #1693 WebContent hang.
            if webView.isLoading {
                throw XCTSkip("Setup: WebContent process is not making progress (see #1693). \(diagnosis)")
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
