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
/// identity values. Errors are withheld too: NSError domains and custom error
/// descriptions can contain document-derived strings.
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
        /// A link activation body did not carry a usable `href`.
        case malformedLinkActivationBody = "malformed_link_activation_body"
        /// A scroll was requested to a progression outside `0...1`.
        case invalidScrollProgression = "invalid_scroll_progression"

        case positionsLoadFailed = "positions_load_failed"
        case internalLinkUnavailable = "internal_link_unavailable"
        case noteFragmentUnavailable = "note_fragment_unavailable"
        case noteResourceUnavailable = "note_resource_unavailable"
        case noteElementUnavailable = "note_element_unavailable"
        case noteReadFailed = "note_read_failed"
        case resourceRangeReadFailed = "resource_range_read_failed"
        case resourceReadFailed = "resource_read_failed"
        case anchorTrackingReinjectionFailed = "anchor_tracking_reinjection_failed"
        case fixedViewportFailed = "fixed_viewport_failed"
        case fixedLayoutStabilityFailed = "fixed_layout_stability_failed"
        case publicationCSSLoadFailed = "publication_css_load_failed"
        case anchorTrackingInitializationFailed = "anchor_tracking_initialization_failed"
        case reflowableLayoutStabilityFailed = "reflowable_layout_stability_failed"
        case javaScriptEvaluationFailed = "js_evaluation_failed"
        case webNavigationFailed = "web_navigation_failed"
        case provisionalWebNavigationFailed = "provisional_web_navigation_failed"

        /// The severity this reason is reported at.
        ///
        /// Owned by the reason rather than passed per call, so the level is part
        /// of the closed contract and cannot drift between sites.
        var level: SeverityLevel {
            switch self {
            case .javaScriptConsoleMessage, .malformedDOMRange:
                return .debug
            case .javaScriptUncaughtError, .positionsLoadFailed, .resourceRangeReadFailed, .resourceReadFailed, .publicationCSSLoadFailed, .javaScriptEvaluationFailed, .webNavigationFailed, .provisionalWebNavigationFailed:
                return .error
            case .malformedSelectionBody,
                 .malformedDecorationActivationBody,
                 .malformedImageActivationBody,
                 .malformedLinkActivationBody,
                 .invalidScrollProgression, .internalLinkUnavailable, .noteFragmentUnavailable, .noteResourceUnavailable, .noteElementUnavailable, .noteReadFailed, .anchorTrackingReinjectionFailed, .fixedViewportFailed, .fixedLayoutStabilityFailed, .anchorTrackingInitializationFailed, .reflowableLayoutStabilityFailed:
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
        log(reason.level, "Page world payload withheld reason=\(reason.rawValue)", file: file, line: line)
    }

    /// Accepts both values without rendering or forwarding either to the sink.
    static func report(
        _ reason: Reason,
        withholding payload: Any?,
        error: Error,
        file: String = #file,
        line: Int = #line
    ) {
        _ = error
        report(reason, withholding: payload, file: file, line: line)
    }

    enum NavigationState: String, CaseIterable {
        case initializing, loading, idle, jumping, moving
    }

    enum NavigationEvent: String, CaseIterable {
        case load, loaded, jump, jumped, move, moved
    }

    static func reportState(_ state: NavigationState, file: String = #file, line: Int = #line) {
        log(.debug, "Navigation state=\(state.rawValue)", file: file, line: line)
    }

    static func reportEvent(_ event: NavigationEvent, file: String = #file, line: Int = #line) {
        log(.debug, "Navigation event=\(event.rawValue)", file: file, line: line)
    }

    static func reportInvalidTransition(state: NavigationState, event: NavigationEvent,
                                        file: String = #file, line: Int = #line)
    {
        log(.error, "Invalid navigation event=\(event.rawValue) state=\(state.rawValue)", file: file, line: line)
    }
}
