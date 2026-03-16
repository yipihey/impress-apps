//
//  StructuralScopeAnalyzer.swift
//  imprint
//
//  Computes hierarchical structural scopes (word, sentence, paragraph, section,
//  chapter, document) from Typst or LaTeX source at a given cursor position.
//

import Foundation
import AppKit

// MARK: - Scope Level

/// The granularity levels of text scope, ordered from finest to coarsest.
public enum ScopeLevel: Int, CaseIterable, Comparable, CustomStringConvertible {
    case word = 0
    case sentence = 1
    case paragraph = 2
    case subsection = 3
    case section = 4
    case chapter = 5
    case document = 6

    public static func < (lhs: ScopeLevel, rhs: ScopeLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Human-readable display name.
    public var description: String {
        switch self {
        case .word:        return "word"
        case .sentence:    return "sentence"
        case .paragraph:   return "paragraph"
        case .subsection:  return "subsection"
        case .section:     return "section"
        case .chapter:     return "chapter"
        case .document:    return "document"
        }
    }

    /// The next coarser scope level, if any.
    public var expanded: ScopeLevel? {
        let next = rawValue + 1
        return ScopeLevel(rawValue: next)
    }

    /// The next finer scope level, if any.
    public var shrunk: ScopeLevel? {
        let prev = rawValue - 1
        return ScopeLevel(rawValue: prev)
    }

    /// SF Symbol for representing this scope level.
    public var icon: String {
        switch self {
        case .word:        return "character.cursor.ibeam"
        case .sentence:    return "text.cursor"
        case .paragraph:   return "paragraph"
        case .subsection:  return "list.bullet.indent"
        case .section:     return "doc.text"
        case .chapter:     return "book.pages"
        case .document:    return "doc.richtext"
        }
    }
}

// MARK: - Text Scope

/// A resolved scope: a level plus its range in the source document.
public struct TextScope: Equatable {
    /// The granularity level.
    public let level: ScopeLevel

    /// The byte range in the source document.
    public let range: NSRange

    /// For section-level scopes, the heading text; nil for word/sentence/paragraph.
    public let label: String?

    public init(level: ScopeLevel, range: NSRange, label: String? = nil) {
        self.level = level
        self.range = range
        self.label = label
    }
}

// MARK: - Structural Scope Analyzer

/// Computes the scope tree at a cursor position in Typst or LaTeX source.
///
/// Returns all scopes that contain the cursor, from finest (word) to coarsest (document).
/// Each scope's `range` covers the full extent of that structural unit.
///
/// Typst heading convention: `= Title` (chapter), `== Title` (section), `=== Title` (subsection)
/// LaTeX heading convention: `\chapter{...}`, `\section{...}`, `\subsection{...}`
public actor StructuralScopeAnalyzer {

    public static let shared = StructuralScopeAnalyzer()

    private init() {}

    // MARK: - Public API

    /// Compute all scopes containing `cursorPosition` in `source`.
    ///
    /// Returns an array ordered from finest (word) to coarsest (document),
    /// containing only scopes that are actually present in the source.
    ///
    /// - Parameters:
    ///   - source: The full document source text.
    ///   - cursorPosition: The cursor offset in `source`.
    ///   - format: `.typst` or `.latex`.
    /// - Returns: Scopes ordered finest → coarsest.
    public func scopes(
        in source: String,
        at cursorPosition: Int,
        format: DocumentFormat = .typst
    ) -> [TextScope] {
        var result: [TextScope] = []

        // Word scope
        if let wordScope = wordScope(in: source, at: cursorPosition) {
            result.append(wordScope)
        }

        // Sentence scope
        if let sentenceScope = sentenceScope(in: source, at: cursorPosition) {
            result.append(sentenceScope)
        }

        // Paragraph scope
        if let paraScope = paragraphScope(in: source, at: cursorPosition) {
            result.append(paraScope)
        }

        // Section scopes (subsection, section, chapter) from the AST
        let sectionScopes = structuralScopes(in: source, at: cursorPosition, format: format)
        result.append(contentsOf: sectionScopes)

        // Document scope (always present)
        result.append(TextScope(level: .document, range: NSRange(location: 0, length: source.utf16.count)))

        return result
    }

    /// Compute the range for a specific scope level at the cursor.
    public func scope(
        _ level: ScopeLevel,
        in source: String,
        at cursorPosition: Int,
        format: DocumentFormat = .typst
    ) -> TextScope? {
        scopes(in: source, at: cursorPosition, format: format).first { $0.level == level }
    }

    // MARK: - Word Scope

    private func wordScope(in source: String, at position: Int) -> TextScope? {
        guard !source.isEmpty, position <= source.count else { return nil }

        let nsSource = source as NSString
        let fullLength = nsSource.length
        guard position <= fullLength else { return nil }

        // Expand left to word boundary
        var start = position
        while start > 0 {
            let ch = nsSource.character(at: start - 1)
            if isWordChar(ch) {
                start -= 1
            } else {
                break
            }
        }

        // Expand right to word boundary
        var end = position
        while end < fullLength {
            let ch = nsSource.character(at: end)
            if isWordChar(ch) {
                end += 1
            } else {
                break
            }
        }

        let length = end - start
        guard length > 0 else { return nil }
        return TextScope(level: .word, range: NSRange(location: start, length: length))
    }

    private func isWordChar(_ ch: unichar) -> Bool {
        // Letters, digits, underscore, hyphen-minus (in compound words)
        let s = String(UnicodeScalar(ch)!)
        if s == "-" || s == "_" { return true }
        let cs = CharacterSet.alphanumerics
        return s.unicodeScalars.first.map { cs.contains($0) } ?? false
    }

    // MARK: - Sentence Scope

    /// Common abbreviations that end with a period but do NOT end a sentence.
    /// Checked as lowercased prefix before the period.
    private static let sentenceAbbreviations: Set<String> = [
        // Titles
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "rev", "gen", "sgt", "cpl", "pvt",
        // Academic
        "fig", "eq", "sec", "ch", "vol", "no", "pp", "ibid", "cf", "et al",
        // Latin / common
        "e.g", "i.e", "vs", "etc", "al", "approx",
        // Months / days (abbreviated)
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        "mon", "tue", "wed", "thu", "fri", "sat", "sun",
        // Units / misc
        "ave", "blvd", "st", "dept", "est",
    ]

    private func sentenceScope(in source: String, at position: Int) -> TextScope? {
        guard !source.isEmpty else { return nil }
        guard let posRange = Range(NSRange(location: position, length: 0), in: source) else { return nil }

        // Use paragraph boundaries as hard sentence containment.
        let beforeText = source[..<posRange.lowerBound]
        let afterText = source[posRange.lowerBound...]

        let paraStart: String.Index
        if let lb = beforeText.range(of: "\n\n", options: .backwards) {
            paraStart = lb.upperBound
        } else {
            paraStart = source.startIndex
        }

        let paraEnd: String.Index
        if let ub = afterText.range(of: "\n\n") {
            paraEnd = ub.lowerBound
        } else {
            paraEnd = source.endIndex
        }

        guard paraStart < paraEnd else { return nil }
        let paragraph = String(source[paraStart..<paraEnd])
        let paraOffset = source.distance(from: source.startIndex, to: paraStart)

        // Split paragraph into sentences using a regex that respects abbreviations.
        let sentences = splitIntoSentences(paragraph)

        // Find which sentence the cursor falls in (relative to paragraph).
        let relativeCursor = source.distance(from: source.startIndex, to: posRange.lowerBound) - paraOffset

        for sentence in sentences {
            let sentStart = sentence.start
            let sentEnd = sentence.end
            if sentStart <= relativeCursor && relativeCursor <= sentEnd {
                let absStart = paraOffset + sentStart
                let absEnd = paraOffset + sentEnd
                guard absEnd > absStart else { continue }
                return TextScope(
                    level: .sentence,
                    range: NSRange(location: absStart, length: absEnd - absStart)
                )
            }
        }

        return nil
    }

    private struct SentenceSpan {
        let start: Int   // byte offset within the paragraph
        let end: Int
    }

    /// Split text into sentence spans using a pattern that skips common abbreviations.
    private func splitIntoSentences(_ text: String) -> [SentenceSpan] {
        var spans: [SentenceSpan] = []

        // Pattern: a terminator (.!?) followed by a capital letter or closing quote + capital.
        // Uses a negative lookbehind-style check for abbreviations.
        // Strategy: find all candidate boundaries, filter abbreviations, build spans.
        let nsText = text as NSString
        let length = nsText.length

        var sentenceStart = 0

        var i = 0
        while i < length {
            let ch = UnicodeScalar(nsText.character(at: i))!
            let chStr = String(ch)

            if ".!?".contains(chStr) {
                // Look ahead: must be followed by space + uppercase (or end of text)
                let afterIdx = i + 1
                var j = afterIdx
                // Skip closing punctuation: )"'
                while j < length && ")\u{201D}\u{2019}'\"".contains(String(UnicodeScalar(nsText.character(at: j))!)) {
                    j += 1
                }
                // Need whitespace
                if j >= length {
                    // End of text — this is a sentence boundary
                    spans.append(SentenceSpan(start: sentenceStart, end: i + 1))
                    sentenceStart = i + 1
                } else if chStr == "." {
                    let nextCh = UnicodeScalar(nsText.character(at: j))!
                    if CharacterSet.whitespaces.contains(nextCh) {
                        // Check for abbreviation: get the word before the period
                        let wordBefore = wordBefore(in: text, before: i)
                        if !Self.sentenceAbbreviations.contains(wordBefore.lowercased()) &&
                           !isSingleUppercaseLetter(wordBefore) &&
                           !isNumeric(wordBefore) {
                            // Check next non-space char is uppercase (real sentence start)
                            var k = j
                            while k < length && CharacterSet.whitespaces.contains(UnicodeScalar(nsText.character(at: k))!) {
                                k += 1
                            }
                            if k < length {
                                let startCh = UnicodeScalar(nsText.character(at: k))!
                                if CharacterSet.uppercaseLetters.contains(startCh) {
                                    spans.append(SentenceSpan(start: sentenceStart, end: j))
                                    sentenceStart = k
                                }
                            }
                        }
                    }
                } else {
                    // ! or ? — these are almost always sentence-ending
                    let nextCh = UnicodeScalar(nsText.character(at: j))!
                    if CharacterSet.whitespaces.contains(nextCh) || CharacterSet.newlines.contains(nextCh) {
                        spans.append(SentenceSpan(start: sentenceStart, end: j))
                        var k = j
                        while k < length && CharacterSet.whitespaces.contains(UnicodeScalar(nsText.character(at: k))!) {
                            k += 1
                        }
                        sentenceStart = k
                    }
                }
            }
            i += 1
        }

        // Add the final sentence
        if sentenceStart < length {
            spans.append(SentenceSpan(start: sentenceStart, end: length))
        }

        return spans
    }

    /// Extract the word immediately before position `i` in the string (stops at whitespace/punct).
    private func wordBefore(in text: String, before i: Int) -> String {
        let nsText = text as NSString
        var j = i - 1
        while j >= 0 {
            let ch = UnicodeScalar(nsText.character(at: j))!
            if CharacterSet.letters.contains(ch) || ch == UnicodeScalar(".") {
                j -= 1
            } else {
                break
            }
        }
        let startJ = j + 1
        guard startJ < i else { return "" }
        return nsText.substring(with: NSRange(location: startJ, length: i - startJ))
    }

    private func isSingleUppercaseLetter(_ s: String) -> Bool {
        s.count == 1 && s.unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
    }

    private func isNumeric(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    // MARK: - Paragraph Scope

    private func paragraphScope(in source: String, at position: Int) -> TextScope? {
        guard !source.isEmpty else { return nil }
        guard let swiftRange = Range(NSRange(location: position, length: 0), in: source) else { return nil }

        // Paragraph boundaries are blank lines (\n\n)
        let beforeText = source[..<swiftRange.lowerBound]
        let afterText = source[swiftRange.lowerBound...]

        // Find paragraph start (after the last \n\n before position)
        let paragraphStart: String.Index
        if let lastDoubleNewline = beforeText.range(of: "\n\n", options: .backwards) {
            paragraphStart = lastDoubleNewline.upperBound
        } else {
            paragraphStart = source.startIndex
        }

        // Find paragraph end (before the next \n\n after position)
        let paragraphEnd: String.Index
        if let nextDoubleNewline = afterText.range(of: "\n\n") {
            paragraphEnd = nextDoubleNewline.lowerBound
        } else {
            paragraphEnd = source.endIndex
        }

        guard paragraphStart < paragraphEnd else { return nil }

        // Skip leading blank lines within paragraph
        var actualStart = paragraphStart
        while actualStart < paragraphEnd && (source[actualStart] == "\n" || source[actualStart] == " ") {
            actualStart = source.index(after: actualStart)
        }

        let nsRange = NSRange(actualStart..<paragraphEnd, in: source)
        guard nsRange.length > 0 else { return nil }
        return TextScope(level: .paragraph, range: nsRange)
    }

    // MARK: - Structural Scopes (Subsection / Section / Chapter)

    /// Returns section-level scopes containing the cursor, ordered subsection → section → chapter.
    private func structuralScopes(
        in source: String,
        at position: Int,
        format: DocumentFormat
    ) -> [TextScope] {
        let headings = parseHeadings(in: source, format: format)
        guard !headings.isEmpty else { return [] }

        let nsSource = source as NSString
        let fullLength = nsSource.length

        // For each heading level, find the heading that immediately precedes position
        // and determine its extent (up to the next heading at the same or higher level).

        // Typst: `=` = chapter, `==` = section, `===` = subsection
        // LaTeX: `\chapter` = chapter, `\section` = section, `\subsection` = subsection

        // headings is sorted by position ascending, each entry: (offset, level, labelText)
        // level: 1 = chapter, 2 = section, 3 = subsection

        var result: [TextScope] = []

        for targetDepth in [3, 2, 1] { // subsection, section, chapter
            guard let containingHeading = findContainingHeading(
                headings: headings, position: position, maxDepth: targetDepth
            ) else { continue }

            // Extent: from heading start to start of next heading at same or shallower depth
            let startOffset = containingHeading.offset
            var endOffset = fullLength
            for h in headings {
                if h.offset > containingHeading.offset && h.depth <= targetDepth {
                    endOffset = h.offset
                    break
                }
            }

            guard startOffset <= position && position <= endOffset else { continue }

            let scopeLevel: ScopeLevel
            switch targetDepth {
            case 1: scopeLevel = .chapter
            case 2: scopeLevel = .section
            case 3: scopeLevel = .subsection
            default: continue
            }

            let range = NSRange(location: startOffset, length: endOffset - startOffset)
            result.append(TextScope(level: scopeLevel, range: range, label: containingHeading.label))
        }

        return result
    }

    // MARK: - Heading Parsing

    private struct HeadingEntry {
        let offset: Int
        let depth: Int    // 1 = chapter, 2 = section, 3 = subsection
        let label: String
    }

    private func parseHeadings(in source: String, format: DocumentFormat) -> [HeadingEntry] {
        switch format {
        case .typst: return parseTypstHeadings(in: source)
        case .latex: return parseLaTeXHeadings(in: source)
        }
    }

    private func parseTypstHeadings(in source: String) -> [HeadingEntry] {
        // Typst headings: lines starting with = (1 =), == (2 =), === (3 =)
        var entries: [HeadingEntry] = []
        let lines = source.components(separatedBy: "\n")
        var offset = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: " \t"))
            if trimmed.hasPrefix("=") {
                // Count leading =
                var depth = 0
                for ch in trimmed {
                    if ch == "=" { depth += 1 }
                    else { break }
                }
                let label = trimmed.drop(while: { $0 == "=" || $0 == " " })
                entries.append(HeadingEntry(offset: offset, depth: depth, label: String(label)))
            }
            offset += line.count + 1 // +1 for newline
        }

        return entries
    }

    private func parseLaTeXHeadings(in source: String) -> [HeadingEntry] {
        var entries: [HeadingEntry] = []
        let patterns: [(String, Int)] = [
            ("\\\\chapter\\{([^}]+)\\}", 1),
            ("\\\\section\\{([^}]+)\\}", 2),
            ("\\\\subsection\\{([^}]+)\\}", 3),
            ("\\\\subsubsection\\{([^}]+)\\}", 4),
        ]

        for (pattern, depth) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match = match else { return }
                let label: String
                if match.numberOfRanges > 1, let labelRange = Range(match.range(at: 1), in: source) {
                    label = String(source[labelRange])
                } else {
                    label = ""
                }
                entries.append(HeadingEntry(offset: match.range.location, depth: depth, label: label))
            }
        }

        return entries.sorted { $0.offset < $1.offset }
    }

    private func findContainingHeading(
        headings: [HeadingEntry],
        position: Int,
        maxDepth: Int
    ) -> HeadingEntry? {
        // The last heading at depth <= maxDepth that starts before position
        var best: HeadingEntry?
        for h in headings {
            if h.offset <= position && h.depth <= maxDepth {
                best = h
            } else if h.offset > position {
                break
            }
        }
        return best
    }
}
