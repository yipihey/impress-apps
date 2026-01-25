//
//  RustSourcePlugins.swift
//  PublicationManagerCore
//
//  Swift bridge for Rust source plugin parsing functions.
//  This provides a unified API for parsing responses from various
//  academic sources (arXiv, ADS, Crossref, PubMed) using Rust.
//

import Foundation
import ImbibRustCore

// MARK: - Rust Source Plugins

/// Unified interface for parsing source plugin responses using Rust
public enum RustSourcePlugins {

    // MARK: - arXiv

    /// Parse arXiv Atom XML feed response
    /// - Parameter xml: The raw XML response from arXiv API
    /// - Returns: Array of SearchResult objects
    /// - Throws: FfiError if parsing fails
    public static func parseArxivResponse(_ xml: String) throws -> [ImbibRustCore.SearchResult] {
        try parseAtomFeed(xml: xml)
    }

    /// Build arXiv API query from user query
    /// - Parameter userQuery: User's search query
    /// - Returns: Properly formatted arXiv API query
    public static func buildArxivQuery(_ userQuery: String) -> String {
        buildApiQuery(userQuery: userQuery)
    }

    // MARK: - NASA ADS

    /// Parse ADS search response JSON
    /// - Parameter json: The raw JSON response from ADS API
    /// - Returns: Array of SearchResult objects
    /// - Throws: FfiError if parsing fails
    public static func parseADSSearchResponse(_ json: String) throws -> [ImbibRustCore.SearchResult] {
        try parseAdsSearchResponse(json: json)
    }

    /// Parse ADS paper stubs response (for references/citations)
    /// - Parameter json: The raw JSON response from ADS API
    /// - Returns: Array of PaperStub objects
    /// - Throws: FfiError if parsing fails
    public static func parseADSPaperStubs(_ json: String) throws -> [ImbibRustCore.PaperStub] {
        try parseAdsPaperStubsResponse(json: json)
    }

    /// Parse ADS BibTeX export response
    /// - Parameter json: The raw JSON export response from ADS API
    /// - Returns: BibTeX string
    /// - Throws: FfiError if parsing fails
    public static func parseADSBibTeXExport(_ json: String) throws -> String {
        try parseAdsBibtexExport(json: json)
    }

    // MARK: - Crossref

    /// Parse Crossref search response JSON
    /// - Parameter json: The raw JSON response from Crossref API
    /// - Returns: Array of SearchResult objects
    /// - Throws: FfiError if parsing fails
    public static func parseCrossrefSearchResponse(_ json: String) throws -> [ImbibRustCore.SearchResult] {
        try ImbibRustCore.parseCrossrefSearchResponse(json: json)
    }

    /// Parse Crossref single work response (DOI lookup)
    /// - Parameter json: The raw JSON response from Crossref API
    /// - Returns: Single SearchResult object
    /// - Throws: FfiError if parsing fails
    public static func parseCrossrefWorkResponse(_ json: String) throws -> ImbibRustCore.SearchResult {
        try ImbibRustCore.parseCrossrefWorkResponse(json: json)
    }

    // MARK: - PubMed

    /// Parse PubMed efetch XML response
    /// - Parameter xml: The raw XML response from PubMed API
    /// - Returns: Array of SearchResult objects
    /// - Throws: FfiError if parsing fails
    public static func parsePubMedResponse(_ xml: String) throws -> [ImbibRustCore.SearchResult] {
        try parsePubmedEfetchResponse(xml: xml)
    }

    /// Parse PubMed esearch response to get PMIDs
    /// - Parameter xml: The raw XML response from PubMed esearch API
    /// - Returns: Array of PMID strings
    /// - Throws: FfiError if parsing fails
    public static func parsePubMedSearchIds(_ xml: String) throws -> [String] {
        try parsePubmedEsearchResponse(xml: xml)
    }
}

/// Information about Rust source plugins availability
public enum RustSourcePluginsInfo {
    public static var isAvailable: Bool { true }
}
