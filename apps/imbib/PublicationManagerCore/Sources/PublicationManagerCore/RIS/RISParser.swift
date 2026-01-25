//
//  RISParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - RIS Parser

/// Parser for RIS (Research Information Systems) format.
///
/// RIS format consists of tagged fields:
/// ```
/// TY  - JOUR
/// AU  - Smith, John
/// TI  - Article Title
/// PY  - 2024
/// ER  -
/// ```
public final class RISParser: Sendable {

    private static let logger = Logger(subsystem: "PublicationManagerCore", category: "RISParser")

    /// Regex pattern for RIS tag lines: `XX  - value`
    /// Two uppercase letters, two spaces, hyphen, space, then value
    private static let tagPattern = #"^([A-Z][A-Z0-9])\s{2}-\s(.*)$"#

    /// Regex pattern for end of record without value
    private static let endPattern = #"^ER\s{2}-\s*$"#

    public init() {}

    // MARK: - Public API

    /// Parse RIS content into entries.
    /// - Parameter content: RIS formatted string
    /// - Returns: Array of parsed RIS entries
    /// - Throws: RISError if parsing fails critically
    public func parse(_ content: String) throws -> [RISEntry] {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RISError.emptyContent
        }

        let lines = content.components(separatedBy: .newlines)
        var entries: [RISEntry] = []
        var currentTags: [RISTagValue] = []
        var currentType: RISReferenceType?
        var inEntry = false
        var currentValue: String?
        var currentTag: RISTag?
        var entryStartLine = 0
        var rawLines: [String] = []

        let tagRegex = try? NSRegularExpression(pattern: Self.tagPattern, options: [])
        let endRegex = try? NSRegularExpression(pattern: Self.endPattern, options: [])

        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines outside entries
            if trimmedLine.isEmpty && !inEntry {
                continue
            }

            // Check for end of record
            if let endRegex = endRegex,
               endRegex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) != nil {
                // Finalize any pending value
                if let tag = currentTag, let value = currentValue {
                    currentTags.append(RISTagValue(tag: tag, value: value.trimmingCharacters(in: .whitespaces)))
                }

                // Create entry if we have a type
                if let type = currentType {
                    rawLines.append(line)
                    let entry = RISEntry(
                        type: type,
                        tags: currentTags,
                        rawRIS: rawLines.joined(separator: "\n")
                    )
                    entries.append(entry)
                    Self.logger.debug("Parsed RIS entry: \(type.rawValue) with \(currentTags.count) tags")
                } else if !currentTags.isEmpty {
                    Self.logger.warning("RIS entry missing type tag at line \(entryStartLine)")
                }

                // Reset state
                currentTags = []
                currentType = nil
                currentTag = nil
                currentValue = nil
                inEntry = false
                rawLines = []
                continue
            }

            // Try to match a tag line
            if let tagRegex = tagRegex,
               let match = tagRegex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               match.numberOfRanges == 3 {

                let tagRange = Range(match.range(at: 1), in: line)!
                let valueRange = Range(match.range(at: 2), in: line)!
                let tagString = String(line[tagRange])
                let valueString = String(line[valueRange])

                // Finalize previous tag if exists
                if let tag = currentTag, let value = currentValue {
                    currentTags.append(RISTagValue(tag: tag, value: value.trimmingCharacters(in: .whitespaces)))
                }

                // Handle TY tag specially
                if tagString == "TY" {
                    if let type = RISReferenceType(rawValue: valueString.trimmingCharacters(in: .whitespaces)) {
                        currentType = type
                        inEntry = true
                        entryStartLine = lineIndex
                        rawLines = [line]
                    } else {
                        Self.logger.warning("Unknown RIS type: \(valueString)")
                        // Use GEN as fallback
                        currentType = .GEN
                        inEntry = true
                        entryStartLine = lineIndex
                        rawLines = [line]
                    }
                    currentTag = nil
                    currentValue = nil
                } else if let tag = RISTag.from(tagString) {
                    currentTag = tag
                    currentValue = valueString
                    if inEntry {
                        rawLines.append(line)
                    }
                } else {
                    // Unknown tag - store as custom if in entry, otherwise warn
                    Self.logger.debug("Unknown RIS tag: \(tagString)")
                    currentTag = nil
                    currentValue = nil
                    if inEntry {
                        rawLines.append(line)
                    }
                }
            } else if inEntry && !trimmedLine.isEmpty {
                // Continuation line for multi-line value
                if currentValue != nil {
                    currentValue! += "\n" + trimmedLine
                    rawLines.append(line)
                }
            } else if inEntry {
                // Empty line within entry - keep for raw preservation
                rawLines.append(line)
            }
        }

        // Handle case where file doesn't end with ER
        if inEntry {
            if let tag = currentTag, let value = currentValue {
                currentTags.append(RISTagValue(tag: tag, value: value.trimmingCharacters(in: .whitespaces)))
            }
            if let type = currentType {
                Self.logger.warning("RIS entry missing ER tag, creating entry anyway")
                let entry = RISEntry(
                    type: type,
                    tags: currentTags,
                    rawRIS: rawLines.joined(separator: "\n")
                )
                entries.append(entry)
            }
        }

        Self.logger.info("Parsed \(entries.count) RIS entries")
        return entries
    }

    /// Parse RIS content into items (entries and comments).
    /// - Parameter content: RIS formatted string
    /// - Returns: Array of parsed items
    public func parseItems(_ content: String) throws -> [RISItem] {
        let entries = try parse(content)
        return entries.map { .entry($0) }
    }

    /// Parse a single RIS entry from string.
    /// - Parameter content: RIS formatted string for a single entry
    /// - Returns: Parsed RIS entry
    /// - Throws: RISError if parsing fails
    public func parseEntry(_ content: String) throws -> RISEntry {
        let entries = try parse(content)
        guard let entry = entries.first else {
            throw RISError.parseError("No valid RIS entry found")
        }
        return entry
    }

    // MARK: - Validation

    /// Validate RIS content without fully parsing.
    /// - Parameter content: RIS formatted string
    /// - Returns: Array of validation errors (empty if valid)
    public func validate(_ content: String) -> [RISError] {
        var errors: [RISError] = []

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyContent)
            return errors
        }

        let lines = content.components(separatedBy: .newlines)
        var hasType = false
        var hasEnd = false
        var inEntry = false

        let tagPattern = #"^([A-Z][A-Z0-9])\s{2}-"#
        let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [])

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if let tagRegex = tagRegex,
               let match = tagRegex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               match.numberOfRanges >= 2 {

                let tagRange = Range(match.range(at: 1), in: line)!
                let tagString = String(line[tagRange])

                if tagString == "TY" {
                    if inEntry && !hasEnd {
                        errors.append(.missingEndTag)
                    }
                    hasType = true
                    hasEnd = false
                    inEntry = true
                } else if tagString == "ER" {
                    if !inEntry {
                        errors.append(.parseError("ER tag without TY"))
                    }
                    hasEnd = true
                    inEntry = false
                }
            }
        }

        if inEntry && !hasEnd {
            errors.append(.missingEndTag)
        }

        return errors
    }
}
