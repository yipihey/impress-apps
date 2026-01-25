//
//  RustIdentifierResolver.swift
//  PublicationManagerCore
//
//  Identifier resolution backed by the Rust imbib-core library.
//  Maps identifiers between different systems (DOI→S2, arXiv→DOI).
//

import Foundation
import ImbibRustCore

// MARK: - Rust Identifier Resolver

/// Identifier resolution using the Rust imbib-core library.
public enum RustIdentifierResolver {

    /// Get the URL prefix for an identifier type
    public static func urlPrefix(for type: IdentifierType) -> String? {
        identifierUrlPrefix(idType: convertToRust(type))
    }

    /// Create a URL from an identifier type and value
    public static func url(for type: IdentifierType, value: String) -> URL? {
        guard let urlString = identifierUrl(idType: convertToRust(type), value: value) else {
            return nil
        }
        return URL(string: urlString)
    }

    /// Get the display name for an identifier type
    public static func displayName(for type: IdentifierType) -> String {
        identifierDisplayName(idType: convertToRust(type))
    }

    /// Check if we can resolve identifiers to a specific enrichment source
    public static func canResolve(
        _ identifiers: [IdentifierType: String],
        to source: EnrichmentSource
    ) -> Bool {
        let idMap = identifiers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }
        return canResolveToSource(identifiers: idMap, source: convertSourceToRust(source))
    }

    /// Get the preferred identifier for a specific source
    public static func preferredIdentifier(
        from identifiers: [IdentifierType: String],
        for source: EnrichmentSource
    ) -> (type: IdentifierType, value: String)? {
        let idMap = identifiers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.rawValue] = pair.value
        }

        guard let result = preferredIdentifierForSource(identifiers: idMap, source: convertSourceToRust(source)) else {
            return nil
        }

        guard let idType = IdentifierType(rawValue: result.idType) else {
            return nil
        }

        return (idType, result.value)
    }

    /// Get all identifier types that can resolve to a source
    public static func supportedIdentifiers(for source: EnrichmentSource) -> [IdentifierType] {
        supportedIdentifiersForSource(source: convertSourceToRust(source))
            .compactMap { IdentifierType(rawValue: $0) }
    }

    /// Resolve DOI to Semantic Scholar paper ID format
    public static func resolveToSemanticScholar(doi: String) -> String {
        resolveDoiToSemanticScholar(doi: doi)
    }

    /// Resolve arXiv ID to Semantic Scholar paper ID format
    public static func resolveToSemanticScholar(arxivID: String) -> String {
        resolveArxivToSemanticScholar(arxivId: arxivID)
    }

    /// Resolve PubMed ID to Semantic Scholar paper ID format
    public static func resolveToSemanticScholar(pmid: String) -> String {
        resolvePmidToSemanticScholar(pmid: pmid)
    }

    // MARK: - Type Conversion

    private static func convertToRust(_ type: IdentifierType) -> ImbibRustCore.IdentifierType {
        switch type {
        case .doi: return .doi
        case .arxiv: return .arxiv
        case .pmid: return .pmid
        case .pmcid: return .pmcid
        case .bibcode: return .bibcode
        case .semanticScholar: return .semanticScholar
        case .openAlex: return .openAlex
        case .dblp: return .dblp
        }
    }

    private static func convertSourceToRust(_ source: EnrichmentSource) -> ImbibRustCore.EnrichmentSource {
        switch source {
        case .ads: return .ads
        case .wos: return .ads  // WoS is not in Rust core, fallback to ADS
        case .openalex: return .ads  // OpenAlex is not in Rust core, fallback to ADS
        }
    }
}

/// Information about Rust identifier resolver
public enum RustIdentifierResolverInfo {
    public static var isAvailable: Bool { true }
}
