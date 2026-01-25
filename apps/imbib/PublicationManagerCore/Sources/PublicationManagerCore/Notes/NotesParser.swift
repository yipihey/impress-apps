//
//  NotesParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation

// MARK: - Parsed Notes

/// Represents parsed notes with quick annotations and freeform content.
public struct ParsedNotes: Equatable, Sendable {
    /// Quick annotation values keyed by field ID
    public var annotations: [String: String]

    /// Freeform markdown notes
    public var freeform: String

    public init(annotations: [String: String] = [:], freeform: String = "") {
        self.annotations = annotations
        self.freeform = freeform
    }

    /// Check if notes are empty
    public var isEmpty: Bool {
        annotations.values.allSatisfy(\.isEmpty) && freeform.isEmpty
    }
}

// MARK: - Notes Parser

/// Parses and serializes notes with YAML front matter for quick annotations.
///
/// Format:
/// ```
/// ---
/// First Author: Pioneer in this field
/// Key Collaborators: Strong team from MIT
/// ---
///
/// Freeform notes here...
/// ```
public enum NotesParser {

    // MARK: - Parsing

    /// Parse notes string into structured format.
    /// - Parameter text: Raw notes text (may include YAML front matter)
    /// - Returns: Parsed notes with annotations and freeform content
    public static func parse(_ text: String) -> ParsedNotes {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for YAML front matter
        guard trimmed.hasPrefix("---") else {
            // No front matter, everything is freeform
            return ParsedNotes(annotations: [:], freeform: text)
        }

        // Find the closing ---
        let lines = trimmed.components(separatedBy: .newlines)
        var endIndex: Int?

        for (index, line) in lines.enumerated() {
            if index > 0 && line.trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }

        guard let end = endIndex else {
            // Malformed front matter, treat as freeform
            return ParsedNotes(annotations: [:], freeform: text)
        }

        // Parse YAML section (lines 1 to end-1, skipping the opening ---)
        var annotations: [String: String] = [:]
        for i in 1..<end {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    annotations[key] = value
                }
            }
        }

        // Everything after the closing --- is freeform
        let freeformLines = Array(lines[(end + 1)...])
        let freeform = freeformLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedNotes(annotations: annotations, freeform: freeform)
    }

    // MARK: - Serialization

    /// Serialize parsed notes back to string with YAML front matter.
    /// - Parameters:
    ///   - notes: The parsed notes to serialize
    ///   - fields: The quick annotation field definitions (for ordering and labels)
    /// - Returns: Serialized notes string
    public static func serialize(_ notes: ParsedNotes, fields: [QuickAnnotationField]) -> String {
        var result = ""

        // Only add front matter if there are non-empty annotations
        let nonEmptyAnnotations = notes.annotations.filter { !$0.value.isEmpty }

        if !nonEmptyAnnotations.isEmpty {
            result += "---\n"

            // Output in field order, using labels as keys
            for field in fields where field.isEnabled {
                if let value = notes.annotations[field.id], !value.isEmpty {
                    // Escape colons and newlines in values
                    let escapedValue = escapeYAMLValue(value)
                    result += "\(field.label): \(escapedValue)\n"
                }
            }

            // Also output any custom annotations not in the field list
            let fieldIDs = Set(fields.map(\.id))
            for (key, value) in nonEmptyAnnotations where !fieldIDs.contains(key) {
                let escapedValue = escapeYAMLValue(value)
                result += "\(key): \(escapedValue)\n"
            }

            result += "---\n\n"
        }

        result += notes.freeform

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Serialize with default field definitions
    public static func serialize(_ notes: ParsedNotes) -> String {
        serialize(notes, fields: QuickAnnotationSettings.defaults.fields)
    }

    // MARK: - Helpers

    /// Escape special characters in YAML values
    private static func escapeYAMLValue(_ value: String) -> String {
        // If value contains newlines, colons, or special chars, quote it
        if value.contains("\n") || value.contains(":") || value.hasPrefix("\"") {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Migration

    /// Migrate from old format (separate JSON + note fields) to new unified format.
    /// - Parameters:
    ///   - structuredJSON: The old notes_structured JSON string
    ///   - freeformNote: The old note field value
    /// - Returns: Unified notes string with YAML front matter
    public static func migrateFromLegacy(structuredJSON: String?, freeformNote: String?) -> String {
        var annotations: [String: String] = [:]

        // Parse old JSON format
        if let json = structuredJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            annotations = dict
        }

        let notes = ParsedNotes(annotations: annotations, freeform: freeformNote ?? "")
        return serialize(notes)
    }
}
