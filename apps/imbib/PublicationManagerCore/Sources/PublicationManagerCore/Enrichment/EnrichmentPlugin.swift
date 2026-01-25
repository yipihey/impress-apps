//
//  EnrichmentPlugin.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Enrichment Plugin Protocol

/// Protocol for sources that can provide enrichment data for publications.
///
/// Enrichment plugins extend source capabilities to fetch additional metadata
/// beyond basic search results: citation counts, references, citations, abstracts,
/// PDF URLs, author statistics, and open access information.
///
/// ## Conformance
///
/// Sources that support enrichment should conform to this protocol via extension:
///
/// ```swift
/// extension SemanticScholarSource: EnrichmentPlugin {
///     var enrichmentCapabilities: EnrichmentCapabilities {
///         [.citationCount, .references, .citations, .abstract, .pdfURL, .authorStats]
///     }
///
///     func enrich(identifiers:existingData:) async throws -> EnrichmentResult {
///         // Implementation
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// Conforming types must be `Sendable` to support concurrent enrichment requests.
public protocol EnrichmentPlugin: Sendable {

    /// Source metadata (id, name, etc.)
    var metadata: SourceMetadata { get }

    /// Capabilities this source can provide for enrichment
    var enrichmentCapabilities: EnrichmentCapabilities { get }

    /// Enrich a paper with additional metadata.
    ///
    /// - Parameters:
    ///   - identifiers: Available identifiers for the paper (DOI, arXiv, etc.)
    ///   - existingData: Previously fetched enrichment data (for merging)
    /// - Returns: Enrichment result containing new data and resolved identifiers
    /// - Throws: `EnrichmentError` if enrichment fails
    func enrich(
        identifiers: [IdentifierType: String],
        existingData: EnrichmentData?
    ) async throws -> EnrichmentResult

    /// Enrich multiple papers in a single batch API call.
    ///
    /// Default implementation falls back to sequential `enrich()` calls.
    /// Sources that support batch queries (like ADS) should override this.
    ///
    /// - Parameter requests: Array of (publicationID, identifiers) pairs
    /// - Returns: Dictionary mapping publication IDs to their enrichment results
    func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>]

    /// Resolve paper identifiers to this source's format.
    ///
    /// For example, Semantic Scholar can resolve DOIs to S2 paper IDs.
    ///
    /// - Parameter identifiers: Available identifiers
    /// - Returns: Extended identifier map including source-specific IDs
    /// - Throws: `EnrichmentError` if resolution fails
    func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String]
}

// MARK: - Default Implementations

public extension EnrichmentPlugin {

    /// Default implementation returns identifiers unchanged.
    func resolveIdentifier(
        from identifiers: [IdentifierType: String]
    ) async throws -> [IdentifierType: String] {
        return identifiers
    }

    /// Default batch implementation falls back to sequential enrichment.
    ///
    /// Sources that support batch API calls should override this for efficiency.
    func enrichBatch(
        requests: [(publicationID: UUID, identifiers: [IdentifierType: String])]
    ) async -> [UUID: Result<EnrichmentResult, Error>] {
        var results: [UUID: Result<EnrichmentResult, Error>] = [:]

        for request in requests {
            do {
                let result = try await enrich(identifiers: request.identifiers, existingData: nil)
                results[request.publicationID] = .success(result)
            } catch {
                results[request.publicationID] = .failure(error)
            }
        }

        return results
    }

    /// Whether this plugin can potentially enrich the given identifiers.
    ///
    /// Returns `true` if any of the identifiers could be used by this source.
    func canEnrich(identifiers: [IdentifierType: String]) -> Bool {
        !identifiers.isEmpty
    }

    /// Check if this plugin supports a specific capability.
    func supports(_ capability: EnrichmentCapabilities) -> Bool {
        enrichmentCapabilities.contains(capability)
    }
}

// MARK: - Source Metadata Extension

public extension SourceMetadata {

    /// Default enrichment capabilities (none)
    var defaultEnrichmentCapabilities: EnrichmentCapabilities { [] }
}

// MARK: - Enrichable Identifier Map

/// Extension to work with identifier maps.
public extension Dictionary where Key == IdentifierType, Value == String {

    /// Create identifier map from a DOI
    static func from(doi: String) -> [IdentifierType: String] {
        [.doi: doi]
    }

    /// Create identifier map from an arXiv ID
    static func from(arxivID: String) -> [IdentifierType: String] {
        [.arxiv: arxivID]
    }

    /// Create identifier map from a bibcode
    static func from(bibcode: String) -> [IdentifierType: String] {
        [.bibcode: bibcode]
    }

    /// DOI value if present
    var doi: String? { self[.doi] }

    /// arXiv ID if present
    var arxivID: String? { self[.arxiv] }

    /// Bibcode if present
    var bibcode: String? { self[.bibcode] }

    /// PubMed ID if present
    var pmid: String? { self[.pmid] }

    /// PubMed Central ID if present
    var pmcid: String? { self[.pmcid] }

    /// Semantic Scholar ID if present
    var semanticScholarID: String? { self[.semanticScholar] }

    /// OpenAlex ID if present
    var openAlexID: String? { self[.openAlex] }

    /// Merge with another identifier map, preferring values from `other`.
    func merging(with other: [IdentifierType: String]) -> [IdentifierType: String] {
        var result = self
        for (key, value) in other {
            result[key] = value
        }
        return result
    }
}

// MARK: - CDPublication Extension

public extension CDPublication {

    /// Extract identifiers from this publication for enrichment.
    ///
    /// Uses `IdentifierExtractor` for consistent field extraction across the codebase.
    var enrichmentIdentifiers: [IdentifierType: String] {
        var result: [IdentifierType: String] = [:]

        if let doi = doi, !doi.isEmpty {
            result[.doi] = doi
        }

        // Use centralized IdentifierExtractor for consistent field extraction
        let allFields = fields

        if let arxiv = IdentifierExtractor.arxivID(from: allFields) {
            result[.arxiv] = arxiv
        }
        if let bibcodeValue = IdentifierExtractor.bibcode(from: allFields) {
            result[.bibcode] = bibcodeValue
        }
        if let pmid = IdentifierExtractor.pmid(from: allFields) {
            result[.pmid] = pmid
        }
        if let pmcid = IdentifierExtractor.pmcid(from: allFields) {
            result[.pmcid] = pmcid
        }

        // Also check stored identifier fields
        if let ssID = semanticScholarID, !ssID.isEmpty {
            result[.semanticScholar] = ssID
        }
        if let oaID = openAlexID, !oaID.isEmpty {
            result[.openAlex] = oaID
        }

        return result
    }

    /// Whether this publication has any identifiers suitable for enrichment
    var hasEnrichmentIdentifiers: Bool {
        !enrichmentIdentifiers.isEmpty
    }
}
