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

/// Real-navigator regressions for the location a reflowable spread reports once
/// a navigation settles. Every test hosts the public navigator in a key window
/// and lets it initialize on its own: readiness, frame registration and
/// progression messages all come from the production lifecycle.
@MainActor
final class EPUBSettledLocationReportingTests: XCTestCase {
    func test_commandTurnReportsMeasuredProgressionWithinSameResource() async throws {
        let reader = try await openReader()
        let initialLocation = reader.initialLocation
        let before = try await reader.requireGeometry()

        let report = reader.spy.expectLocation("post-turn report in the same resource") {
            $0.href.isEquivalentTo(initialLocation.href)
        }
        let moved = await reader.navigator.goForward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)

        let after = try await reader.waitForOffset(differentFrom: before)
        let measuredFirst = after.firstProgression

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        let location = try XCTUnwrap(reader.spy.matchedLocation, "No location was reported after the turn")
        XCTAssertEqual(location.href, initialLocation.href)
        let actual = try XCTUnwrap(location.locations.progression)
        XCTAssertGreaterThan(actual, initialLocation.locations.progression ?? 0)
        XCTAssertEqual(actual, measuredFirst, accuracy: 0.000_001)
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
    }

    func test_crossResourceTurnReportsTheMeasuredDestination() async throws {
        let reader = try await openReader(at: Self.nextChapterHREF, minimumScreens: 1)
        let before = try await reader.requireGeometry()

        let report = reader.spy.expectLocation("report of the previous resource") {
            $0.href.isEquivalentTo(Self.longChapterHREF.anyURL)
        }
        let moved = await reader.navigator.goBackward(options: NavigatorGoOptions(animated: false))
        XCTAssertTrue(moved)

        // Turning back lands on the previous resource's last page, so a report
        // of its start would be a fabricated position, not the destination.
        let after = try await reader.waitForOffset(differentFrom: before)
        XCTAssertGreaterThan(after.firstProgression, 0)

        await fulfillment(of: [report], timeout: Self.reportTimeout)
        let location = try XCTUnwrap(reader.spy.matchedLocation, "No destination location was reported")
        let actual = try XCTUnwrap(location.locations.progression)
        XCTAssertEqual(actual, after.firstProgression, accuracy: 0.000_001)
    }

    // MARK: - Fixture

    /// The production debounce is 300 ms; a report that has not arrived well
    /// past it is missing, not late.
    private static let reportTimeout: TimeInterval = 10

    /// How long an absent report is watched for. Several times the production
    /// debounce, so a late report of an invented move would land inside it.
    private static let quietWindow: TimeInterval = 2

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
        }

        let reader = Reader(window: window, navigator: navigator, spy: spy, initialLocation: initialLocation)
        try await reader.waitUntilUsable(minimumScreens: minimumScreens)
        return reader
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
    let initialLocation: Locator

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
        XCTFail(
            """
            Setup: the reader never reached a usable paginated viewport with an opening report. \
            reports=\(spy.locations.count), \
            state=\(currentSpread.map { "\($0.readiness.state)" } ?? "no spread"), \
            geometry=\(lastGeometry.map { "\($0)" } ?? "unmeasured")
            """
        )
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

/// Records every delegated location and fulfills one armed expectation with the
/// first location delivered after arming that satisfies its predicate. Arming
/// happens immediately before the action under test, so the opening report can
/// never satisfy it.
@MainActor
private final class LocationReportSpy: EPUBNavigatorDelegate {
    private(set) var locations: [Locator] = []
    private(set) var matchedLocation: Locator?
    private var pending: (predicate: (Locator) -> Bool, expectation: XCTestExpectation)?

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
