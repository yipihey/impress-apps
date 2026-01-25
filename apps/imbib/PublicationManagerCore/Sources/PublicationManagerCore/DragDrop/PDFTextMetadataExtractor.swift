//
//  PDFTextMetadataExtractor.swift
//  PublicationManagerCore
//
//  Heuristic extraction of metadata (title, authors, year) from PDF text
//  when no identifiers (DOI, arXiv, bibcode) are available.
//

import Foundation
import OSLog

// MARK: - Heuristic Extracted Fields

/// Metadata extracted heuristically from PDF text.
public struct HeuristicExtractedFields: Sendable {
    /// Title extracted from PDF (first major text block)
    public let title: String?

    /// Authors extracted from PDF
    public let authors: [String]

    /// Year extracted from PDF (4-digit pattern)
    public let year: Int?

    /// Journal name if detected
    public let journal: String?

    /// Confidence level of extraction
    public let confidence: HeuristicConfidence

    public init(
        title: String? = nil,
        authors: [String] = [],
        year: Int? = nil,
        journal: String? = nil,
        confidence: HeuristicConfidence = .none
    ) {
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.confidence = confidence
    }
}

/// Confidence level for heuristic extraction.
public enum HeuristicConfidence: Int, Comparable, Sendable {
    /// No metadata could be extracted
    case none = 0

    /// Low confidence (single field extracted)
    case low = 1

    /// Medium confidence (multiple fields, some validation)
    case medium = 2

    /// High confidence (all major fields extracted with validation)
    case high = 3

    public static func < (lhs: HeuristicConfidence, rhs: HeuristicConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - PDF Text Metadata Extractor

/// Extracts structured metadata from PDF text using heuristics.
///
/// Used as a fallback when no identifiers (DOI, arXiv, bibcode) are found.
/// Applies pattern matching and NLP-like heuristics to extract:
/// - Title (first large text block before author-like content)
/// - Authors (lines with name patterns, "and" connectors)
/// - Year (4-digit patterns 19xx, 20xx)
/// - Journal (common journal name patterns)
public enum PDFTextMetadataExtractor {

    // MARK: - Public Methods

    /// Extract metadata from PDF first page text.
    ///
    /// - Parameter firstPageText: Text from the first page of the PDF
    /// - Returns: Extracted fields with confidence score
    public static func extract(from firstPageText: String) -> HeuristicExtractedFields {
        let lines = firstPageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var extractedTitle: String?
        var extractedAuthors: [String] = []
        var extractedYear: Int?
        var extractedJournal: String?

        // Extract title (usually first significant text block)
        extractedTitle = extractTitle(from: lines)

        // Extract authors (look for name patterns)
        extractedAuthors = extractAuthors(from: lines)

        // Extract year (4-digit pattern)
        extractedYear = extractYear(from: firstPageText)

        // Extract journal (if present)
        extractedJournal = extractJournal(from: firstPageText)

        // Calculate confidence
        let confidence = calculateConfidence(
            title: extractedTitle,
            authors: extractedAuthors,
            year: extractedYear
        )

        Logger.files.debugCapture(
            "Heuristic extraction - title: \(extractedTitle?.prefix(50) ?? "none"), authors: \(extractedAuthors.count), year: \(extractedYear ?? 0), confidence: \(confidence)",
            category: "files"
        )

        return HeuristicExtractedFields(
            title: extractedTitle,
            authors: extractedAuthors,
            year: extractedYear,
            journal: extractedJournal,
            confidence: confidence
        )
    }

    // MARK: - Title Extraction

    /// Extract title from PDF text lines.
    ///
    /// Heuristics:
    /// - First large text block (10+ chars) that isn't a header pattern
    /// - Before author-like content
    /// - Exclude journal names, dates, page numbers
    private static func extractTitle(from lines: [String]) -> String? {
        // Patterns to skip (headers, metadata, etc.)
        let skipPatterns = [
            "preprint", "submitted", "accepted", "published", "received",
            "journal", "volume", "issue", "pages", "vol.", "no.",
            "doi:", "arxiv:", "http", "www", "©", "copyright",
            "all rights reserved", "abstract", "introduction",
            "keywords:", "pacs:", "msc:"
        ]

        var candidateLines: [String] = []
        var foundAuthorLikeLine = false

        for line in lines.prefix(25) {  // Check first 25 lines
            let lowercased = line.lowercased()

            // Skip if matches header patterns
            if skipPatterns.contains(where: { lowercased.contains($0) }) {
                continue
            }

            // Skip very short lines (page numbers, etc.)
            if line.count < 10 {
                continue
            }

            // Skip lines that look like affiliations
            if lowercased.contains("@") ||
               lowercased.contains("university") ||
               lowercased.contains("institute") ||
               lowercased.contains("department") ||
               lowercased.contains("laboratory") {
                continue
            }

            // Check if line looks like authors (stop collecting title candidates)
            if looksLikeAuthorLine(line) {
                foundAuthorLikeLine = true
                continue
            }

            // Stop if we've passed author-like content
            if foundAuthorLikeLine {
                break
            }

            candidateLines.append(line)

            // Limit title candidates
            if candidateLines.count >= 3 {
                break
            }
        }

        // Join candidate lines if they look like a multi-line title
        guard !candidateLines.isEmpty else { return nil }

        if candidateLines.count >= 2 {
            let combined = candidateLines.joined(separator: " ")
            // Check if combined length is reasonable for a title
            if combined.count <= 300 {
                return cleanTitle(combined)
            }
        }

        return cleanTitle(candidateLines.first!)
    }

    /// Check if a line looks like it contains author names.
    private static func looksLikeAuthorLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()

        // Contains " and " between words (common in author lists)
        if lowercased.contains(" and ") {
            let parts = lowercased.components(separatedBy: " and ")
            // Both parts should have capitalized words
            if parts.count >= 2 && parts.allSatisfy({ hasCapitalizedWords($0) }) {
                return true
            }
        }

        // Multiple comma-separated names
        let commaParts = line.components(separatedBy: ",")
        if commaParts.count >= 2 {
            // Check if parts look like names (capitalized words)
            let nameLikeParts = commaParts.filter { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return trimmed.count > 2 && hasCapitalizedWords(trimmed)
            }
            if nameLikeParts.count >= 2 {
                return true
            }
        }

        // Superscript/footnote markers common in author lists
        if line.contains("*") || line.contains("†") || line.contains("‡") {
            // And has name-like patterns
            if hasCapitalizedWords(line) {
                return true
            }
        }

        return false
    }

    /// Check if string has capitalized words (name-like pattern).
    private static func hasCapitalizedWords(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespaces)
        let capitalizedCount = words.filter { word in
            guard let first = word.first else { return false }
            return first.isUppercase && word.count > 1
        }.count
        return capitalizedCount >= 2
    }

    /// Clean up extracted title.
    private static func cleanTitle(_ title: String) -> String {
        var result = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing punctuation that shouldn't be in titles
        while result.hasSuffix(".") || result.hasSuffix(",") || result.hasSuffix(";") {
            result.removeLast()
        }

        return result
    }

    // MARK: - Author Extraction

    /// Extract author names from PDF text lines.
    ///
    /// Heuristics:
    /// - Lines with " and " between capitalized names
    /// - Comma-separated lists of names
    /// - Names with affiliations markers (*, †, ‡, superscripts)
    private static func extractAuthors(from lines: [String]) -> [String] {
        var authors: [String] = []

        // Look for author lines in first 30 lines
        for line in lines.prefix(30) {
            if looksLikeAuthorLine(line) {
                // Extract names from this line
                let extracted = extractNamesFromLine(line)
                if !extracted.isEmpty {
                    authors.append(contentsOf: extracted)
                }
            }
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        return authors.filter { name in
            let normalized = name.lowercased()
            if seen.contains(normalized) {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    /// Extract individual names from an author line.
    private static func extractNamesFromLine(_ line: String) -> [String] {
        var names: [String] = []

        // Clean the line of affiliations markers
        var cleaned = line
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "†", with: "")
            .replacingOccurrences(of: "‡", with: "")
            .replacingOccurrences(of: "§", with: "")

        // Remove superscript digits (1, 2, 3, etc. used for affiliations)
        cleaned = cleaned.replacingOccurrences(
            of: #"[¹²³⁴⁵⁶⁷⁸⁹⁰]"#,
            with: "",
            options: .regularExpression
        )

        // Split by " and " first
        let andParts = cleaned.components(separatedBy: " and ")

        for part in andParts {
            // Then split by commas
            let commaParts = part.components(separatedBy: ",")

            for commaPart in commaParts {
                let trimmed = commaPart.trimmingCharacters(in: .whitespacesAndNewlines)

                // Validate as a name (2+ capitalized words, reasonable length)
                if isValidName(trimmed) {
                    names.append(formatAuthorName(trimmed))
                }
            }
        }

        return names
    }

    /// Check if a string looks like a valid author name.
    private static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Should have reasonable length
        guard trimmed.count >= 3 && trimmed.count <= 100 else { return false }

        // Should have at least 2 words
        let words = trimmed.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return false }

        // First word should be capitalized (first name or initial)
        guard let firstWord = words.first,
              let firstChar = firstWord.first,
              firstChar.isUppercase else { return false }

        // Shouldn't contain obvious non-name patterns
        let lowercased = trimmed.lowercased()
        let nonNamePatterns = [
            "university", "institute", "department", "laboratory",
            "et al", "submitted", "accepted", "@"
        ]
        if nonNamePatterns.contains(where: { lowercased.contains($0) }) {
            return false
        }

        return true
    }

    /// Format author name to "LastName, FirstName" format.
    private static func formatAuthorName(_ name: String) -> String {
        let parts = name.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else { return name }

        // If already in "LastName, FirstName" format, return as-is
        if name.contains(",") {
            return name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Convert "FirstName LastName" to "LastName, FirstName"
        let lastName = parts.last!
        let firstNames = parts.dropLast().joined(separator: " ")

        return "\(lastName), \(firstNames)"
    }

    // MARK: - Year Extraction

    /// Extract publication year from text.
    ///
    /// Heuristics:
    /// - 4-digit patterns (19xx, 20xx)
    /// - Near keywords like "published", "accepted", etc.
    /// - Prefer years in reasonable range (1900-current+1)
    private static func extractYear(from text: String) -> Int? {
        let currentYear = Calendar.current.component(.year, from: Date())
        let minYear = 1900
        let maxYear = currentYear + 1

        // Pattern: 4-digit year
        let yearPattern = #"\b(19\d{2}|20\d{2})\b"#

        guard let regex = try? NSRegularExpression(pattern: yearPattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var candidates: [Int] = []

        for match in matches {
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let yearString = String(text[matchRange])
            guard let year = Int(yearString) else { continue }

            // Validate year is in reasonable range
            if year >= minYear && year <= maxYear {
                candidates.append(year)
            }
        }

        // Prefer years near "published", "accepted", etc.
        // For now, just return the most recent reasonable year
        // (publications are usually newer)
        return candidates.max()
    }

    // MARK: - Journal Extraction

    /// Extract journal name from text (if present).
    private static func extractJournal(from text: String) -> String? {
        let lowercased = text.lowercased()

        // Common journal name patterns
        let journalPatterns = [
            #"published in (.+?)(?:\.|,|$)"#,
            #"journal of (.+?)(?:\.|,|$)"#,
            #"proceedings of (.+?)(?:\.|,|$)"#,
            #"accepted (?:for publication )?(?:in|by) (.+?)(?:\.|,|$)"#,
        ]

        for pattern in journalPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let range = NSRange(lowercased.startIndex..., in: lowercased)
            if let match = regex.firstMatch(in: lowercased, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: lowercased) {
                let journal = String(text[captureRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Validate journal name (reasonable length, no obvious non-journal content)
                if journal.count >= 5 && journal.count <= 200 {
                    return journal
                }
            }
        }

        return nil
    }

    // MARK: - Confidence Calculation

    /// Calculate confidence based on what was extracted.
    private static func calculateConfidence(
        title: String?,
        authors: [String],
        year: Int?
    ) -> HeuristicConfidence {
        var score = 0

        // Title contributes most
        if let title, title.count >= 20 {
            score += 2
        } else if title != nil {
            score += 1
        }

        // Authors
        if authors.count >= 2 {
            score += 2
        } else if !authors.isEmpty {
            score += 1
        }

        // Year
        if year != nil {
            score += 1
        }

        switch score {
        case 0:
            return .none
        case 1...2:
            return .low
        case 3...4:
            return .medium
        default:
            return .high
        }
    }
}
