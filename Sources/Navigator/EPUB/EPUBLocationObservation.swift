//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreFoundation
import Foundation

/// A measured viewport range of one reflowable document, tagged with the frame
/// capability that document held when it answered.
struct EPUBProgressionSample: Equatable, Sendable {
    let capability: EPUBSpreadFrameCapability
    let range: ClosedRange<Double>
}

/// The closed result of one progression read. These are observation results,
/// not navigation outcomes: none of them is a `PageTurnOutcome`.
enum EPUBProgressionReadOutcome: Equatable, Sendable {
    /// The selected frame measured its viewport under the current capability.
    case sample(EPUBProgressionSample)
    /// The document answered without a measurement: its geometry could not be
    /// measured, or it no longer held the capability. Transient.
    case unavailable
    /// The answer was malformed or named another capability. Fails closed.
    case invalid
    /// The logical deadline passed before WebKit answered. The call still
    /// occupies the transport until it actually completes.
    case expired
    /// The document, its capability or the selected frame changed before the
    /// answer arrived.
    case cancelled
    /// WebKit returned an error.
    case failed

    /// Decodes a `readProgression` answer for the document issued `capability`.
    /// A sample has exactly `capability`, `first` and `last`; the capability must
    /// be the expected one, and both ends ordered, finite, non-Boolean numbers
    /// in 0...1.
    static func decoding(
        _ value: Any,
        expecting capability: EPUBSpreadFrameCapability
    ) -> EPUBProgressionReadOutcome {
        // The script answers `null` when it cannot measure or no longer holds
        // the capability; WebKit delivers that as `NSNull`.
        if value is NSNull {
            return .unavailable
        }
        guard
            let payload = value as? [String: Any],
            Set(payload.keys) == ["capability", "first", "last"],
            payload["capability"] as? String == capability.id.uuidString,
            let first = unitInterval(payload["first"]),
            let last = unitInterval(payload["last"]),
            first <= last
        else {
            return .invalid
        }
        return .sample(EPUBProgressionSample(capability: capability, range: first ... last))
    }

    private static func unitInterval(_ value: Any?) -> Double? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        guard (0 ... 1).contains(double) else {
            return nil
        }
        return double
    }
}
