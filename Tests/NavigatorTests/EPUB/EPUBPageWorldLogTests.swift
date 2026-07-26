//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import XCTest

/// Captures everything the framework logs so a test can assert on it.
private final class CapturingLogger: LoggerType {
    private let lock = NSLock()
    private var lines: [String] = []

    func log(level: SeverityLevel, value: Any?, file: String, line: Int) {
        let rendered = "\(level.rawValue) \(file):\(line): \(String(describing: value))"
        lock.lock()
        lines.append(rendered)
        lock.unlock()
    }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
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
        static let geometry = "ZZGEOMETRYZZ"

        static let all = [
            bookText, quote, href, title, selector,
            locator, script, rawError, geometry,
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

    /// An error whose every renderable surface carries a sentinel, so reducing
    /// it to type/domain/code is the only way to stay clean.
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

    private var logger: CapturingLogger!

    override func setUp() {
        super.setUp()
        logger = CapturingLogger()
        // `.trace` so no reason's own level can be filtered out, which would
        // make an absent sentinel prove nothing.
        ReadiumEnableLog(withMinimumSeverityLevel: .trace, customLogger: logger)
    }

    override func tearDown() {
        // Restores the framework default: a `LoggerStub` at `.warning`.
        ReadiumEnableLog(withMinimumSeverityLevel: .warning)
        logger = nil
        super.tearDown()
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

    func testTheErrorOverloadEmitsTypeDomainAndCodeOnly() throws {
        EPUBPageWorldLog.report(
            .malformedDOMRange,
            withholding: adversarialPayload,
            error: adversarialError
        )

        let captured = logger.captured
        XCTAssertEqual(captured.count, 1)
        let line = try XCTUnwrap(captured.first)
        XCTAssertTrue(line.contains("reason=malformed_dom_range"))
        XCTAssertTrue(line.contains("type=NSError"), "the error's Swift type is the only type detail")
        XCTAssertTrue(line.contains("[ZZDOMAINZZ#42]"), "domain and code are reported")
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
        }

        let captured = logger.captured
        XCTAssertFalse(captured.isEmpty, "nothing was logged, so absence proves nothing")

        for line in captured {
            for sentinel in Sentinel.all {
                XCTAssertFalse(
                    line.contains(sentinel),
                    "page-world sentinel \(sentinel) reached the log: \(line)"
                )
            }
        }
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

/// Proves the spread's log call sites still route page-world data through the
/// choke point.
///
/// `EPUBPageWorldLogTests` proves the choke point itself withholds a payload.
/// That says nothing about whether the handlers still use it — a single
/// `log(.warning, "bad body: \(body)")` restores the leak without failing any
/// behavioural test, because a log line has no observable effect on navigation.
/// So this reads the spread sources and pins the complete inventory of what any
/// log call in them may interpolate. Anything new fails until it is reviewed and
/// added here, which is the point.
final class EPUBSpreadLogInterpolationTests: XCTestCase {
    /// The exact set of expressions a log call in the spread sources
    /// interpolates, pinned in both directions: a new one fails, and so does a
    /// stale entry, so this list cannot quietly pre-authorise something nothing
    /// uses.
    ///
    /// Each is a compile-time constant of our own declarations or a count, never
    /// a value read out of the rendered document:
    ///
    /// - `type(of: error)`, `ns.domain`, `ns.code` — the sanctioned error shape.
    /// - `rawAnchorIds.count` — a cardinality, used when a list exceeds its cap.
    /// - `name` — a JS message-handler name, supplied only as a literal by
    ///   `registerJSMessages()`, reported when one is registered twice.
    private static let allowedInterpolations: Set<String> = [
        "type(of: error)",
        "ns.domain",
        "ns.code",
        "rawAnchorIds.count",
        "name",
    ]

    private static let spreadSourceNames = [
        "EPUBSpreadView.swift",
        "EPUBReflowableSpreadView.swift",
        "EPUBFixedSpreadView.swift",
    ]

    /// `Sources/Navigator/EPUB`, derived from this file's location so the test
    /// needs no bundled resource.
    private static var spreadSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            // …/Tests/NavigatorTests/EPUB/<this file>
            .deletingLastPathComponent() // EPUB
            .deletingLastPathComponent() // NavigatorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/Navigator/EPUB")
    }

    private func source(named name: String) throws -> String {
        let url = Self.spreadSourceDirectory.appendingPathComponent(name)
        // Fail rather than skip: an unreadable source would make every
        // assertion below pass vacuously.
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Lines that emit a log, whether directly through `Loggable` or through the
    /// choke point.
    private func logEmittingLines(in source: String) -> [String] {
        source
            .components(separatedBy: .newlines)
            .filter { $0.contains("log(.") || $0.contains("PageWorldLog.report(") }
    }

    // MARK: - The inventory

    func testNoLogCallInTheSpreadSourcesInterpolatesAnythingUnreviewed() throws {
        for name in Self.spreadSourceNames {
            let source = try source(named: name)
            for line in logEmittingLines(in: source) {
                for interpolation in Self.interpolations(in: line) {
                    XCTAssertTrue(
                        Self.allowedInterpolations.contains(interpolation),
                        """
                        \(name) interpolates \\(\(interpolation)) into a log call. \
                        If it cannot carry page-world data, add it to \
                        allowedInterpolations; otherwise route the site through \
                        EPUBPageWorldLog.report.
                        """
                    )
                }
            }
        }
    }

    /// A log call split across lines would hide its message from the scan above.
    func testEveryLogCallInTheSpreadSourcesIsWrittenOnOneLine() throws {
        for name in Self.spreadSourceNames {
            let source = try source(named: name)
            for line in logEmittingLines(in: source) {
                XCTAssertEqual(
                    line.filter { $0 == "(" }.count,
                    line.filter { $0 == ")" }.count,
                    """
                    \(name) has a log call spanning lines, so \
                    testNoLogCallInTheSpreadSourcesInterpolatesAnythingUnreviewed \
                    cannot see its message: \(line.trimmingCharacters(in: .whitespaces))
                    """
                )
            }
        }
    }

    /// Catches a stale allowlist entry, which would pre-authorise an
    /// interpolation no call site currently makes.
    func testTheAllowlistIsExactlyWhatTheSpreadSourcesInterpolate() throws {
        XCTAssertEqual(
            try scan().interpolations,
            Self.allowedInterpolations,
            "allowedInterpolations has drifted from the spread sources"
        )
    }

    // MARK: - Harness controls

    /// Without this, a scan that found no log lines at all — wrong directory,
    /// renamed file — would report success.
    func testTheScanFindsLogCallsAndAKnownInterpolation() throws {
        let scanned = try scan()

        XCTAssertGreaterThan(scanned.logLineCount, 10, "the scan found almost no log calls")
        XCTAssertTrue(
            scanned.interpolations.contains("type(of: error)"),
            "the scan has no resolving power: it did not find the known error shape"
        )
    }

    private func scan() throws -> (interpolations: Set<String>, logLineCount: Int) {
        var interpolations: Set<String> = []
        var logLineCount = 0

        for name in Self.spreadSourceNames {
            let lines = try logEmittingLines(in: source(named: name))
            logLineCount += lines.count
            for line in lines {
                interpolations.formUnion(Self.interpolations(in: line))
            }
        }

        return (interpolations, logLineCount)
    }

    func testTheInterpolationScannerHandlesNestedParentheses() {
        XCTAssertEqual(
            Self.interpolations(in: #"log(.error, "a \(type(of: error)) b \(ns.code)")"#),
            ["type(of: error)", "ns.code"]
        )
        XCTAssertEqual(Self.interpolations(in: #"log(.warning, "static message")"#), [])
    }

    // MARK: - Scanner

    /// Extracts each balanced `\(…)` interpolation from a line of Swift source.
    private static func interpolations(in line: String) -> [String] {
        let characters = Array(line)
        var results: [String] = []
        var index = 0

        while index + 1 < characters.count {
            guard characters[index] == "\\", characters[index + 1] == "(" else {
                index += 1
                continue
            }

            var depth = 0
            var cursor = index + 1
            var captured = ""

            while cursor < characters.count {
                let character = characters[cursor]
                if character == "(" {
                    depth += 1
                    if depth == 1 {
                        cursor += 1
                        continue
                    }
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }
                captured.append(character)
                cursor += 1
            }

            results.append(captured)
            index = cursor + 1
        }

        return results
    }
}
