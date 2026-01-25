//
//  BibTeXTypes.swift
//  PublicationManagerCore
//

import Foundation

// MARK: - BibTeX Entry

/// A complete BibTeX bibliographic entry.
public struct BibTeXEntry: Sendable, Equatable, Identifiable, Codable {

    public var id: String { citeKey }

    /// The citation key (e.g., "Einstein1905")
    public var citeKey: String

    /// The entry type (e.g., "article", "book")
    public var entryType: String

    /// The fields as string key-value pairs
    public var fields: [String: String]

    /// Original raw BibTeX for round-trip preservation
    public var rawBibTeX: String?

    public init(
        citeKey: String,
        entryType: String,
        fields: [String: String] = [:],
        rawBibTeX: String? = nil
    ) {
        self.citeKey = citeKey
        self.entryType = entryType.lowercased()
        self.fields = fields
        self.rawBibTeX = rawBibTeX
    }
}

// MARK: - Field Access

public extension BibTeXEntry {

    /// Get a field value (case-insensitive key lookup)
    subscript(field: String) -> String? {
        get { fields[field.lowercased()] }
        set { fields[field.lowercased()] = newValue }
    }

    var title: String? {
        guard let raw = self["title"] else { return nil }
        return BibTeXFieldCleaner.stripOuterBraces(raw)
    }

    var author: String? { self["author"] }
    var year: String? { self["year"] }
    var journal: String? { self["journal"] }
    var booktitle: String? { self["booktitle"] }
    var doi: String? { self["doi"] }
    var url: String? { self["url"] }
    var abstract: String? { self["abstract"] }

    /// Parse year as integer
    var yearInt: Int? {
        guard let yearStr = year else { return nil }
        return Int(yearStr)
    }

    /// Parse authors into array, with braces stripped from names
    var authorList: [String] {
        guard let author = author else { return [] }
        return author
            .components(separatedBy: " and ")
            .map { BibTeXFieldCleaner.cleanAuthorName($0) }
    }

    /// First author's last name
    var firstAuthorLastName: String? {
        guard let first = authorList.first else { return nil }
        if first.contains(",") {
            return first.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
        }
        return first.components(separatedBy: " ").last
    }
}

// MARK: - BibTeX Field Cleaner

/// Utilities for cleaning BibTeX field values
public enum BibTeXFieldCleaner {

    /// Strip outer protective braces from a field value
    /// e.g., "{Some Title}" → "Some Title"
    public static func stripOuterBraces(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)

        // Keep stripping outer braces while they're balanced
        while result.hasPrefix("{") && result.hasSuffix("}") && isBalancedBraces(result) {
            result = String(result.dropFirst().dropLast())
            result = result.trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    /// Clean an author name by stripping protective braces
    /// e.g., "{Kim}, Eun-Jin" → "Kim, Eun-Jin"
    /// e.g., "{{Collaboration}}" → "Collaboration"
    public static func cleanAuthorName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces)

        // First strip fully-wrapped names like {{Collaboration}}
        result = stripOuterBraces(result)

        // Then handle partial braces like "{Kim}, Eun-Jin"
        // Replace {word} patterns with just word
        result = stripInlineBraces(result)

        return result
    }

    /// Strip inline braces that protect individual words
    /// e.g., "{Kim}, Eun-Jin" → "Kim, Eun-Jin"
    public static func stripInlineBraces(_ value: String) -> String {
        var result = ""
        var i = value.startIndex

        while i < value.endIndex {
            let char = value[i]

            if char == "{" {
                // Find matching close brace
                var depth = 1
                var j = value.index(after: i)
                var content = ""

                while j < value.endIndex && depth > 0 {
                    let c = value[j]
                    if c == "{" {
                        depth += 1
                        content.append(c)
                    } else if c == "}" {
                        depth -= 1
                        if depth > 0 {
                            content.append(c)
                        }
                    } else {
                        content.append(c)
                    }
                    j = value.index(after: j)
                }

                result.append(content)
                i = j
            } else {
                result.append(char)
                i = value.index(after: i)
            }
        }

        return result
    }

    /// Check if a string has balanced outer braces
    private static func isBalancedBraces(_ value: String) -> Bool {
        guard value.hasPrefix("{") && value.hasSuffix("}") else {
            return false
        }

        // Check that the outer braces match (not two separate pairs)
        var depth = 0
        for (index, char) in value.enumerated() {
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
            }

            // If depth hits 0 before the end, outer braces don't match
            if depth == 0 && index < value.count - 1 {
                return false
            }
        }

        return depth == 0
    }
}

// MARK: - Standard Entry Types

public extension BibTeXEntry {

    static let standardTypes: Set<String> = [
        "article", "book", "booklet", "conference", "inbook",
        "incollection", "inproceedings", "manual", "mastersthesis",
        "misc", "phdthesis", "proceedings", "techreport", "unpublished"
    ]

    var isStandardType: Bool {
        Self.standardTypes.contains(entryType)
    }
}

// MARK: - BibTeX Item (for parsing)

/// Top-level items in a BibTeX file
public enum BibTeXItem: Sendable, Equatable {
    case entry(BibTeXEntry)
    case stringMacro(name: String, value: String)
    case preamble(String)
    case comment(String)
}
