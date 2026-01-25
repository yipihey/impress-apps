//
//  BibTeXParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - BibTeX Parser

/// Parses BibTeX content into structured entries.
///
/// Supports:
/// - All standard entry types (@article, @book, @inproceedings, etc.)
/// - String macros (@string{...})
/// - Nested braces in field values
/// - Quoted field values
/// - String concatenation with #
/// - Crossref inheritance
/// - LaTeX character decoding
public struct BibTeXParser: Sendable {

    // MARK: - Properties

    private let expandMacros: Bool
    private let resolveCrossrefs: Bool
    private let decodeLaTeX: Bool

    // MARK: - Built-in Macros

    private static let monthMacros: [String: String] = [
        "jan": "January", "feb": "February", "mar": "March",
        "apr": "April", "may": "May", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September",
        "oct": "October", "nov": "November", "dec": "December"
    ]

    // MARK: - Initialization

    public init(
        expandMacros: Bool = true,
        resolveCrossrefs: Bool = true,
        decodeLaTeX: Bool = true
    ) {
        self.expandMacros = expandMacros
        self.resolveCrossrefs = resolveCrossrefs
        self.decodeLaTeX = decodeLaTeX
    }

    // MARK: - Public API

    /// Parse BibTeX content into items (entries, macros, preambles, comments)
    public func parse(_ content: String) throws -> [BibTeXItem] {
        Logger.bibtex.entering()
        defer { Logger.bibtex.exiting() }

        var scanner = BibTeXScanner(content)
        var items: [BibTeXItem] = []
        var macros: [String: String] = Self.monthMacros

        while !scanner.isAtEnd {
            scanner.skipWhitespaceAndComments()

            guard scanner.peek() == "@" else {
                scanner.advance()
                continue
            }

            let startIndex = scanner.currentIndex

            do {
                let item = try parseItem(&scanner, macros: &macros, startIndex: startIndex, content: content)
                items.append(item)
            } catch let error as BibTeXError {
                Logger.bibtex.warning("Parse error: \(error.localizedDescription)")
                throw error
            }
        }

        // Post-process
        var entries = items.compactMap { item -> BibTeXEntry? in
            if case .entry(let entry) = item { return entry }
            return nil
        }

        if resolveCrossrefs {
            entries = resolveCrossrefInheritance(entries)
        }

        // Replace entries in items array
        var result: [BibTeXItem] = []
        var entryIndex = 0
        for item in items {
            if case .entry = item {
                result.append(.entry(entries[entryIndex]))
                entryIndex += 1
            } else {
                result.append(item)
            }
        }

        Logger.bibtex.info("Parsed \(result.count) items (\(entries.count) entries)")
        return result
    }

    /// Parse and return only entries
    public func parseEntries(_ content: String) throws -> [BibTeXEntry] {
        try parse(content).compactMap { item in
            if case .entry(let entry) = item { return entry }
            return nil
        }
    }

    /// Parse a single entry from string
    public func parseEntry(_ content: String) throws -> BibTeXEntry {
        let entries = try parseEntries(content)
        guard let entry = entries.first else {
            throw BibTeXError.parseError(line: 1, message: "No entry found")
        }
        return entry
    }

    // MARK: - Item Parsing

    private func parseItem(
        _ scanner: inout BibTeXScanner,
        macros: inout [String: String],
        startIndex: String.Index,
        content: String
    ) throws -> BibTeXItem {

        guard scanner.consume("@") else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '@'")
        }

        let entryType = scanner.scanIdentifier().lowercased()

        switch entryType {
        case "string":
            let (name, value) = try parseStringMacro(&scanner, macros: macros)
            if expandMacros {
                macros[name.lowercased()] = value
            }
            return .stringMacro(name: name, value: value)

        case "preamble":
            let value = try parsePreamble(&scanner, macros: macros)
            return .preamble(value)

        case "comment":
            let value = try parseComment(&scanner)
            return .comment(value)

        default:
            let entry = try parseEntry(&scanner, entryType: entryType, macros: macros, startIndex: startIndex, content: content)
            return .entry(entry)
        }
    }

    // MARK: - Entry Parsing

    private func parseEntry(
        _ scanner: inout BibTeXScanner,
        entryType: String,
        macros: [String: String],
        startIndex: String.Index,
        content: String
    ) throws -> BibTeXEntry {

        scanner.skipWhitespace()

        let openBrace = scanner.peek()
        guard openBrace == "{" || openBrace == "(" else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '{' or '('")
        }
        let closeBrace: Character = openBrace == "{" ? "}" : ")"
        scanner.advance()

        scanner.skipWhitespace()

        // Parse cite key
        let citeKey = scanner.scanCiteKey()
        guard !citeKey.isEmpty else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected cite key")
        }

        scanner.skipWhitespace()
        guard scanner.consume(",") else {
            // Entry with no fields
            scanner.skipWhitespace()
            guard scanner.consume(closeBrace) else {
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected ',' or '\(closeBrace)'")
            }
            let rawBibTeX = String(content[startIndex..<scanner.currentIndex])
            return BibTeXEntry(citeKey: citeKey, entryType: entryType, rawBibTeX: rawBibTeX)
        }

        // Parse fields
        var fields: [String: String] = [:]

        while true {
            scanner.skipWhitespace()

            if scanner.peek() == closeBrace {
                scanner.advance()
                break
            }

            // Parse field name
            let fieldName = scanner.scanIdentifier().lowercased()
            if fieldName.isEmpty {
                if scanner.peek() == closeBrace {
                    scanner.advance()
                    break
                }
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected field name")
            }

            scanner.skipWhitespace()
            guard scanner.consume("=") else {
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '=' after field name '\(fieldName)'")
            }

            scanner.skipWhitespace()

            // Parse field value (may have concatenation)
            let value = try parseFieldValue(&scanner, macros: macros)
            fields[fieldName] = value

            scanner.skipWhitespace()

            // Consume comma if present
            if scanner.peek() == "," {
                scanner.advance()
            }
        }

        let rawBibTeX = String(content[startIndex..<scanner.currentIndex])

        return BibTeXEntry(
            citeKey: citeKey,
            entryType: entryType,
            fields: fields,
            rawBibTeX: rawBibTeX
        )
    }

    // MARK: - Field Value Parsing

    private func parseFieldValue(_ scanner: inout BibTeXScanner, macros: [String: String]) throws -> String {
        var parts: [String] = []

        while true {
            scanner.skipWhitespace()

            guard let char = scanner.peek() else {
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Unexpected end of input in field value")
            }

            var part: String

            if char == "{" {
                part = try parseBracedValue(&scanner)
            } else if char == "\"" {
                part = try parseQuotedValue(&scanner)
            } else if char.isNumber {
                part = scanner.scanNumber()
            } else if char.isLetter {
                let identifier = scanner.scanIdentifier()
                // Look up macro
                if expandMacros, let expanded = macros[identifier.lowercased()] {
                    part = expanded
                } else {
                    part = identifier
                }
            } else {
                break
            }

            if decodeLaTeX {
                part = LaTeXDecoder.decode(part)
            }
            parts.append(part)

            scanner.skipWhitespace()

            // Check for concatenation
            if scanner.peek() == "#" {
                scanner.advance()
            } else {
                break
            }
        }

        return parts.joined()
    }

    private func parseBracedValue(_ scanner: inout BibTeXScanner) throws -> String {
        guard scanner.consume("{") else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '{'")
        }

        var result = ""
        var depth = 1

        while depth > 0 {
            guard let char = scanner.peek() else {
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Unclosed brace in field value")
            }

            if char == "{" {
                depth += 1
                result.append(char)
                scanner.advance()
            } else if char == "}" {
                depth -= 1
                if depth > 0 {
                    result.append(char)
                }
                scanner.advance()
            } else if char == "\\" {
                // Escape sequence - handle \{ \} and \\{ \\} robustly
                result.append(char)
                scanner.advance()
                if let next = scanner.peek() {
                    result.append(next)
                    scanner.advance()
                    // Handle \\{ and \\} - many BibTeX files use double backslash
                    // before braces when they mean escaped braces. Treat the
                    // following brace as non-structural for robustness.
                    if next == "\\" {
                        if let afterBackslash = scanner.peek(), afterBackslash == "{" || afterBackslash == "}" {
                            result.append(afterBackslash)
                            scanner.advance()
                        }
                    }
                }
            } else {
                result.append(char)
                scanner.advance()
            }
        }

        return result
    }

    private func parseQuotedValue(_ scanner: inout BibTeXScanner) throws -> String {
        guard scanner.consume("\"") else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '\"'")
        }

        var result = ""
        var depth = 0  // Track nested braces within quotes

        while true {
            guard let char = scanner.peek() else {
                throw BibTeXError.parseError(line: scanner.currentLine, message: "Unclosed quote in field value")
            }

            if char == "{" {
                depth += 1
                result.append(char)
                scanner.advance()
            } else if char == "}" {
                depth -= 1
                result.append(char)
                scanner.advance()
            } else if char == "\"" && depth == 0 {
                scanner.advance()
                break
            } else if char == "\\" {
                result.append(char)
                scanner.advance()
                if let next = scanner.peek() {
                    result.append(next)
                    scanner.advance()
                    // Handle \\{ and \\} robustly (see parseBracedValue)
                    if next == "\\" {
                        if let afterBackslash = scanner.peek(), afterBackslash == "{" || afterBackslash == "}" {
                            result.append(afterBackslash)
                            scanner.advance()
                        }
                    }
                }
            } else {
                result.append(char)
                scanner.advance()
            }
        }

        return result
    }

    // MARK: - String Macro Parsing

    private func parseStringMacro(_ scanner: inout BibTeXScanner, macros: [String: String]) throws -> (String, String) {
        scanner.skipWhitespace()

        let openBrace = scanner.peek()
        guard openBrace == "{" || openBrace == "(" else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '{' or '(' after @string")
        }
        let closeBrace: Character = openBrace == "{" ? "}" : ")"
        scanner.advance()

        scanner.skipWhitespace()

        let name = scanner.scanIdentifier()
        guard !name.isEmpty else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected macro name")
        }

        scanner.skipWhitespace()
        guard scanner.consume("=") else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '=' in @string")
        }

        scanner.skipWhitespace()
        let value = try parseFieldValue(&scanner, macros: macros)

        scanner.skipWhitespace()
        guard scanner.consume(closeBrace) else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '\(closeBrace)' to close @string")
        }

        return (name, value)
    }

    // MARK: - Preamble Parsing

    private func parsePreamble(_ scanner: inout BibTeXScanner, macros: [String: String]) throws -> String {
        scanner.skipWhitespace()

        let openBrace = scanner.peek()
        guard openBrace == "{" || openBrace == "(" else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '{' or '(' after @preamble")
        }
        let closeBrace: Character = openBrace == "{" ? "}" : ")"
        scanner.advance()

        scanner.skipWhitespace()
        let value = try parseFieldValue(&scanner, macros: macros)

        scanner.skipWhitespace()
        guard scanner.consume(closeBrace) else {
            throw BibTeXError.parseError(line: scanner.currentLine, message: "Expected '\(closeBrace)' to close @preamble")
        }

        return value
    }

    // MARK: - Comment Parsing

    private func parseComment(_ scanner: inout BibTeXScanner) throws -> String {
        scanner.skipWhitespace()

        guard scanner.peek() == "{" else {
            // @comment without braces - skip to end of line
            return scanner.scanToEndOfLine()
        }

        return try parseBracedValue(&scanner)
    }

    // MARK: - Crossref Resolution

    private func resolveCrossrefInheritance(_ entries: [BibTeXEntry]) -> [BibTeXEntry] {
        // Build lookup by cite key
        var lookup: [String: BibTeXEntry] = [:]
        for entry in entries {
            lookup[entry.citeKey.lowercased()] = entry
        }

        return entries.map { entry in
            guard let crossref = entry.fields["crossref"],
                  let parent = lookup[crossref.lowercased()] else {
                return entry
            }

            var inheritedFields = parent.fields
            // Child fields override parent
            for (key, value) in entry.fields {
                inheritedFields[key] = value
            }

            return BibTeXEntry(
                citeKey: entry.citeKey,
                entryType: entry.entryType,
                fields: inheritedFields,
                rawBibTeX: entry.rawBibTeX
            )
        }
    }
}

// MARK: - BibTeX Scanner

/// Low-level scanner for BibTeX content
private struct BibTeXScanner {
    let content: String
    var currentIndex: String.Index
    var currentLine: Int = 1

    init(_ content: String) {
        self.content = content
        self.currentIndex = content.startIndex
    }

    var isAtEnd: Bool {
        currentIndex >= content.endIndex
    }

    func peek() -> Character? {
        guard currentIndex < content.endIndex else { return nil }
        return content[currentIndex]
    }

    mutating func advance() {
        guard currentIndex < content.endIndex else { return }
        if content[currentIndex] == "\n" {
            currentLine += 1
        }
        currentIndex = content.index(after: currentIndex)
    }

    mutating func consume(_ char: Character) -> Bool {
        if peek() == char {
            advance()
            return true
        }
        return false
    }

    mutating func consume(_ string: String) -> Bool {
        let remaining = content[currentIndex...]
        if remaining.hasPrefix(string) {
            for _ in string {
                advance()
            }
            return true
        }
        return false
    }

    mutating func skipWhitespace() {
        while let char = peek(), char.isWhitespace {
            advance()
        }
    }

    mutating func skipWhitespaceAndComments() {
        while true {
            skipWhitespace()

            // Skip line comments (% to end of line, but not inside entries)
            if peek() == "%" {
                _ = scanToEndOfLine()
                continue
            }

            break
        }
    }

    mutating func scanIdentifier() -> String {
        var result = ""
        while let char = peek(), char.isLetter || char.isNumber || char == "_" || char == "-" || char == ":" || char == "." {
            result.append(char)
            advance()
        }
        return result
    }

    mutating func scanCiteKey() -> String {
        var result = ""
        while let char = peek() {
            // Cite keys can contain many characters but not: { } , = # " \ whitespace
            if char == "," || char == "}" || char == ")" || char == "=" || char.isWhitespace {
                break
            }
            result.append(char)
            advance()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    mutating func scanNumber() -> String {
        var result = ""
        while let char = peek(), char.isNumber {
            result.append(char)
            advance()
        }
        return result
    }

    mutating func scanToEndOfLine() -> String {
        var result = ""
        while let char = peek(), char != "\n" {
            result.append(char)
            advance()
        }
        if peek() == "\n" {
            advance()
        }
        return result
    }
}
