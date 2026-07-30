//
//  IdentifierExtractor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import Foundation
import ImbibRustCore

// MARK: - Identifier Extractor

/// Forwarding shim over the Rust identifier extractor (`imbib-core`).
///
/// Every regex that used to live here now lives once, in `im-identifiers`
/// (reached through `impress-identifiers`), so the import path, the PDF
/// scanner, the enrichment resolver, the CLI and the MCP tools all agree.
/// Behaviour is pinned against the pre-port Swift implementation by
/// `crates/imbib-core/test_fixtures/golden/identifiers_golden.json` — see
/// `GoldenCorpusParityTests` (Swift) and `golden_parity.rs` (Rust).
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
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: The arXiv ID if found and valid, nil otherwise
    public static func arxivID(from fields: [String: String]) -> String? {
        arxivIdFromFields(fields: fields)
    }

    /// Check if a string matches valid arXiv ID formats.
    ///
    /// Valid formats:
    /// - New format (post-2007): YYMM.NNNNN or YYMM.NNNNNvN (e.g., 2401.12345, 2401.12345v2)
    /// - Old format (pre-2007): category/NNNNNNN (e.g., astro-ph/0612345, hep-th/9901001)
    public static func isValidArXivIDFormat(_ value: String) -> Bool {
        isValidArxivIdFormat(value: value)
    }

    /// Extract DOI from BibTeX fields.
    public static func doi(from fields: [String: String]) -> String? {
        doiFromFields(fields: fields)
    }

    /// Extract ADS bibcode from BibTeX fields (`bibcode`, else parsed from `adsurl`).
    public static func bibcode(from fields: [String: String]) -> String? {
        bibcodeFromFields(fields: fields)
    }

    /// Extract PubMed ID from BibTeX fields.
    public static func pmid(from fields: [String: String]) -> String? {
        pmidFromFields(fields: fields)
    }

    /// Extract PubMed Central ID from BibTeX fields.
    public static func pmcid(from fields: [String: String]) -> String? {
        pmcidFromFields(fields: fields)
    }

    // MARK: - Batch Extraction

    /// Extract all identifiers from BibTeX fields in a single FFI call.
    ///
    /// - Parameter fields: Dictionary of BibTeX field names to values
    /// - Returns: Dictionary of identifier types to their values
    public static func allIdentifiers(from fields: [String: String]) -> [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]
        for (rawType, value) in allIdentifiersFromFields(fields: fields) {
            guard let type = IdentifierType(rawValue: rawType) else { continue }
            result[type] = value
        }
        return result
    }

    // MARK: - arXiv ID Normalization

    /// Normalize an arXiv ID for database lookups.
    ///
    /// Removes an `arXiv:` prefix, strips the version suffix and lowercases, so
    /// `arXiv:2401.12345v2` and `2401.12345` land on the same indexed key.
    public static func normalizeArXivID(_ arxivID: String) -> String {
        normalizeArxivId(arxivId: arxivID)
    }

    // MARK: - Text Content Extraction

    /// Extract the first DOI from free-form text (e.g., PDF content).
    public static func extractDOIFromText(_ text: String) -> String? {
        extractDoiFromText(text: text)
    }

    /// Extract the first arXiv ID from free-form text, normalized for lookups.
    public static func extractArXivFromText(_ text: String) -> String? {
        extractArxivFromText(text: text)
    }

    /// Extract the first ADS bibcode from free-form text.
    ///
    /// Bibcodes are 19-character identifiers like `2023ApJ...123..456A`.
    public static func extractBibcodeFromText(_ text: String) -> String? {
        ImbibRustCore.extractBibcodeFromText(text: text)
    }

    /// Extract the first PubMed ID (PMID) from free-form text, including PubMed URLs.
    public static func extractPMIDFromText(_ text: String) -> String? {
        extractPmidFromText(text: text)
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
    /// The host is validated before extraction, so an `/abs/` path on another
    /// site cannot masquerade as an ADS record.
    func extractingBibcode() -> String? {
        bibcodeFromAdsUrl(url: self)
    }
}
