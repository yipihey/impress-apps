//
//  ImbibCitationSearchService.swift
//  PublicationManagerCore
//
//  imbib's implementation of the manuscript editor's citation seam.
//
//  imprint installs its app-target ImprintPublicationService; imbib never
//  installed anything, so the shared @-trigger citation palette showed "no
//  matches" and the compile-time bibliography had nothing to resolve keys
//  against. This wraps the adapter's ImbibStore handle directly (the FFI
//  returns the BibliographyRow shape the citation UI renders) and is
//  cross-platform — the iOS citation picker uses the same instance.
//

import Foundation
import ImbibRustCore
import OSLog

/// Citation lookup + search over the imbib store for the manuscript editor.
///
/// Install once at launch:
/// `ManuscriptEditorEnvironment.shared.citationSearch = ImbibCitationSearchService.shared`
@MainActor
public final class ImbibCitationSearchService: ManuscriptCitationSearching {

    public static let shared = ImbibCitationSearchService()

    private init() {}

    private var store: ImbibStore { RustStoreAdapter.shared.imbibStore }

    /// Per-session cite-key cache; invalidated on store mutation via dataVersion.
    private var citeKeyCache: [String: BibliographyRow] = [:]
    private var cachedAtVersion: Int = -1

    private func validateCache() {
        let version = RustStoreAdapter.shared.dataVersion
        if version != cachedAtVersion {
            citeKeyCache.removeAll(keepingCapacity: true)
            cachedAtVersion = version
        }
    }

    public func findByCiteKey(_ citeKey: String) -> BibliographyRow? {
        validateCache()
        if let cached = citeKeyCache[citeKey] { return cached }
        do {
            if let row = try store.findByCiteKey(citeKey: citeKey, libraryId: nil) {
                citeKeyCache[citeKey] = row
                return row
            }
        } catch {
            Logger.library.error("citationSearch findByCiteKey('\(citeKey)') failed: \(error)")
        }
        return nil
    }

    /// Multi-term search: split on whitespace, intersect per-term results by
    /// id so "abel banerjee" matches a paper containing both terms anywhere
    /// in its searchable fields (same pattern as imprint's service).
    public func search(_ query: String, limit: Int) -> [BibliographyRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let terms = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        if terms.count == 1 {
            return singleTermSearch(terms[0], limit: limit)
        }

        let pool = limit * 5
        var intersection: [BibliographyRow]?
        for term in terms {
            let hits = singleTermSearch(term, limit: pool)
            if hits.isEmpty { return [] }
            if let current = intersection {
                let ids = Set(hits.map(\.id))
                intersection = current.filter { ids.contains($0.id) }
                if intersection?.isEmpty == true { return [] }
            } else {
                intersection = hits
            }
        }
        return Array((intersection ?? []).prefix(limit))
    }

    /// Store-backed BibTeX export for the compile-time virtual bibliography.
    /// Rust owns BibTeX round-trip fidelity — never assemble entries in Swift.
    public func bibliography(forKeys keys: [String]) -> String? {
        let ids = keys.compactMap { findByCiteKey($0)?.id }
        guard !ids.isEmpty else { return nil }
        do {
            let bibtex = try store.exportBibtex(ids: ids)
            return bibtex.isEmpty ? nil : bibtex
        } catch {
            Logger.library.error("citationSearch bibliography export failed: \(error)")
            return nil
        }
    }

    private func singleTermSearch(_ term: String, limit: Int) -> [BibliographyRow] {
        do {
            return try store.searchPublications(
                query: term,
                parentId: nil,
                sortField: "dateAdded",
                ascending: false,
                limit: UInt32(limit),
                offset: nil
            )
        } catch {
            Logger.library.error("citationSearch search('\(term)') failed: \(error)")
            return []
        }
    }
}
