//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
@testable import ReadiumShared
import XCTest

/// Captures everything the framework logs so a test can assert on it.
private final class CapturingLogger: LoggerType {
    private let lock = NSLock()
    private var lines: [String] = []
    private var levels: [SeverityLevel] = []
    private var objectCount = 0

    func log(level: SeverityLevel, value: Any?, file: String, line: Int) {
        let rendered = "\(level.rawValue) \(file):\(line): \(String(describing: value))"
        lock.lock()
        if !(value is String) {
            objectCount += 1
        }
        lines.append(rendered)
        levels.append(level)
        lock.unlock()
    }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var capturedObjectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return objectCount
    }

    var capturedLevels: [SeverityLevel] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }
}

/// Proves that the page-world log choke point emits a real log line while none
/// of the payload it was handed survives into it.
///
/// The sentinels below stand for each class of page-world data the choke point
/// exists to withhold. They are single tokens with no substring overlap with the
/// reason codes, so a hit is unambiguous.
final class EPUBPageWorldLogTests: XCTestCase {
    private enum Sentinel {
        static let bookText = "ZZBOOKTEXTZZ"
        static let quote = "ZZQUOTEZZ"
        static let href = "ZZHREFZZ"
        static let title = "ZZTITLEZZ"
        static let selector = "ZZSELECTORZZ"
        static let locator = "ZZLOCATORZZ"
        static let script = "ZZSCRIPTZZ"
        static let rawError = "ZZRAWERRORZZ"
        static let domain = "ZZDOMAINZZ"
        static let geometry = "ZZGEOMETRYZZ"

        static let all = [
            bookText, quote, href, title, selector,
            locator, script, rawError, domain, geometry,
        ]
    }

    /// A payload shaped like the bodies the JS bridge actually delivers, with
    /// every field replaced by its sentinel.
    private var adversarialPayload: [String: Any] {
        [
            "href": "https://\(Sentinel.href).example/\(Sentinel.href).xhtml#\(Sentinel.href)",
            "title": Sentinel.title,
            "text": [
                "before": Sentinel.bookText,
                "highlight": Sentinel.quote,
                "after": Sentinel.bookText,
            ],
            "locator": "{\"href\":\"\(Sentinel.locator)\",\"locations\":{\"cssSelector\":\"\(Sentinel.selector)\"}}",
            "cssSelector": "body > div:nth-child(3) > p.\(Sentinel.selector)",
            "message": "\(Sentinel.script) threw \(Sentinel.rawError)",
            "filename": "https://\(Sentinel.href).example/\(Sentinel.script).js",
            "line": 4711,
            "src": "https://\(Sentinel.href).example/\(Sentinel.title).png",
            "alt": Sentinel.bookText,
            "caption": Sentinel.quote,
            "attribution": Sentinel.title,
            "rect": [
                "x": Sentinel.geometry,
                "y": Sentinel.geometry,
                "width": Sentinel.geometry,
                "height": Sentinel.geometry,
            ],
        ]
    }

    /// An error whose every renderable surface carries a sentinel, including a caller-controlled domain, so only withholding stays clean.
    private var adversarialError: Error {
        NSError(
            domain: "ZZDOMAINZZ",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "\(Sentinel.rawError) at \(Sentinel.selector)",
                NSLocalizedFailureReasonErrorKey: Sentinel.bookText,
                "payload": Sentinel.locator,
            ]
        )
    }

    /// A native Swift error, not an `NSError`. This is the shape `DOMRange(json:)`
    /// actually throws, and it bridges differently: `localizedDescription` comes
    /// from the `LocalizedError` conformance, and the domain becomes the mangled
    /// Swift type name. Both shapes must be withheld without bridging or describing the error.
    private enum SentinelError: Error, LocalizedError {
        case leaked(String)

        var errorDescription: String? {
            switch self {
            case let .leaked(text): return text
            }
        }
    }

    private var logger: CapturingLogger!
    private var priorLogger: LoggerType?
    private var priorMinimumSeverityLevel: SeverityLevel?

    override func setUp() {
        super.setUp()
        // The framework default is NO logger at all, not a `LoggerStub`. Calling
        // `ReadiumEnableLog` to "reset" would install one, leaving every later
        // test in this process printing at `.warning`+ where nothing printed
        // before — so snapshot the real prior state and put it back instead.
        priorLogger = Logger.sharedInstance.activeLogger
        priorMinimumSeverityLevel = Logger.sharedInstance.minimumSeverityLevel

        logger = CapturingLogger()
        // `.trace` so no reason's own level can be filtered out, which would
        // make an absent sentinel prove nothing.
        install(logger, at: .trace)
    }

    override func tearDown() {
        Logger.sharedInstance.activeLogger = priorLogger
        Logger.sharedInstance.minimumSeverityLevel = priorMinimumSeverityLevel
        logger = nil
        super.tearDown()
    }

    /// Installs `sink` at `level`, bypassing `ReadiumEnableLog` — which prints a
    /// banner on every call and cannot express "no logger".
    private func install(_ sink: LoggerType?, at level: SeverityLevel?) {
        Logger.sharedInstance.activeLogger = sink
        Logger.sharedInstance.minimumSeverityLevel = level
    }

    // MARK: - Plumbing ran

    func testEveryReasonEmitsALogLineCarryingItsCode() {
        for reason in EPUBPageWorldLog.Reason.allCases {
            EPUBPageWorldLog.report(reason, withholding: adversarialPayload)
        }

        let captured = logger.captured
        XCTAssertEqual(
            captured.count,
            EPUBPageWorldLog.Reason.allCases.count,
            "logging plumbing did not run for every reason"
        )
        for reason in EPUBPageWorldLog.Reason.allCases {
            XCTAssertTrue(
                captured.contains { $0.contains("reason=\(reason.rawValue)") },
                "no log line carried reason=\(reason.rawValue)"
            )
        }
    }

    func testTheErrorOverloadWithholdsAllErrorDetails() throws {
        EPUBPageWorldLog.report(
            .malformedDOMRange,
            withholding: adversarialPayload,
            error: adversarialError
        )

        let captured = logger.captured
        XCTAssertEqual(captured.count, 1)
        let line = try XCTUnwrap(captured.first)
        XCTAssertTrue(line.contains("reason=malformed_dom_range"))
        XCTAssertFalse(line.contains("type=NSError"), "raw error type is withheld")
        XCTAssertFalse(line.contains("ZZDOMAINZZ"), "arbitrary error domains are content")
        XCTAssertFalse(
            line.contains(Sentinel.rawError),
            "the error's localized description reached the log"
        )
    }

    /// The capture assertions below only mean something if this logger can see a
    /// sentinel at all. Without this control, a silently-detached logger would
    /// make every absence assertion pass vacuously.
    func testTheCapturingLoggerCanObserveASentinel() {
        // Emitted through the same `Loggable` path the choke point uses, so this
        // control fails if that path is what is broken.
        EPUBPageWorldLog.log(.warning, "control \(Sentinel.bookText)")

        XCTAssertTrue(
            logger.captured.contains { $0.contains(Sentinel.bookText) },
            "the capture harness has no resolving power"
        )
    }

    // MARK: - Sentinels absent

    func testNoSentinelSurvivesAnyReportOverload() {
        for reason in EPUBPageWorldLog.Reason.allCases {
            EPUBPageWorldLog.report(reason, withholding: adversarialPayload)
            EPUBPageWorldLog.report(
                reason,
                withholding: adversarialPayload,
                error: adversarialError
            )
            // The native-Swift shape as well as the `NSError` one: they bridge
            // differently, and only one of them was covered.
            EPUBPageWorldLog.report(
                reason,
                withholding: adversarialPayload,
                error: SentinelError.leaked(Sentinel.rawError)
            )
        }

        let captured = logger.captured
        XCTAssertFalse(captured.isEmpty, "nothing was logged, so absence proves nothing")
        XCTAssertEqual(logger.capturedObjectCount, 0, "raw objects must not reach the logger")

        for line in captured {
            for sentinel in Sentinel.all {
                XCTAssertFalse(
                    line.contains(sentinel),
                    "page-world sentinel \(sentinel) reached the log: \(line)"
                )
            }
        }
    }

    func testNavigationDiagnosticsRetainOnlyClosedTokens() throws {
        let locator = try Locator(href: XCTUnwrap(AnyURL(string: "ZZHREFZZ")), mediaType: .html, title: Sentinel.title,
                                  text: .init(highlight: Sentinel.bookText))
        let states: [(EPUBNavigatorViewController.State, EPUBPageWorldLog.NavigationState)] = [
            (.initializing, .initializing), (.loading(pendingLocator: nil), .loading),
            (.loading(pendingLocator: locator), .loading), (.idle, .idle),
            (.jumping(pendingLocator: locator), .jumping), (.moving(direction: .left), .moving),
        ]
        let events: [(EPUBNavigatorViewController.Event, EPUBPageWorldLog.NavigationEvent)] = [
            (.load(nil), .load), (.load(locator), .load), (.loaded, .loaded),
            (.jump(locator), .jump), (.jumped, .jumped), (.move(.left), .move), (.moved, .moved),
        ]
        for (state, token) in states {
            XCTAssertEqual(state.logToken, token)
            EPUBPageWorldLog.reportState(state.logToken)
            XCTAssertTrue(logger.captured.last?.contains("state=\(token.rawValue)") == true)
            XCTAssertEqual(logger.capturedLevels.last, .debug)
        }
        for (event, token) in events {
            XCTAssertEqual(event.logToken, token)
            EPUBPageWorldLog.reportEvent(event.logToken)
            XCTAssertTrue(logger.captured.last?.contains("event=\(token.rawValue)") == true)
            XCTAssertEqual(logger.capturedLevels.last, .debug)
        }
        var state = EPUBNavigatorViewController.State.initializing
        XCTAssertFalse(state.transition(.jump(locator)))
        XCTAssertEqual(state, .initializing)
        XCTAssertTrue(logger.captured.last?.contains("event=jump state=initializing") == true)
        XCTAssertEqual(logger.capturedLevels.last, .error)
        for sentinel in Sentinel.all {
            XCTAssertFalse(logger.captured.contains { $0.contains(sentinel) })
        }
    }

    // MARK: - Severity

    /// The reason→level table, asserted directly. Every other test installs the
    /// logger at `.trace` so no level can be filtered, which means none of them
    /// would notice a reason's severity changing.
    func testEveryReasonReportsAtItsDeclaredLevel() {
        let expected: [EPUBPageWorldLog.Reason: SeverityLevel] = [
            .javaScriptConsoleMessage: .debug,
            .malformedDOMRange: .debug,
            .javaScriptUncaughtError: .error,
            .malformedSelectionBody: .warning,
            .malformedDecorationActivationBody: .warning,
            .malformedImageActivationBody: .warning,
            .invalidScrollProgression: .warning,
            .positionsLoadFailed: .error,
            .internalLinkUnavailable: .warning,
            .noteFragmentUnavailable: .warning,
            .noteResourceUnavailable: .warning,
            .noteElementUnavailable: .warning,
            .noteReadFailed: .warning,
            .resourceRangeReadFailed: .error,
            .resourceReadFailed: .error,
            .anchorTrackingReinjectionFailed: .warning,
            .fixedViewportFailed: .warning,
            .fixedLayoutStabilityFailed: .warning,
            .publicationCSSLoadFailed: .error,
            .anchorTrackingInitializationFailed: .warning,
            .reflowableLayoutStabilityFailed: .warning,
            .javaScriptEvaluationFailed: .error,
            .webNavigationFailed: .error,
            .provisionalWebNavigationFailed: .error,
        ]
        // Driven off `allCases` so a new reason forces a decision here rather
        // than inheriting a neighbour's severity silently.
        XCTAssertEqual(
            Set(expected.keys),
            Set(EPUBPageWorldLog.Reason.allCases),
            "the level table has drifted from the reason inventory"
        )

        for reason in EPUBPageWorldLog.Reason.allCases {
            EPUBPageWorldLog.report(reason, withholding: adversarialPayload)
            XCTAssertEqual(
                logger.capturedLevels.last,
                expected[reason],
                "\(reason) reported at the wrong severity"
            )
        }
    }

    /// The real-world consequence of the table: a consumer filtering at
    /// `.warning` must still see an uncaught script error, and must not be
    /// spammed by routine console traffic.
    func testTheTwoDebugReasonsAreSuppressedAtAWarningFloor() {
        install(logger, at: .warning)

        for reason in EPUBPageWorldLog.Reason.allCases {
            EPUBPageWorldLog.report(reason, withholding: adversarialPayload)
        }

        let captured = logger.captured
        XCTAssertEqual(captured.count, EPUBPageWorldLog.Reason.allCases.filter { $0.level != .debug }.count)
        XCTAssertFalse(captured.contains { $0.contains("reason=js_console_message") })
        XCTAssertFalse(captured.contains { $0.contains("reason=malformed_dom_range") })
        XCTAssertTrue(
            captured.contains { $0.contains("reason=js_uncaught_error") },
            "an uncaught script error must survive a warning floor"
        )
    }

    /// Guards the inventory: a reason whose token stops being a fixed snake-case
    /// identifier could start carrying derived text.
    func testEveryReasonCodeIsAFixedLowercaseToken() {
        for reason in EPUBPageWorldLog.Reason.allCases {
            XCTAssertFalse(reason.rawValue.isEmpty)
            XCTAssertEqual(
                reason.rawValue,
                reason.rawValue.lowercased(),
                "\(reason) is not a lowercase token"
            )
            XCTAssertNil(
                reason.rawValue.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_").inverted),
                "\(reason) carries characters outside [a-z_]"
            )
        }
    }
}
