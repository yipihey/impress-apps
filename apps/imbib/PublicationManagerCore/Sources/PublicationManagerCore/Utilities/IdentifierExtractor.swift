//
//  IdentifierExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation

// MARK: - Identifier Extractor

/// Centralized utility for extracting publication identifiers from BibTeX fields.
///
/// This eliminates duplicate identifier extraction logic and ensures consistent
/// handling across ManagedObjects, LocalPaper, and EnrichmentPlugin.
///
/// Field priority order for each identifier:
/// - arXiv: `eprint` → `arxivid` → `arxiv`
/// - DOI: `doi`
/// - Bibcode: `bibcode` (or extracted from `adsurl`)
/// - PMID: `pmid`
/// - PMCID: `pmcid`
public enum IdentifierExtractor {

    // MARK: - Individual Identifier Extraction

    /// Extract arXiv ID from BibTeX fields.
    ///
    /// Checks fields in priority order: `eprint`, `arxivid`, `arxiv`.
    /// The `eprint` field is standard BibTeX, while `arxivid` and `arxiv` are
    /// common alternatives used by various tools.
    ///
    /// Validates that the extracted value is actually a valid arXiv ID (not a bibcode,
    /// DOI, or other identifier that some sources incorrectly put in the eprint field).
    /// Also handles arXiv DOIs (`10.48550/arXiv.XXXX`) by extracting the actual arXiv ID.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The arXiv ID if found and valid, nil otherwise
    public static func arxivID(from fields: [String: String]) -> String? {
        // Check fields in priority order
        let candidates = [fields["eprint"], fields["arxivid"], fields["arxiv"]]

        for candidate in candidates {
            guard let value = candidate, !value.isEmpty else { continue }

            // Check if it's an arXiv DOI (10.48550/arXiv.XXXX) and extract the ID
            if let extractedID = extractArXivIDFromDOI(value) {
                return extractedID
            }

            // Clean the value (remove arXiv: prefix if present)
            var cleanValue = value.trimmingCharacters(in: .whitespaces)
            if cleanValue.lowercased().hasPrefix("arxiv:") {
                cleanValue = String(cleanValue.dropFirst(6))
            }

            // Validate it's actually an arXiv ID format
            if isValidArXivIDFormat(cleanValue) {
                return cleanValue
            }
        }

        return nil
    }

    /// Extract arXiv ID from an arXiv DOI.
    /// arXiv DOIs have format: 10.48550/arXiv.{arxivID}
    private static func extractArXivIDFromDOI(_ value: String) -> String? {
        let lowercased = value.lowercased()
        guard lowercased.hasPrefix("10.48550/arxiv.") else { return nil }

        // Extract the part after "10.48550/arXiv."
        let prefix = "10.48550/arxiv."
        let startIndex = value.index(value.startIndex, offsetBy: prefix.count)
        let extractedID = String(value[startIndex...])

        // Validate the extracted ID
        if isValidArXivIDFormat(extractedID) {
            return extractedID
        }
        return nil
    }

    /// Check if a string matches valid arXiv ID formats.
    ///
    /// Valid formats:
    /// - New format (post-2007): YYMM.NNNNN or YYMM.NNNNNvN (e.g., 2401.12345, 2401.12345v2)
    /// - Old format (pre-2007): category/NNNNNNN (e.g., astro-ph/0612345, hep-th/9901001)
    ///
    /// This is public so that other parts of the codebase can validate arXiv IDs
    /// (e.g., ADS enrichment validating identifiers from API responses).
    public static func isValidArXivIDFormat(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // New format: YYMM.NNNNN(vN) - 4 digits, dot, 4-5 digits, optional version
        let newFormatPattern = #"^\d{4}\.\d{4,5}(v\d+)?$"#
        if let regex = try? NSRegularExpression(pattern: newFormatPattern),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }

        // Old format: category/NNNNNNN(vN) - letters/hyphens, slash, 7 digits, optional version
        let oldFormatPattern = #"^[a-z-]+/\d{7}(v\d+)?$"#
        if let regex = try? NSRegularExpression(pattern: oldFormatPattern, options: .caseInsensitive),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }

        return false
    }

    /// Extract DOI from BibTeX fields.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The DOI if found, nil otherwise
    public static func doi(from fields: [String: String]) -> String? {
        fields["doi"]
    }

    /// Extract ADS bibcode from BibTeX fields.
    ///
    /// Checks the `bibcode` field first, then attempts to extract from `adsurl`
    /// if present.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The bibcode if found, nil otherwise
    public static func bibcode(from fields: [String: String]) -> String? {
        fields["bibcode"] ?? fields["adsurl"]?.extractingBibcode()
    }

    /// Extract PubMed ID from BibTeX fields.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The PMID if found, nil otherwise
    public static func pmid(from fields: [String: String]) -> String? {
        fields["pmid"]
    }

    /// Extract PubMed Central ID from BibTeX fields.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The PMCID if found, nil otherwise
    public static func pmcid(from fields: [String: String]) -> String? {
        fields["pmcid"]
    }

    // MARK: - Batch Extraction

    /// Extract all identifiers from BibTeX fields at once.
    ///
    /// This is more efficient than calling individual methods when you need
    /// multiple identifiers, as it only iterates the fields once.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: Dictionary of identifier types to their values
    public static func allIdentifiers(from fields: [String: String]) -> [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]

        if let arxiv = arxivID(from: fields) {
            result[.arxiv] = arxiv
        }
        if let doi = doi(from: fields) {
            result[.doi] = doi
        }
        if let bibcode = bibcode(from: fields) {
            result[.bibcode] = bibcode
        }
        if let pmid = pmid(from: fields) {
            result[.pmid] = pmid
        }
        if let pmcid = pmcid(from: fields) {
            result[.pmcid] = pmcid
        }

        return result
    }

    // MARK: - arXiv ID Normalization

    /// Normalize an arXiv ID for database lookups.
    ///
    /// Handles:
    /// - Removes `arXiv:` prefix if present
    /// - Strips version suffix (e.g., `2401.12345v2` → `2401.12345`)
    /// - Lowercases for case-insensitive matching
    ///
    /// - Parameter arxivID: Raw arXiv ID
    /// - Returns: Normalized arXiv ID for indexed lookups
    public static func normalizeArXivID(_ arxivID: String) -> String {
        var id = arxivID.trimmingCharacters(in: .whitespaces)

        // Remove arXiv: prefix
        if id.lowercased().hasPrefix("arxiv:") {
            id = String(id.dropFirst(6))
        }

        // Strip version suffix (v1, v2, etc.)
        if let vIndex = id.lastIndex(of: "v") {
            let suffix = id[id.index(after: vIndex)...]
            if suffix.allSatisfy({ $0.isNumber }) && !suffix.isEmpty {
                id = String(id[..<vIndex])
            }
        }

        return id.lowercased()
    }

    // MARK: - Text Content Extraction

    /// Extract DOI from free-form text (e.g., PDF content).
    ///
    /// Matches DOI patterns like:
    /// - `10.1234/abc.def`
    /// - `doi:10.1234/abc.def`
    /// - `https://doi.org/10.1234/abc.def`
    ///
    /// - Parameter text: Text to search for DOI
    /// - Returns: The first DOI found, or nil
    public static func extractDOIFromText(_ text: String) -> String? {
        // DOI pattern: 10.XXXX/... where XXXX is 4+ digits
        // DOI can contain alphanumerics, dashes, dots, underscores, colons, parentheses, etc.
        // Terminates at whitespace, comma, semicolon, or certain punctuation
        let doiPattern = #"(?:doi[:\s]*)?(?:https?://(?:dx\.)?doi\.org/)?10\.\d{4,}/[^\s,;"\]>)]+[^\s,;"\]>).]"#

        guard let regex = try? NSRegularExpression(pattern: doiPattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        var doi = String(text[matchRange])

        // Clean up: remove "doi:" or "doi " prefix if present
        let lowercased = doi.lowercased()
        if lowercased.hasPrefix("doi:") {
            doi = String(doi.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else if lowercased.hasPrefix("doi ") {
            doi = String(doi.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else if lowercased.hasPrefix("doi") && doi.count > 3 && doi[doi.index(doi.startIndex, offsetBy: 3)].isWhitespace {
            // Handle any whitespace after "doi"
            doi = String(doi.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }

        // Clean up: remove URL prefix if present
        if let urlRange = doi.range(of: "doi.org/", options: .caseInsensitive) {
            doi = String(doi[urlRange.upperBound...])
        }

        // Clean up: remove trailing punctuation
        while doi.last == "." || doi.last == "," || doi.last == ";" {
            doi.removeLast()
        }

        return doi.isEmpty ? nil : doi
    }

    /// Extract arXiv ID from free-form text (e.g., PDF content).
    ///
    /// Matches arXiv patterns like:
    /// - New format: `2401.12345` or `2401.12345v2`
    /// - Old format: `astro-ph/0612345` or `hep-th/0612345v1`
    /// - With prefix: `arXiv:2401.12345`
    ///
    /// - Parameter text: Text to search for arXiv ID
    /// - Returns: The first arXiv ID found (normalized), or nil
    public static func extractArXivFromText(_ text: String) -> String? {
        // New format: YYMM.NNNNN(vN)
        let newFormatPattern = #"(?:arXiv:)?(\d{4}\.\d{4,5}(?:v\d+)?)"#

        // Old format: category/NNNNNNN(vN)
        let oldFormatPattern = #"(?:arXiv:)?([a-z-]+/\d{7}(?:v\d+)?)"#

        // Try new format first (more common)
        if let regex = try? NSRegularExpression(pattern: newFormatPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: text) {
                return normalizeArXivID(String(text[captureRange]))
            }
        }

        // Try old format
        if let regex = try? NSRegularExpression(pattern: oldFormatPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: text) {
                return normalizeArXivID(String(text[captureRange]))
            }
        }

        return nil
    }

    /// Extract ADS bibcode from free-form text.
    ///
    /// Bibcodes are 19-character identifiers like: `2023ApJ...123..456A`
    /// Format: YYYYJJJJJVVVVMPPPPA
    /// - YYYY: Year
    /// - JJJJJ: Journal abbreviation (5 chars, right-padded with dots)
    /// - VVVV: Volume (4 chars, left-padded with dots)
    /// - M: Page type indicator (., L, E, etc.)
    /// - PPPP: Page (4 chars, left-padded with dots)
    /// - A: Author initial
    ///
    /// - Parameter text: Text to search for bibcode
    /// - Returns: The first bibcode found, or nil
    public static func extractBibcodeFromText(_ text: String) -> String? {
        // Bibcode pattern: 19 chars, starts with 4-digit year
        // Format: YYYYJJJJJVVVVMPPPPA
        // - YYYY: Year (4 digits)
        // - JJJJJ: Journal (5 chars, letters/numbers/ampersand/dots)
        // - VVVV: Volume (4 chars, digits/dots for padding)
        // - M: Qualifier (1 char, letter or dot)
        // - PPPP: Page (4 chars, digits/dots for padding)
        // - A: Author initial (1 char)
        let bibcodePattern = #"\b((?:19|20)\d{2}[A-Za-z&.]{5}[.\d]{4}[A-Za-z.][.\d]{4}[A-Za-z.])\b"#

        guard let regex = try? NSRegularExpression(pattern: bibcodePattern, options: []) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let bibcode = String(text[matchRange])

        // Validate length (should be exactly 19 chars)
        guard bibcode.count == 19 else {
            return nil
        }

        return bibcode
    }

    /// Extract PubMed ID (PMID) from free-form text.
    ///
    /// Matches patterns like:
    /// - `PMID: 12345678`
    /// - `PubMed ID: 12345678`
    /// - `https://pubmed.ncbi.nlm.nih.gov/12345678`
    ///
    /// - Parameter text: Text to search for PMID
    /// - Returns: The first PMID found, or nil
    public static func extractPMIDFromText(_ text: String) -> String? {
        // PMID with prefix
        let pmidPattern = #"(?:PMID|PubMed(?:\s*ID)?)[:\s]+(\d{6,9})"#

        if let regex = try? NSRegularExpression(pattern: pmidPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: text) {
                return String(text[captureRange])
            }
        }

        // PubMed URL pattern
        let urlPattern = #"pubmed\.ncbi\.nlm\.nih\.gov/(\d{6,9})"#

        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let captureRange = Range(match.range(at: 1), in: text) {
                return String(text[captureRange])
            }
        }

        return nil
    }
}

// MARK: - String Extension for Bibcode Extraction

public extension String {
    /// Extract ADS bibcode from an ADS URL.
    ///
    /// Handles URLs like:
    /// - `https://ui.adsabs.harvard.edu/abs/2023ApJ...123..456A/abstract`
    /// - `https://adsabs.harvard.edu/abs/2023ApJ...123..456A`
    ///
    /// Validates that the URL actually points to an ADS domain before extraction.
    ///
    /// - Returns: The bibcode if found, nil otherwise
    func extractingBibcode() -> String? {
        // Use URL parsing for robustness
        guard let url = URL(string: self),
              url.host?.contains("adsabs") == true,
              url.pathComponents.contains("abs"),
              let bibcodeIndex = url.pathComponents.firstIndex(of: "abs"),
              bibcodeIndex + 1 < url.pathComponents.count else {
            return nil
        }
        return url.pathComponents[bibcodeIndex + 1]
    }
}
