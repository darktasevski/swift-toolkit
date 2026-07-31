//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// The single point through which a page-world payload may reach a log sink.
///
/// Everything a `WKWebView` hands back from the rendered document is page-world
/// data: book text and quotes from a selection, resource hrefs, document titles,
/// CSS selectors and locators from a decoration or command reply, script source
/// from a console message, and viewport geometry. None of it may be logged.
///
/// Every such site therefore reports here, hands over its raw payload, and gets
/// back a static closed reason code. The payload is *accepted* so that no call
/// site has to remember to strip it, and *never read* so that no call site is
/// able to render it — the same posture as the redacting log wrappers used for
/// identity values. An error is reduced to its Swift type plus its bridged
/// `NSError` domain and code, all three of which are compile-time constants of
/// the error's own declaration rather than anything derived from the document.
enum EPUBPageWorldLog: Loggable {
    /// Why a page-world payload was withheld.
    ///
    /// One case per reporting site. The raw values are the stable tokens that
    /// appear in the log, so they are written as fixed snake-case identifiers
    /// rather than derived from the case names.
    enum Reason: String, CaseIterable {
        /// The page world called the `log` bridge (`console`-level message).
        case javaScriptConsoleMessage = "js_console_message"
        /// The page world called the `logError` bridge (uncaught script error).
        case javaScriptUncaughtError = "js_uncaught_error"
        /// A `selectionChanged` body did not carry an href, text and rect.
        case malformedSelectionBody = "malformed_selection_body"
        /// A selection's `domRange` failed to decode.
        case malformedDOMRange = "malformed_dom_range"
        /// A decoration activation body did not carry an id, group and rect.
        case malformedDecorationActivationBody = "malformed_decoration_activation_body"
        /// An image activation body did not carry a usable `src`.
        case malformedImageActivationBody = "malformed_image_activation_body"
        /// A scroll was requested to a progression outside `0...1`.
        case invalidScrollProgression = "invalid_scroll_progression"

        /// The severity this reason is reported at.
        ///
        /// Owned by the reason rather than passed per call, so the level is part
        /// of the closed contract and cannot drift between sites.
        var level: SeverityLevel {
            switch self {
            case .javaScriptConsoleMessage, .malformedDOMRange:
                return .debug
            case .javaScriptUncaughtError:
                return .error
            case .malformedSelectionBody,
                 .malformedDecorationActivationBody,
                 .malformedImageActivationBody,
                 .invalidScrollProgression:
                return .warning
            }
        }
    }

    /// The fixed prefix every withheld-payload log line carries.
    static let messagePrefix = "Page world payload withheld"

    /// Reports `reason`, withholding `payload`.
    ///
    /// `payload` is deliberately unread. Passing it is what makes the drop
    /// explicit at the call site and impossible to forget.
    static func report(
        _ reason: Reason,
        withholding payload: Any?,
        file: String = #file,
        line: Int = #line
    ) {
        _ = payload
        log(reason.level, message(reason), file: file, line: line)
    }

    /// Reports `reason`, withholding `payload` and reducing `error` to its type,
    /// bridged domain and bridged code.
    static func report(
        _ reason: Reason,
        withholding payload: Any?,
        error: Error,
        file: String = #file,
        line: Int = #line
    ) {
        _ = payload
        let ns = error as NSError
        log(
            reason.level,
            "\(message(reason)) type=\(type(of: error)) [\(ns.domain)#\(ns.code)]",
            file: file,
            line: line
        )
    }

    /// The message logged for `reason`, without any error detail.
    static func message(_ reason: Reason) -> String {
        "\(messagePrefix) reason=\(reason.rawValue)"
    }
}
