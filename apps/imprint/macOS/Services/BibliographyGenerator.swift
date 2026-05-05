//
//  BibliographyGenerator.swift
//  imprint
//
//  Extracts citations from manuscript content and generates bibliography files.
//  Supports both LaTeX (\cite{key}) and Typst (@key) citation formats.
//

import Foundation
import ImpressKit
import ImpressLogging
import OSLog

// MARK: - Bibliography Generator

/// Generates bibliography files from manuscript content.
///
/// This service extracts cite keys from manuscript source code (supporting both
/// LaTeX and Typst formats) and fetches the corresponding BibTeX entries from imbib.
@MainActor @Observable
public final class BibliographyGenerator {

    // MARK: - Singleton

    public static let shared = BibliographyGenerator()

    // MARK: - Dependencies

    private let imbibService: ImbibIntegrationService

    // MARK: - Published State

    /// Cite keys currently found in the manuscript
    public private(set) var extractedCiteKeys: [String] = []

    /// Papers with metadata for extracted cite keys
    public private(set) var citedPapers: [CitationResult] = []

    /// Whether bibliography generation is in progress
    public private(set) var isGenerating = false

    /// Last error encountered
    public private(set) var lastError: Error?

    // Guards against re-entrancy and redundant work in `updateCitedPapers`.
    // Not observed — they exist only to stop the view `.task(id: source)`
    // from thrashing when @Observable mutations re-trigger body evaluation.
    @ObservationIgnored private var updateInFlightForSource: String?
    @ObservationIgnored private var lastUpdatedSource: String?

    // MARK: - Initialization

    private init() {
        self.imbibService = ImbibIntegrationService.shared
    }

    // MARK: - Citation Extraction

    /// Extract all cite keys from the given manuscript content.
    ///
    /// Supports:
    /// - LaTeX: `\cite{key}`, `\citep{key}`, `\citet{key}`, `\cite{key1,key2}`
    /// - Typst: `@citeKey`, `@cite-key`, `@citeKey2024`
    ///
    /// - Parameter source: The manuscript source code
    /// - Returns: Array of unique cite keys found
    public func extractCiteKeys(from source: String) -> [String] {
        var citeKeys = Set<String>()

        // LaTeX citation patterns
        // Matches: \cite{key}, \citep{key}, \citet{key}, \citeauthor{key}, \citeyear{key}
        // Also handles multiple keys: \cite{key1,key2,key3}
        let latexPattern = #"\\cite[pt]?\{([^}]+)\}"#
        let latexExtendedPattern = #"\\cite(?:author|year|alp|alt)?\*?\{([^}]+)\}"#

        // Typst citation pattern
        // Matches: @citeKey, @cite-key, @CiteKey2024
        // But not @-prefixed decorators or emails
        let typstPattern = #"(?<![a-zA-Z0-9_@])@([a-zA-Z][a-zA-Z0-9_-]*)"#

        // Extract LaTeX citations
        extractCitations(from: source, pattern: latexPattern, into: &citeKeys)
        extractCitations(from: source, pattern: latexExtendedPattern, into: &citeKeys)

        // Extract Typst citations
        extractTypstCitations(from: source, pattern: typstPattern, into: &citeKeys)

        let sortedKeys = citeKeys.sorted()
        if sortedKeys != extractedCiteKeys {
            extractedCiteKeys = sortedKeys
            Logger.compilation.infoCapture("Extracted \(sortedKeys.count) cite keys from manuscript", category: "bibliography")
        }
        return sortedKeys
    }

    private func extractCitations(from source: String, pattern: String, into citeKeys: inout Set<String>) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return
        }

        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: range)

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let keysString = String(source[keyRange])

            // Handle comma-separated keys like \cite{key1,key2,key3}
            let keys = keysString
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for key in keys {
                citeKeys.insert(key)
            }
        }
    }

    private func extractTypstCitations(from source: String, pattern: String, into citeKeys: inout Set<String>) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return
        }

        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: range)

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[keyRange])

            // Filter out common non-citation @-prefixed items
            let excludedPrefixes = ["param", "example", "deprecated", "available", "objc", "main"]
            if !excludedPrefixes.contains(where: { key.lowercased().hasPrefix($0) }) {
                citeKeys.insert(key)
            }
        }
    }

    // MARK: - Bibliography Generation

    /// Generate a .bib file from the citations in the manuscript.
    ///
    /// - Parameters:
    ///   - source: The manuscript source code
    ///   - outputPath: Optional path to save the .bib file
    /// - Returns: The generated BibTeX content
    @available(macOS 13.0, *)
    public func generateBibliography(from source: String, saveTo outputPath: URL? = nil) async throws -> String {
        guard imbibService.isAvailable else {
            throw BibliographyGeneratorError.imbibNotAvailable
        }

        isGenerating = true
        lastError = nil

        defer {
            isGenerating = false
        }

        // Extract cite keys
        let citeKeys = extractCiteKeys(from: source)

        guard !citeKeys.isEmpty else {
            Logger.compilation.infoCapture("No citations found in manuscript", category: "bibliography")
            return ""
        }

        Logger.compilation.infoCapture("Generating bibliography for \(citeKeys.count) citations", category: "bibliography")

        // Fetch BibTeX from imbib
        let bibtex: String
        do {
            bibtex = try await imbibService.getBibTeX(forCiteKeys: citeKeys)
        } catch {
            lastError = error
            throw error
        }

        // Add header comment
        let header = """
        % Bibliography generated by imprint from imbib
        % Generated: \(ISO8601DateFormatter().string(from: Date()))
        % Citation keys: \(citeKeys.joined(separator: ", "))

        """
        let fullBibtex = header + bibtex

        // Save to file if path provided
        if let outputPath = outputPath {
            do {
                try fullBibtex.write(to: outputPath, atomically: true, encoding: .utf8)
                Logger.compilation.infoCapture("Bibliography saved to: \(outputPath.path)", category: "bibliography")
            } catch {
                Logger.compilation.errorCapture("Failed to save bibliography: \(error.localizedDescription)", category: "bibliography")
                throw BibliographyGeneratorError.saveError(error.localizedDescription)
            }
        }

        return fullBibtex
    }

    /// Parsed bibitem metadata from LaTeX source.
    public struct BibitemInfo {
        let authors: String   // e.g. "Desjacques, Jeong & Schmidt"
        let year: String      // e.g. "2018"
        let fullLine: String  // the reference line after \bibitem
    }

    /// Parsed bibitem metadata keyed by cite key.
    public private(set) var bibitemMetadata: [String: BibitemInfo] = [:]

    /// Parse `\bibitem[Authors(Year)]{citekey}` entries from LaTeX source.
    /// Also captures the following reference line for richer search queries.
    public func parseBibitems(from source: String) {
        var metadata: [String: BibitemInfo] = [:]

        // Pattern: \bibitem[Authors(Year)]{citekey}
        // followed by the reference text on the next line(s)
        let lines = source.components(separatedBy: "\n")
        let bibitemPattern = try? NSRegularExpression(
            pattern: #"\\bibitem\[([^\]]+)\]\{([^}]+)\}"#
        )

        for (i, line) in lines.enumerated() {
            guard let regex = bibitemPattern,
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }

            guard let optArgRange = Range(match.range(at: 1), in: line),
                  let citeKeyRange = Range(match.range(at: 2), in: line) else { continue }

            let optArg = String(line[optArgRange])    // e.g. "Desjacques, Jeong \& Schmidt(2018)"
            let citeKey = String(line[citeKeyRange])

            // Parse authors and year from the optional argument
            var authors = optArg
            var year = ""
            if let parenRange = optArg.range(of: #"\((\d{4})\)"#, options: .regularExpression) {
                year = String(optArg[parenRange]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                authors = String(optArg[optArg.startIndex..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            // Grab the next non-empty line as the full reference
            var fullLine = ""
            if i + 1 < lines.count {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !nextLine.isEmpty && !nextLine.hasPrefix("\\bibitem") {
                    fullLine = nextLine
                }
            }

            metadata[citeKey] = BibitemInfo(authors: authors, year: year, fullLine: fullLine)
        }

        let changed = metadata.count != bibitemMetadata.count
            || metadata.keys.sorted() != bibitemMetadata.keys.sorted()
        if changed {
            bibitemMetadata = metadata
            if !metadata.isEmpty {
                Logger.compilation.infoCapture("Parsed \(metadata.count) bibitem entries from LaTeX source", category: "bibliography")
            }
        }
    }

    /// Parse a journal/volume/pages triple from a reference fragment. Handles
    /// common astronomy and physics citation styles:
    ///   - "… 1986, ApJ, 304, 15"             (year leads)
    ///   - "… 2018 MNRAS 475 1133"             (year leads, no commas)
    ///   - "JHEP 09 (2012) 082"                (journal vol (year) page)
    ///   - "JCAP 1211 (2012) 036"              (journal vol (year) page)
    ///   - "Phys. Rev. D 86, 083540 (2012)"    (journal vol, page (year))
    ///   - "Phys. Rev. Lett. 119, 031301 (2017)"
    ///   - "Nuclear Physics B 316 (1989) 391"
    /// The journal is returned in a form suitable for ADS's `bibstem:` query
    /// (capital-case, dot-stripped — "Phys. Rev. D" → "PhRvD", "JHEP"
    /// stays "JHEP"). ADS accepts the human form too, but the compact form
    /// is less ambiguous.
    nonisolated static func parseJournalRef(_ text: String) -> (journal: String, volume: String?, pages: String?)? {
        // Journal names accept dotted forms like "Phys. Rev. D" or "ApJ."
        let patterns: [String] = [
            // "1986, ApJ, 304, 15" — year, journal, volume, pages
            #"\b(\d{4})\s*[,.]?\s+([A-Z][A-Za-z.\s&]{1,40})\.?,?\s+(\d+),?\s+([A-Z]?\d+[A-Z0-9\-]*)"#,
            // "2018 MNRAS 475 1133" — year journal volume page, whitespace separated
            #"\b(\d{4})\s+([A-Z][A-Za-z.\s&]{1,40})\.?\s+(\d+)[\s,]+([A-Z]?\d+[A-Z0-9\-]*)"#,
            // "JHEP 09 (2012) 082" — journal vol (year) page
            #"([A-Z][A-Za-z.\s&]{1,40})\.?\s+(\d+)\s*\((\d{4})\)\s+([A-Z]?\d+[A-Z0-9\-]*)"#,
            // "Phys. Rev. D 86, 083540 (2012)" — journal vol, page (year)
            #"([A-Z][A-Za-z.\s&]{1,40})\.?\s+(\d+),?\s+([A-Z]?\d+[A-Z0-9\-]*)\s*\((\d{4})\)"#
        ]
        let range = NSRange(text.startIndex..., in: text)
        for (i, p) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: p),
                  let m = regex.firstMatch(in: text, range: range),
                  m.numberOfRanges >= 4 else { continue }
            // Group layout depends on the pattern.
            let journalGroup: Int
            let volumeGroup: Int
            let pageGroup: Int
            switch i {
            case 0, 1:
                journalGroup = 2; volumeGroup = 3; pageGroup = 4
            case 2:
                journalGroup = 1; volumeGroup = 2; pageGroup = 4
            case 3:
                journalGroup = 1; volumeGroup = 2; pageGroup = 3
            default:
                continue
            }
            guard let j = Range(m.range(at: journalGroup), in: text) else { continue }
            let rawJournal = String(text[j])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !rawJournal.isEmpty else { continue }
            let journal = normalizeJournalToBibstem(rawJournal)
            let volume = Range(m.range(at: volumeGroup), in: text).map { String(text[$0]) }
            let pages = Range(m.range(at: pageGroup), in: text).map { String(text[$0]) }
            return (journal, volume, pages)
        }
        return nil
    }

    /// Compact a human-written journal name into the form ADS expects for
    /// its `bibstem:` field (e.g. "Phys. Rev. D" → "PhRvD", "Astrophys. J."
    /// → "ApJ", "Nucl. Phys. B" → "NuPhB"). Already-compact names like
    /// "JHEP", "JCAP", "MNRAS", "ApJ" are returned unchanged.
    nonisolated static func normalizeJournalToBibstem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // If the input is a single token of letters (possibly ending with a
        // single capital letter suffix), assume it's already a bibstem.
        if trimmed.range(of: #"^[A-Z][A-Za-z]+$"#, options: .regularExpression) != nil {
            return trimmed
        }
        // Known mappings for the common cases.
        let lower = trimmed.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let map: [(String, String)] = [
            ("astrophys j lett", "ApJL"),
            ("astrophys j suppl", "ApJS"),
            ("astrophys j", "ApJ"),
            ("mon not r astron soc", "MNRAS"),
            ("monthly notices", "MNRAS"),
            ("phys rev lett", "PhRvL"),
            ("phys rev d", "PhRvD"),
            ("phys rev e", "PhRvE"),
            ("phys rev a", "PhRvA"),
            ("phys rev b", "PhRvB"),
            ("phys rev c", "PhRvC"),
            ("phys rev", "PhRv"),
            ("phys lett b", "PhLB"),
            ("phys lett a", "PhLA"),
            ("phys lett", "PhL"),
            ("nucl phys b", "NuPhB"),
            ("nucl phys a", "NuPhA"),
            ("nucl phys", "NuPh"),
            ("nature astronomy", "NatAs"),
            ("nature", "Natur"),
            ("science", "Sci"),
            ("astron astrophys", "A&A"),
            ("astronomy astrophysics", "A&A"),
            ("j cosmol astropart phys", "JCAP"),
            ("journal of cosmology", "JCAP")
        ]
        for (needle, bibstem) in map {
            if lower.contains(needle) { return bibstem }
        }
        // Fallback: take the first letter of each word (e.g. "Phys Rev X" → "PRX").
        let initials = trimmed
            .components(separatedBy: .whitespaces)
            .compactMap { $0.first.map(String.init) }
            .joined()
        return initials.isEmpty ? trimmed : initials
    }

    /// Strip common LaTeX escapes and macros so a BibTeX-derived string
    /// becomes a plain search query. Not a full LaTeX-to-Unicode converter —
    /// just enough to keep `ADS`, `Crossref`, `arXiv` search from choking
    /// on backslashes and braces.
    nonisolated static func sanitizeLatex(_ text: String) -> String {
        var s = text
        // `\&` `\_` `\$` `\#` `\%` → bare character
        s = s.replacingOccurrences(of: #"\\([&_\$#%])"#, with: "$1", options: .regularExpression)
        // `\'{o}` / `\'o` / `\"{u}` / `\~n` → drop the accent command, keep the letter
        s = s.replacingOccurrences(of: #"\\['"`^~=.]\{?([a-zA-Z])\}?"#, with: "$1", options: .regularExpression)
        // Remaining `\foo{...}` → keep the braced content only
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+\*?\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        // Bare `\foo` (no braces) → drop
        s = s.replacingOccurrences(of: #"\\[a-zA-Z]+\*?"#, with: "", options: .regularExpression)
        // Drop any remaining braces.
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")
        // `~` is a non-breaking space in LaTeX.
        s = s.replacingOccurrences(of: "~", with: " ")
        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Update the list of cited papers with metadata from imbib.
    ///
    /// - Parameter source: The manuscript source code
    ///
    /// Re-entrancy guard: if a call with the same `source` is already
    /// running, or the source has already been processed and produced a
    /// populated `citedPapers` list, the call is a no-op. This stops the
    /// SwiftUI `.task(id: source)` consumer from thrashing in a render
    /// loop when mutations to `@Observable` state cause the parent body
    /// to re-evaluate.
    @available(macOS 13.0, *)
    public func updateCitedPapers(from source: String, force: Bool = false) async {
        guard imbibService.isAvailable else {
            if !citedPapers.isEmpty { citedPapers = [] }
            return
        }

        // The in-flight guard still applies even under `force` — no point
        // running two resolutions of the same source in parallel.
        if updateInFlightForSource == source {
            return
        }
        // `force` skips the "already-processed" dedup so a successful
        // import can refresh the sidebar even though `source` hasn't
        // changed. Callers: the `citedPapersShouldRefresh` notification
        // after picker → import.
        if !force && lastUpdatedSource == source && !citedPapers.isEmpty {
            return
        }

        updateInFlightForSource = source
        defer {
            updateInFlightForSource = nil
            lastUpdatedSource = source
        }

        let citeKeys = extractCiteKeys(from: source)
        parseBibitems(from: source)

        guard !citeKeys.isEmpty else {
            if !citedPapers.isEmpty { citedPapers = [] }
            return
        }

        var papers: [CitationResult] = []
        var foundCount = 0
        var missingCount = 0
        var failedCount = 0

        for citeKey in citeKeys {
            do {
                if let paper = try await imbibService.getPaperMetadata(citeKey: citeKey) {
                    papers.append(paper)
                    foundCount += 1
                } else {
                    let info = bibitemMetadata[citeKey]
                    papers.append(CitationResult(
                        id: UUID(),
                        citeKey: citeKey,
                        title: "(Not found in imbib)",
                        authors: info?.authors ?? "Unknown",
                        year: Int(info?.year ?? "") ?? 0,
                        venue: "",
                        formattedPreview: info?.fullLine ?? citeKey,
                        bibtex: "",
                        hasPDF: false
                    ))
                    missingCount += 1
                }
            } catch {
                Logger.compilation.warningCapture("Failed to fetch metadata for \(citeKey): \(error.localizedDescription)", category: "bibliography")
                let info = bibitemMetadata[citeKey]
                papers.append(CitationResult(
                    id: UUID(),
                    citeKey: citeKey,
                    title: "(Failed to load)",
                    authors: info?.authors ?? "Unknown",
                    year: Int(info?.year ?? "") ?? 0,
                    venue: "",
                    formattedPreview: info?.fullLine ?? citeKey,
                    bibtex: "",
                    hasPDF: false
                ))
                failedCount += 1
            }
        }

        Logger.compilation.infoCapture(
            "Resolved \(citeKeys.count) cited papers: found=\(foundCount) missing=\(missingCount) failed=\(failedCount)",
            category: "bibliography"
        )

        // Only assign if membership changed — same set + same order should
        // not churn the observable (citedPapers carries fresh UUIDs for
        // placeholders, so compare by citeKey).
        let newKeys = papers.map(\.citeKey)
        let oldKeys = citedPapers.map(\.citeKey)
        if newKeys != oldKeys {
            citedPapers = papers
        }
    }

    // MARK: - Validation

    /// Check which cite keys are missing from the imbib library.
    ///
    /// - Parameter citeKeys: Array of cite keys to check
    /// - Returns: Array of cite keys not found in imbib
    @available(macOS 13.0, *)
    public func findMissingCitations(citeKeys: [String]) async -> [String] {
        guard imbibService.isAvailable else {
            return citeKeys
        }

        var missing: [String] = []

        for citeKey in citeKeys {
            do {
                if try await imbibService.getPaperMetadata(citeKey: citeKey) == nil {
                    missing.append(citeKey)
                }
            } catch {
                missing.append(citeKey)
            }
        }

        return missing
    }
}

// MARK: - Error Types

/// Errors that can occur during bibliography generation.
public enum BibliographyGeneratorError: LocalizedError {
    case imbibNotAvailable
    case noCitationsFound
    case saveError(String)

    public var errorDescription: String? {
        switch self {
        case .imbibNotAvailable:
            return "imbib is not available. Please install imbib to generate bibliographies."
        case .noCitationsFound:
            return "No citations found in the manuscript."
        case .saveError(let message):
            return "Failed to save bibliography file: \(message)"
        }
    }
}

// MARK: - Bibitem → CitationInput

public extension BibliographyGenerator.BibitemInfo {
    /// Convert a parsed `\bibitem` block into an `ImbibCitationInput` for
    /// imbib's structured resolve endpoint. Extracts journal/volume/pages
    /// from the reference line when possible; hands imbib the raw full
    /// line as both `rawBibtex` (for identifier scanning) and `freeText`
    /// (for the all-sources fallback).
    ///
    /// LaTeX sanitation is left to the server — `ImbibBridge` passes
    /// everything through verbatim and imbib's `LaTeXDecoder` does the
    /// accent/command decoding before query construction.
    func toCitationInput(citeKey: String) -> ImbibCitationInput {
        // Split the bibitem's [Authors(Year)] bracket into individual
        // author surnames. Handles "Smith, Jones & Brown" style lists.
        let authorList: [String] = BibliographyGenerator.splitBibitemAuthors(authors)
        let yearInt = Int(year)

        // Parse a journal/volume/pages triple out of the reference line
        // so ADS gets a precise `bibstem:/volume:/page:` on the query.
        let fullLineClean = BibliographyGenerator.sanitizeLatex(fullLine)
        let journalInfo = BibliographyGenerator.parseJournalRef(fullLineClean)

        return ImbibCitationInput(
            authors: authorList,
            title: nil,  // bibitem rarely has an explicit title field
            year: yearInt,
            journal: journalInfo?.journal,
            volume: journalInfo?.volume,
            pages: journalInfo?.pages,
            doi: nil,
            arxiv: nil,
            bibcode: nil,
            rawBibtex: fullLineClean.isEmpty ? nil : fullLineClean,
            freeText: BibliographyGenerator.defaultFreeText(
                authors: authorList,
                year: yearInt,
                fullLineClean: fullLineClean,
                citeKey: citeKey
            ),
            preferredDatabase: "astronomy"
        )
    }
}

extension BibliographyGenerator {
    /// Split `"Smith, Jones & Brown"` into `["Smith", "Jones", "Brown"]`.
    /// Strips trailing "et al." and empty tokens.
    nonisolated static func splitBibitemAuthors(_ raw: String) -> [String] {
        let cleaned = Self.sanitizeLatex(raw)
        return cleaned
            .components(separatedBy: CharacterSet(charactersIn: ",;&"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.replacingOccurrences(of: #"(?i)\bet\s*al\.?"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Build a free-text fallback: "FirstAuthor Year <clean ref line>".
    /// Truncated to 220 chars so we don't swamp all-sources search with a
    /// long abstract-style string.
    nonisolated static func defaultFreeText(
        authors: [String],
        year: Int?,
        fullLineClean: String,
        citeKey: String
    ) -> String? {
        var parts: [String] = []
        if let first = authors.first, !first.isEmpty {
            parts.append(first)
        }
        if let y = year { parts.append(String(y)) }
        if !fullLineClean.isEmpty {
            parts.append(String(fullLineClean.prefix(220)))
        }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? citeKey : joined
    }
}
