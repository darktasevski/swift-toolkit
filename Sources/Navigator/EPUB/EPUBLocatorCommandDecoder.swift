//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

enum EPUBLocatorCommandRejection: String, Error, Equatable, Sendable {
    case malformed
    case payloadTooLarge
    case nestingTooDeep
    case duplicateField
    case invalidRoot
    case unknownField
    case missingRequiredField
    case invalidField
    case stringTooLong
    case selectorTooLong
    case quoteContextTooLong
    case highlightTooLong
    case invalidNumber
    case invalidInteger
    case invalidDOMRange
}

struct EPUBLocatorCommandPayload: Sendable {
    let href: String
    let locator: JSONValue
}

enum EPUBLocatorCommandDecoder {
    private enum Limits {
        static let payloadBytes = 64 * 1024
        static let nestingDepth = 6
        static let stringUTF16 = 16 * 1024
        static let selectorUTF16 = 8 * 1024
        static let hrefOrTitleUTF16 = 4 * 1024
        // selection.js persists at most 200 UTF-16 units on either side of a selection.
        // Keep the decoder bounded while accepting the complete producer contract, including
        // locators already persisted by clients before isolated commands were introduced.
        static let quoteContextUTF16 = 200
        static let highlightUTF16 = 16384
    }

    static func decode(_ source: String) throws -> EPUBLocatorCommandPayload {
        let data = Data(source.utf8)
        guard data.count <= Limits.payloadBytes else {
            throw EPUBLocatorCommandRejection.payloadTooLarge
        }

        var scanner = StrictJSONShapeScanner(bytes: Array(data), maximumDepth: Limits.nestingDepth)
        try scanner.scan()

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw EPUBLocatorCommandRejection.malformed
        }
        guard let value = JSONValue(raw), let object = value.object else {
            throw EPUBLocatorCommandRejection.invalidRoot
        }

        try requireOnlyKeys(object, allowed: ["href", "type", "title", "locations", "text"])
        guard let hrefValue = object["href"] else {
            throw EPUBLocatorCommandRejection.missingRequiredField
        }
        let href = try requiredString(hrefValue, limit: Limits.hrefOrTitleUTF16)
        if let type = object["type"] {
            _ = try requiredString(type, limit: Limits.stringUTF16)
        }
        if let title = object["title"] {
            _ = try requiredString(title, limit: Limits.hrefOrTitleUTF16)
        }
        if let locations = object["locations"] {
            try validateLocations(locations)
        }
        if let text = object["text"] {
            try validateText(text)
        }

        return EPUBLocatorCommandPayload(href: href, locator: value)
    }

    private static func validateLocations(_ value: JSONValue) throws {
        guard let object = value.object else {
            throw EPUBLocatorCommandRejection.invalidField
        }
        try requireOnlyKeys(
            object,
            allowed: ["fragments", "progression", "totalProgression", "position", "cssSelector", "domRange"]
        )

        if let fragments = object["fragments"] {
            guard let values = fragments.array else {
                throw EPUBLocatorCommandRejection.invalidField
            }
            for value in values {
                _ = try requiredString(value, limit: Limits.stringUTF16)
            }
        }
        if let progression = object["progression"] {
            try validateProgression(progression)
        }
        if let totalProgression = object["totalProgression"] {
            try validateProgression(totalProgression)
        }
        if let position = object["position"] {
            try validateNonnegativeInteger(position)
        }
        if let selector = object["cssSelector"] {
            _ = try requiredString(selector, limit: Limits.selectorUTF16, rejection: .selectorTooLong)
        }
        if let domRange = object["domRange"] {
            try validateDOMRange(domRange)
        }
    }

    private static func validateText(_ value: JSONValue) throws {
        guard let object = value.object else {
            throw EPUBLocatorCommandRejection.invalidField
        }
        try requireOnlyKeys(object, allowed: ["before", "highlight", "after"])
        if let before = object["before"] {
            _ = try requiredString(before, limit: Limits.quoteContextUTF16, rejection: .quoteContextTooLong)
        }
        if let highlight = object["highlight"] {
            _ = try requiredString(highlight, limit: Limits.highlightUTF16, rejection: .highlightTooLong)
        }
        if let after = object["after"] {
            _ = try requiredString(after, limit: Limits.quoteContextUTF16, rejection: .quoteContextTooLong)
        }
    }

    private static func validateDOMRange(_ value: JSONValue) throws {
        guard let object = value.object else {
            throw EPUBLocatorCommandRejection.invalidDOMRange
        }
        try requireOnlyKeys(object, allowed: ["start", "end"])
        guard let start = object["start"], let end = object["end"] else {
            throw EPUBLocatorCommandRejection.invalidDOMRange
        }
        try validateDOMPoint(start)
        try validateDOMPoint(end)
    }

    private static func validateDOMPoint(_ value: JSONValue) throws {
        guard let object = value.object else {
            throw EPUBLocatorCommandRejection.invalidDOMRange
        }
        try requireOnlyKeys(object, allowed: ["cssSelector", "textNodeIndex", "charOffset"])
        guard let selector = object["cssSelector"], let textNodeIndex = object["textNodeIndex"] else {
            throw EPUBLocatorCommandRejection.invalidDOMRange
        }
        _ = try requiredString(selector, limit: Limits.selectorUTF16, rejection: .selectorTooLong)
        try validateNonnegativeInteger(textNodeIndex)
        if let charOffset = object["charOffset"] {
            try validateNonnegativeInteger(charOffset)
        }
    }

    private static func validateProgression(_ value: JSONValue) throws {
        guard let number = value.double, number.isFinite, 0 ... 1 ~= number else {
            throw EPUBLocatorCommandRejection.invalidNumber
        }
    }

    private static func validateNonnegativeInteger(_ value: JSONValue) throws {
        guard let integer = value.integer, integer >= 0 else {
            throw EPUBLocatorCommandRejection.invalidInteger
        }
    }

    private static func requiredString(
        _ value: JSONValue,
        limit: Int,
        rejection: EPUBLocatorCommandRejection = .stringTooLong
    ) throws -> String {
        guard let string = value.string else {
            throw EPUBLocatorCommandRejection.invalidField
        }
        guard string.utf16.count <= limit else {
            throw rejection
        }
        return string
    }

    private static func requireOnlyKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
        guard object.keys.allSatisfy(allowed.contains) else {
            throw EPUBLocatorCommandRejection.unknownField
        }
    }
}

private struct StrictJSONShapeScanner {
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0

    init(bytes: [UInt8], maximumDepth: Int) {
        self.bytes = bytes
        self.maximumDepth = maximumDepth
    }

    mutating func scan() throws {
        skipWhitespace()
        try scanValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw EPUBLocatorCommandRejection.malformed
        }
    }

    private mutating func scanValue(depth: Int) throws {
        guard let byte = current else {
            throw EPUBLocatorCommandRejection.malformed
        }
        switch byte {
        case 0x7B:
            try scanObject(depth: depth + 1)
        case 0x5B:
            try scanArray(depth: depth + 1)
        case 0x22:
            _ = try scanString()
        case 0x74:
            try consumeLiteral("true")
        case 0x66:
            try consumeLiteral("false")
        case 0x6E:
            try consumeLiteral("null")
        default:
            try scanNumber()
        }
    }

    private mutating func scanObject(depth: Int) throws {
        try validate(depth: depth)
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) {
            return
        }

        var keys: Set<String> = []
        while true {
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw EPUBLocatorCommandRejection.duplicateField
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            try scanValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func scanArray(depth: Int) throws {
        try validate(depth: depth)
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) {
            return
        }

        while true {
            try scanValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        try consume(0x22)
        var escaped = false
        while let byte = current {
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let data = Data(bytes[start ..< index])
                guard let string = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
                    throw EPUBLocatorCommandRejection.malformed
                }
                return string
            }
        }
        throw EPUBLocatorCommandRejection.malformed
    }

    private mutating func scanNumber() throws {
        let start = index
        while let byte = current, !Self.valueDelimiters.contains(byte) {
            index += 1
        }
        guard index > start else {
            throw EPUBLocatorCommandRejection.malformed
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for expected in literal.utf8 {
            try consume(expected)
        }
    }

    private mutating func validate(depth: Int) throws {
        guard depth <= maximumDepth else {
            throw EPUBLocatorCommandRejection.nestingTooDeep
        }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard current == expected else {
            throw EPUBLocatorCommandRejection.malformed
        }
        index += 1
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard current == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = current, Self.whitespace.contains(byte) {
            index += 1
        }
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    private static let valueDelimiters: Set<UInt8> = whitespace.union([0x2C, 0x5D, 0x7D])
}
