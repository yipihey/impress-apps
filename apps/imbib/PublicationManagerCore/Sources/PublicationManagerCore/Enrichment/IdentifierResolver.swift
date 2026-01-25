//
//  IdentifierResolver.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Identifier Resolver

/// Service for resolving publication identifiers across different systems.
///
/// Maps between identifier types:
/// - DOI → OpenAlex ID, Semantic Scholar ID
/// - arXiv ID → Semantic Scholar ID, DOI
/// - Bibcode → DOI
/// - PubMed ID → DOI
///
/// ## Usage
///
/// ```swift
/// let resolver = IdentifierResolver()
///
/// // Resolve DOI to Semantic Scholar ID
/// let s2ID = try await resolver.resolveToSemanticScholar(doi: "10.1234/test")
///
/// // Resolve arXiv ID to DOI
/// let doi = try await resolver.resolveArXivToDOI(arxivID: "2301.12345")
/// ```
public actor IdentifierResolver {

    // MARK: - Dependencies

    private let session: URLSession

    // MARK: - Cache

    private var resolutionCache: [String: [IdentifierType: String]] = [:]
    private let maxCacheSize: Int

    // MARK: - Initialization

    public init(session: URLSession = .shared, maxCacheSize: Int = 1000) {
        self.session = session
        self.maxCacheSize = maxCacheSize
    }

    // MARK: - Resolution Methods

    /// Resolve identifiers to include as many types as possible.
    ///
    /// Takes existing identifiers and attempts to resolve additional ones.
    ///
    /// - Parameter identifiers: Known identifiers
    /// - Returns: Extended identifier map
    public func resolve(_ identifiers: [IdentifierType: String]) async -> [IdentifierType: String] {
        var result = identifiers

        // Check cache first
        if let cacheKey = identifiers.doi ?? identifiers.arxivID {
            if let cached = resolutionCache[cacheKey] {
                Logger.enrichment.debug("IdentifierResolver: cache hit for \(cacheKey)")
                return identifiers.merging(with: cached)
            }
        }

        // Try to resolve missing identifiers
        var resolved: [IdentifierType: String] = [:]

        // DOI → Semantic Scholar ID
        if let doi = identifiers.doi, identifiers.semanticScholarID == nil {
            resolved[.semanticScholar] = "DOI:\(doi)"
        }

        // arXiv → Semantic Scholar ID
        if let arxiv = identifiers.arxivID, identifiers.semanticScholarID == nil {
            resolved[.semanticScholar] = "ARXIV:\(arxiv)"
        }

        // PubMed → Semantic Scholar ID
        if let pmid = identifiers.pmid, identifiers.semanticScholarID == nil {
            resolved[.semanticScholar] = "PMID:\(pmid)"
        }

        // DOI → OpenAlex ID (format: W followed by numbers, derived from DOI hash)
        if let doi = identifiers.doi, identifiers.openAlexID == nil {
            // OpenAlex can be queried by DOI directly
            resolved[.openAlex] = "https://doi.org/\(doi)"
        }

        // Merge resolved identifiers
        result = result.merging(with: resolved)

        // Cache the resolution
        if let cacheKey = identifiers.doi ?? identifiers.arxivID {
            cacheResolution(key: cacheKey, identifiers: resolved)
        }

        return result
    }

    /// Resolve DOI to Semantic Scholar paper ID format.
    ///
    /// - Parameter doi: The DOI to resolve
    /// - Returns: Semantic Scholar paper ID (format: "DOI:xxx")
    public func resolveToSemanticScholar(doi: String) -> String {
        "DOI:\(doi)"
    }

    /// Resolve arXiv ID to Semantic Scholar paper ID format.
    ///
    /// - Parameter arxivID: The arXiv ID to resolve
    /// - Returns: Semantic Scholar paper ID (format: "ARXIV:xxx")
    public func resolveToSemanticScholar(arxivID: String) -> String {
        "ARXIV:\(arxivID)"
    }

    /// Resolve PubMed ID to Semantic Scholar paper ID format.
    ///
    /// - Parameter pmid: The PubMed ID to resolve
    /// - Returns: Semantic Scholar paper ID (format: "PMID:xxx")
    public func resolveToSemanticScholar(pmid: String) -> String {
        "PMID:\(pmid)"
    }

    /// Check if we can resolve identifiers to a specific source.
    ///
    /// - Parameters:
    ///   - identifiers: Available identifiers
    ///   - source: Target enrichment source
    /// - Returns: `true` if resolution is possible
    public func canResolve(_ identifiers: [IdentifierType: String], to source: EnrichmentSource) -> Bool {
        switch source {
        case .ads:
            // ADS uses bibcode, DOI, or arXiv
            return identifiers.bibcode != nil ||
                   identifiers.doi != nil ||
                   identifiers.arxivID != nil
        case .wos:
            // WoS primarily uses DOI or WoS UT
            return identifiers.doi != nil
        case .openalex:
            // OpenAlex uses DOI, OpenAlex ID, or any other identifier
            return identifiers.doi != nil ||
                   identifiers[.openAlex] != nil ||
                   identifiers.arxivID != nil
        }
    }

    /// Get the preferred identifier for a source.
    ///
    /// - Parameters:
    ///   - identifiers: Available identifiers
    ///   - source: Target enrichment source
    /// - Returns: The best identifier to use for this source
    public func preferredIdentifier(
        from identifiers: [IdentifierType: String],
        for source: EnrichmentSource
    ) -> (type: IdentifierType, value: String)? {
        switch source {
        case .ads:
            // Prefer bibcode, then DOI, then arXiv
            if let bibcode = identifiers.bibcode {
                return (.bibcode, bibcode)
            }
            if let doi = identifiers.doi {
                return (.doi, doi)
            }
            if let arxiv = identifiers.arxivID {
                return (.arxiv, arxiv)
            }
        case .wos:
            // WoS prefers DOI
            if let doi = identifiers.doi {
                return (.doi, doi)
            }
        case .openalex:
            // OpenAlex prefers DOI, then OpenAlex ID, then arXiv
            if let doi = identifiers.doi {
                return (.doi, doi)
            }
            if let openAlexID = identifiers[.openAlex] {
                return (.openAlex, openAlexID)
            }
            if let arxiv = identifiers.arxivID {
                return (.arxiv, arxiv)
            }
        }
        return nil
    }

    // MARK: - Online Resolution (Future Enhancement)

    /// Resolve arXiv ID to DOI via arXiv API.
    ///
    /// - Parameter arxivID: The arXiv ID
    /// - Returns: DOI if found, nil otherwise
    /// - Note: This requires an API call and may be rate-limited.
    public func resolveArXivToDOI(arxivID: String) async throws -> String? {
        // arXiv metadata API: https://export.arxiv.org/api/query?id_list=arxivID
        // The DOI is in the <link> element with rel="related" title="doi"
        // For now, return nil - implement when needed
        Logger.enrichment.debug("IdentifierResolver: arXiv→DOI resolution not yet implemented")
        return nil
    }

    /// Resolve DOI to OpenAlex work ID.
    ///
    /// - Parameter doi: The DOI
    /// - Returns: OpenAlex work ID if found
    public func resolveToOpenAlex(doi: String) async throws -> String? {
        // OpenAlex API: https://api.openalex.org/works/doi:{doi}
        // Returns work with ID field
        // For now, return nil - implement when needed
        Logger.enrichment.debug("IdentifierResolver: DOI→OpenAlex resolution not yet implemented")
        return nil
    }

    // MARK: - Cache Management

    /// Clear the resolution cache.
    public func clearCache() {
        resolutionCache.removeAll()
        Logger.enrichment.debug("IdentifierResolver: cache cleared")
    }

    /// Current cache size.
    public var cacheSize: Int {
        resolutionCache.count
    }

    // MARK: - Private Helpers

    private func cacheResolution(key: String, identifiers: [IdentifierType: String]) {
        // Evict oldest entries if cache is full
        if resolutionCache.count >= maxCacheSize {
            // Simple eviction: remove first 10%
            let toRemove = maxCacheSize / 10
            for key in resolutionCache.keys.prefix(toRemove) {
                resolutionCache.removeValue(forKey: key)
            }
        }
        resolutionCache[key] = identifiers
    }
}

// MARK: - Identifier Type Extensions

public extension IdentifierType {

    /// URL prefix for this identifier type (if applicable).
    var urlPrefix: String? {
        switch self {
        case .doi: return "https://doi.org/"
        case .arxiv: return "https://arxiv.org/abs/"
        case .pmid: return "https://pubmed.ncbi.nlm.nih.gov/"
        case .pmcid: return "https://www.ncbi.nlm.nih.gov/pmc/articles/"
        case .bibcode: return "https://ui.adsabs.harvard.edu/abs/"
        case .semanticScholar: return "https://www.semanticscholar.org/paper/"
        case .openAlex: return "https://openalex.org/works/"
        case .dblp: return "https://dblp.org/rec/"
        }
    }

    /// Create a URL from an identifier value.
    func url(for value: String) -> URL? {
        guard let prefix = urlPrefix else { return nil }
        return URL(string: prefix + value)
    }
}
