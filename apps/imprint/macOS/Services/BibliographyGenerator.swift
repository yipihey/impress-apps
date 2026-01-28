//
//  BibliographyGenerator.swift
//  imprint
//
//  Extracts citations from manuscript content and generates bibliography files.
//  Supports both LaTeX (\cite{key}) and Typst (@key) citation formats.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imprint.app", category: "bibliographyGenerator")

// MARK: - Bibliography Generator

/// Generates bibliography files from manuscript content.
///
/// This service extracts cite keys from manuscript source code (supporting both
/// LaTeX and Typst formats) and fetches the corresponding BibTeX entries from imbib.
@MainActor
public final class BibliographyGenerator: ObservableObject {

    // MARK: - Singleton

    public static let shared = BibliographyGenerator()

    // MARK: - Dependencies

    private let imbibService: ImbibIntegrationService

    // MARK: - Published State

    /// Cite keys currently found in the manuscript
    @Published public private(set) var extractedCiteKeys: [String] = []

    /// Papers with metadata for extracted cite keys
    @Published public private(set) var citedPapers: [CitationResult] = []

    /// Whether bibliography generation is in progress
    @Published public private(set) var isGenerating = false

    /// Last error encountered
    @Published public private(set) var lastError: Error?

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
        extractedCiteKeys = sortedKeys

        logger.info("Extracted \(sortedKeys.count) cite keys from manuscript")

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
            logger.info("No citations found in manuscript")
            return ""
        }

        logger.info("Generating bibliography for \(citeKeys.count) citations")

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
                logger.info("Bibliography saved to: \(outputPath.path)")
            } catch {
                logger.error("Failed to save bibliography: \(error.localizedDescription)")
                throw BibliographyGeneratorError.saveError(error.localizedDescription)
            }
        }

        return fullBibtex
    }

    /// Update the list of cited papers with metadata from imbib.
    ///
    /// - Parameter source: The manuscript source code
    @available(macOS 13.0, *)
    public func updateCitedPapers(from source: String) async {
        guard imbibService.isAvailable else {
            citedPapers = []
            return
        }

        let citeKeys = extractCiteKeys(from: source)

        guard !citeKeys.isEmpty else {
            citedPapers = []
            return
        }

        var papers: [CitationResult] = []

        for citeKey in citeKeys {
            do {
                if let paper = try await imbibService.getPaperMetadata(citeKey: citeKey) {
                    papers.append(paper)
                } else {
                    // Create placeholder for missing paper
                    papers.append(CitationResult(
                        id: UUID(),
                        citeKey: citeKey,
                        title: "(Not found in imbib)",
                        authors: "Unknown",
                        year: 0,
                        venue: "",
                        formattedPreview: citeKey,
                        bibtex: "",
                        hasPDF: false
                    ))
                }
            } catch {
                logger.warning("Failed to fetch metadata for \(citeKey): \(error.localizedDescription)")
                // Create placeholder for failed fetch
                papers.append(CitationResult(
                    id: UUID(),
                    citeKey: citeKey,
                    title: "(Failed to load)",
                    authors: "Unknown",
                    year: 0,
                    venue: "",
                    formattedPreview: citeKey,
                    bibtex: "",
                    hasPDF: false
                ))
            }
        }

        citedPapers = papers
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
