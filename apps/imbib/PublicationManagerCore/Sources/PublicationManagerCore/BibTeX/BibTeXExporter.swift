//
//  BibTeXExporter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - BibTeX Exporter

/// Exports BibTeX entries to formatted .bib file content.
public struct BibTeXExporter: Sendable {

    // MARK: - Configuration

    public struct Options: Sendable {
        /// Field ordering (fields listed first in order, then alphabetical)
        public var fieldOrder: [String]

        /// Whether to wrap long lines
        public var wrapLines: Bool

        /// Maximum line width for wrapping
        public var maxLineWidth: Int

        /// Indentation for fields
        public var indent: String

        /// Whether to use rawBibTeX when available
        public var preferRawBibTeX: Bool

        public init(
            fieldOrder: [String] = Self.defaultFieldOrder,
            wrapLines: Bool = false,
            maxLineWidth: Int = 80,
            indent: String = "    ",
            preferRawBibTeX: Bool = false
        ) {
            self.fieldOrder = fieldOrder
            self.wrapLines = wrapLines
            self.maxLineWidth = maxLineWidth
            self.indent = indent
            self.preferRawBibTeX = preferRawBibTeX
        }

        public static let defaultFieldOrder = [
            "author", "title", "journal", "booktitle",
            "year", "month", "volume", "number", "pages",
            "publisher", "address", "edition",
            "editor", "series", "chapter", "type",
            "school", "institution", "organization",
            "doi", "url", "eprint", "arxivid",
            "isbn", "issn", "pmid", "bibcode",
            "abstract", "keywords", "note",
        ]
    }

    private let options: Options

    // MARK: - Initialization

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Public API

    /// Export multiple entries to BibTeX string
    public func export(_ entries: [BibTeXEntry]) -> String {
        entries.map { export($0) }.joined(separator: "\n\n")
    }

    /// Export a single entry to BibTeX string
    public func export(_ entry: BibTeXEntry) -> String {
        // Use raw BibTeX if available and preferred
        if options.preferRawBibTeX, let raw = entry.rawBibTeX {
            return raw
        }

        var lines: [String] = []

        // Entry type and cite key
        lines.append("@\(entry.entryType){\(entry.citeKey),")

        // Sort fields
        let sortedFields = sortFields(entry.fields)

        for (index, (key, value)) in sortedFields.enumerated() {
            let isLast = index == sortedFields.count - 1
            let formattedValue = formatFieldValue(value, fieldName: key)
            let comma = isLast ? "" : ","
            lines.append("\(options.indent)\(key) = \(formattedValue)\(comma)")
        }

        lines.append("}")

        return lines.joined(separator: "\n")
    }

    /// Export items (entries + string macros + preambles)
    public func export(_ items: [BibTeXItem]) -> String {
        var parts: [String] = []

        for item in items {
            switch item {
            case .entry(let entry):
                parts.append(export(entry))
            case .stringMacro(let name, let value):
                parts.append("@string{\(name) = {\(value)}}")
            case .preamble(let value):
                parts.append("@preamble{\"\(value)\"}")
            case .comment(let value):
                parts.append("@comment{\(value)}")
            }
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Field Formatting

    private func sortFields(_ fields: [String: String]) -> [(String, String)] {
        let orderedSet = Set(options.fieldOrder.map { $0.lowercased() })
        var ordered: [(String, String)] = []
        var remaining: [(String, String)] = []

        // Add fields in specified order
        for fieldName in options.fieldOrder {
            if let value = fields[fieldName.lowercased()] {
                ordered.append((fieldName, value))
            }
        }

        // Add remaining fields alphabetically
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            if !orderedSet.contains(key.lowercased()) {
                remaining.append((key, value))
            }
        }

        return ordered + remaining
    }

    private func formatFieldValue(_ value: String, fieldName: String) -> String {
        // Numeric fields don't need braces
        let numericFields = Set(["year", "volume", "number", "pages"])
        if numericFields.contains(fieldName.lowercased()) {
            if let _ = Int(value) {
                return value
            }
        }

        // Check if value needs protection (contains special chars)
        let needsBraces = value.contains("{") || value.contains("}") ||
                          value.contains("\"") || value.contains("#") ||
                          value.contains(",")

        if needsBraces || shouldUseBraces(value) {
            return "{\(value)}"
        }

        return "{\(value)}"
    }

    private func shouldUseBraces(_ value: String) -> Bool {
        // Always use braces for safety
        true
    }

    // MARK: - Generate from PaperRepresentable

    /// Generate a BibTeX entry from any PaperRepresentable's metadata.
    /// Works with LocalPaper and CDPublication types.
    public static func generateEntry(from paper: any PaperRepresentable) -> BibTeXEntry {
        // Generate cite key: LastName + Year + FirstTitleWord
        let lastNamePart = paper.authors.first?
            .components(separatedBy: ",").first?
            .components(separatedBy: " ").last?
            .filter { $0.isLetter } ?? "Unknown"
        let yearPart = paper.year.map { String($0) } ?? ""
        let titleWord = paper.title
            .components(separatedBy: .whitespaces)
            .first { $0.count > 3 }?
            .filter { $0.isLetter }
            .capitalized ?? ""
        let citeKey = "\(lastNamePart)\(yearPart)\(titleWord)"

        // Determine entry type
        let entryType: String
        if paper.arxivID != nil {
            entryType = "article"
        } else if let venue = paper.venue?.lowercased() {
            if venue.contains("proceedings") || venue.contains("conference") {
                entryType = "inproceedings"
            } else {
                entryType = "article"
            }
        } else {
            entryType = "article"
        }

        // Build fields
        var fields: [String: String] = [:]
        fields["title"] = paper.title

        // Format authors as "Last, First and Last, First"
        if !paper.authors.isEmpty {
            fields["author"] = paper.authors.joined(separator: " and ")
        }

        if let year = paper.year {
            fields["year"] = String(year)
        }

        if let venue = paper.venue {
            if entryType == "inproceedings" {
                fields["booktitle"] = venue
            } else {
                fields["journal"] = venue
            }
        }

        if let abstract = paper.abstract {
            fields["abstract"] = abstract
        }

        if let doi = paper.doi {
            fields["doi"] = doi
        }

        if let arxivID = paper.arxivID {
            fields["eprint"] = arxivID
            fields["archiveprefix"] = "arXiv"
        }

        if let bibcode = paper.bibcode {
            fields["adsurl"] = "https://ui.adsabs.harvard.edu/abs/\(bibcode)"
        }

        // Store PDF links as bdsk-url-* fields (BibDesk compatible)
        for link in paper.pdfLinks {
            let fieldName = "bdsk-url-\(link.type.bdskUrlNumber)"
            fields[fieldName] = link.url.absoluteString
        }

        return BibTeXEntry(citeKey: citeKey, entryType: entryType, fields: fields)
    }
}

// MARK: - Cite Key Generator

/// Generates cite keys from bibliographic data
public struct CiteKeyGenerator: Sendable {

    public init() {}

    /// Generate a cite key from an entry's fields
    /// Pattern: {LastName}{Year}{TitleWord}
    public func generate(from fields: [String: String]) -> String {
        let author = extractFirstAuthorLastName(from: fields["author"])
        let year = fields["year"] ?? ""
        let titleWord = extractFirstMeaningfulWord(from: fields["title"])

        var key = author + year
        if !titleWord.isEmpty {
            key += titleWord
        }

        return sanitizeCiteKey(key)
    }

    /// Generate a cite key from a search result
    public func generate(from result: SearchResult) -> String {
        let author = result.firstAuthorLastName ?? "Unknown"
        let year = result.year.map(String.init) ?? ""
        let titleWord = extractFirstMeaningfulWord(from: result.title)

        var key = author + year
        if !titleWord.isEmpty {
            key += titleWord
        }

        return sanitizeCiteKey(key)
    }

    /// Generate a unique cite key, appending suffix if needed
    public func generateUnique(
        from fields: [String: String],
        existingKeys: Set<String>
    ) -> String {
        let base = generate(from: fields)
        return makeUnique(base, existingKeys: existingKeys)
    }

    public func makeUnique(_ base: String, existingKeys: Set<String>) -> String {
        if !existingKeys.contains(base) {
            return base
        }

        // Try letter suffixes: a, b, c, ...
        for suffix in "abcdefghijklmnopqrstuvwxyz" {
            let candidate = base + String(suffix)
            if !existingKeys.contains(candidate) {
                return candidate
            }
        }

        // Fall back to numbers
        var counter = 2
        while existingKeys.contains("\(base)\(counter)") {
            counter += 1
        }
        return "\(base)\(counter)"
    }

    // MARK: - Private Helpers

    private func extractFirstAuthorLastName(from author: String?) -> String {
        guard let author = author, !author.isEmpty else {
            return "Unknown"
        }

        // Split by " and " to get first author
        let firstAuthor = author.components(separatedBy: " and ").first ?? author

        // Handle "Last, First" format
        if firstAuthor.contains(",") {
            let lastName = firstAuthor.components(separatedBy: ",").first ?? ""
            return cleanName(lastName)
        }

        // Handle "First Last" format
        let parts = firstAuthor.components(separatedBy: " ")
        if let last = parts.last {
            return cleanName(last)
        }

        return cleanName(firstAuthor)
    }

    private func cleanName(_ name: String) -> String {
        // Remove braces, accents, and normalize
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "{", with: "")
        cleaned = cleaned.replacingOccurrences(of: "}", with: "")
        cleaned = cleaned.folding(options: .diacriticInsensitive, locale: .current)

        // Keep only alphanumeric
        cleaned = cleaned.filter { $0.isLetter || $0.isNumber }

        // Capitalize first letter
        if let first = cleaned.first {
            cleaned = String(first).uppercased() + String(cleaned.dropFirst())
        }

        return cleaned
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for",
        "and", "or", "but", "with", "by", "from", "as", "is",
        "are", "was", "were", "be", "been", "being", "have",
        "has", "had", "do", "does", "did", "will", "would",
        "could", "should", "may", "might", "can", "this", "that",
    ]

    private func extractFirstMeaningfulWord(from title: String?) -> String {
        guard let title = title, !title.isEmpty else {
            return ""
        }

        // Remove braces and clean
        var cleaned = title.replacingOccurrences(of: "{", with: "")
        cleaned = cleaned.replacingOccurrences(of: "}", with: "")

        // Split into words
        let words = cleaned.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        // Find first non-stop word
        for word in words {
            if !Self.stopWords.contains(word.lowercased()) && word.count >= 3 {
                // Capitalize and clean
                var result = word.folding(options: .diacriticInsensitive, locale: .current)
                result = result.filter { $0.isLetter || $0.isNumber }
                if let first = result.first {
                    return String(first).uppercased() + String(result.dropFirst()).lowercased()
                }
            }
        }

        return ""
    }

    private func sanitizeCiteKey(_ key: String) -> String {
        // BibTeX cite keys can contain: letters, numbers, _ - : .
        var sanitized = key.filter { char in
            char.isLetter || char.isNumber || char == "_" || char == "-" || char == ":"
        }

        // Must start with a letter
        if let first = sanitized.first, !first.isLetter {
            sanitized = "ref" + sanitized
        }

        return sanitized.isEmpty ? "UnknownEntry" : sanitized
    }
}

// MARK: - Bdsk-File Codec

/// Encodes and decodes BibDesk file references (Bdsk-File-* fields)
public enum BdskFileCodec {

    /// Decode a Bdsk-File-* field value to get the relative path
    public static func decode(_ value: String) -> String? {
        // Bdsk-File values are base64-encoded binary plists
        guard let data = Data(base64Encoded: value) else {
            Logger.bibtex.warning("Failed to decode base64 Bdsk-File value")
            return nil
        }

        do {
            // Try to decode as plist
            if let plist = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] {
                // Look for relativePath key
                if let relativePath = plist["relativePath"] as? String {
                    return relativePath
                }
            }
        } catch {
            Logger.bibtex.warning("Failed to decode Bdsk-File plist: \(error.localizedDescription)")
        }

        return nil
    }

    /// Encode a relative path as a Bdsk-File-* field value
    public static func encode(relativePath: String) -> String? {
        let plist: [String: Any] = [
            "relativePath": relativePath,
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            return data.base64EncodedString()
        } catch {
            Logger.bibtex.warning("Failed to encode Bdsk-File plist: \(error.localizedDescription)")
            return nil
        }
    }

    /// Extract all file paths from an entry's Bdsk-File-* fields
    public static func extractFiles(from fields: [String: String]) -> [String] {
        var files: [String] = []

        for (key, value) in fields {
            if key.lowercased().hasPrefix("bdsk-file-") {
                if let path = decode(value) {
                    files.append(path)
                }
            }
        }

        return files.sorted()
    }

    /// Add file references to entry fields
    public static func addFiles(_ paths: [String], to fields: inout [String: String]) {
        // Remove existing Bdsk-File-* fields
        for key in fields.keys where key.lowercased().hasPrefix("bdsk-file-") {
            fields.removeValue(forKey: key)
        }

        // Add new ones
        for (index, path) in paths.enumerated() {
            if let encoded = encode(relativePath: path) {
                fields["Bdsk-File-\(index + 1)"] = encoded
            }
        }
    }
}
