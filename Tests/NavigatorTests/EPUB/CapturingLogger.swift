//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
@testable import ReadiumShared

/// Captures everything the framework logs so a test can assert on it.
final class CapturingLogger: LoggerType {
    private let lock = NSLock()
    private var lines: [String] = []
    private var levels: [SeverityLevel] = []

    func log(level: SeverityLevel, value: Any?, file: String, line: Int) {
        let rendered = "\(level.rawValue) \(file):\(line): \(String(describing: value))"
        lock.lock()
        lines.append(rendered)
        levels.append(level)
        lock.unlock()
    }

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var capturedLevels: [SeverityLevel] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }
}
