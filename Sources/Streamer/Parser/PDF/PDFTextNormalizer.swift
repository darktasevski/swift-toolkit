//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

/// Normalizes raw PDF text by joining broken lines while preserving paragraph breaks.
///
/// PDF text extraction returns line breaks at column positions rather than at
/// semantic boundaries. Fed verbatim into the Content API, those hard breaks
/// fragment TTS utterances (the sentence tokenizer splits on every line) and
/// break phrase search across line boundaries. This normalizer:
/// 1. Joins lines that were broken due to column width.
/// 2. Preserves intentional paragraph breaks (blank lines).
/// 3. Rejoins hyphenated words split at line endings.
///
/// Applied at the content-iterator seam (see `NormalizingPDFContentIterator`),
/// it benefits every Content API consumer — TTS and search alike.
enum PDFTextNormalizer {
    /// Normalizes the given PDF text.
    /// - Parameter text: Raw text extracted from a PDF page.
    /// - Returns: Normalized text with column-broken lines rejoined and
    ///   paragraph breaks preserved.
    static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var currentParagraph: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Empty line = paragraph break
                if !currentParagraph.isEmpty {
                    result.append(joinLines(currentParagraph))
                    currentParagraph = []
                }
            } else {
                currentParagraph.append(trimmed)
            }
        }

        // Add final paragraph
        if !currentParagraph.isEmpty {
            result.append(joinLines(currentParagraph))
        }

        return result.joined(separator: "\n\n")
    }

    /// Joins lines intelligently, handling hyphenation and proper spacing.
    private static func joinLines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        guard lines.count > 1 else { return lines[0] }

        var result = ""

        for (index, line) in lines.enumerated() {
            if index == 0 {
                result = line
                continue
            }

            let previousLine = lines[index - 1]

            // Handle hyphenation: if previous line ends with hyphen, join without space
            if previousLine.hasSuffix("-") {
                // Remove the trailing hyphen and join directly
                result = String(result.dropLast()) + line
            } else {
                // Normal case: join with space
                result += " " + line
            }
        }

        return result
    }
}
