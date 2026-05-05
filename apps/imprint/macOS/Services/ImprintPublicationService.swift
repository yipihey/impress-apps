//
//  ImprintPublicationService.swift
//  imprint
//
//  Reads imbib's publication database directly via the shared Rust FFI.
//  No HTTP. No process switch. Works offline.
//
//  Both imbib and imprint open the same SQLite file at
//  group.com.impress.suite/workspace/impress.sqlite via ImbibStore.
//  SQLite WAL mode natively supports concurrent readers; imbib's writes
//  are visible to imprint on the next query.
//

import Foundation
import ImbibRustCore
import ImpressKit
import ImpressLogging
import ImpressPublicationUI
import OSLog

/// Shared-database publication access for imprint.
///
/// This replaces the HTTP-based `ImbibIntegrationService` paths for lookups.
/// Readers return `BibliographyRow` and `PublicationDetail` — the same typed
/// values imbib uses internally.
///
/// Usage:
/// ```
/// if let row = ImprintPublicationService.shared.findByCiteKey("desjacques18") {
///     print(row.title)
/// }
/// ```
@MainActor
@Observable
public final class ImprintPublicationService: PublicationDataSource {

    public static let shared = ImprintPublicationService()

    /// The underlying Rust store. `nil` until `start()` succeeds (e.g. if the
    /// shared workspace is unavailable in an unsandboxed dev build).
    private var store: ImbibStore?

    /// Whether the store was opened successfully.
    public private(set) var isReady: Bool = false

    /// Bumped when a cross-process change is observed, so SwiftUI views can react.
    public private(set) var dataVersion: Int = 0

    /// Cite-key → row cache, invalidated on cross-process mutation.
    /// Avoids re-hitting SQLite for the same keys during a render pass.
    private var citeKeyCache: [String: BibliographyRow] = [:]

    /// Darwin notification observer token.
    private var storeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// Open the shared Rust store. Safe to call multiple times.
    /// Call from app startup (e.g. `ImprintAppDelegate.applicationDidFinishLaunching`).
    public func start() {
        guard store == nil else { return }

        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databasePath
            let s = try ImbibStore.open(path: path)
            self.store = s
            self.isReady = true
            logInfo("ImprintPublicationService started at \(path)", category: "publications")


            // Subscribe to cross-process store mutations from imbib.
            // When imbib posts `.storeDidMutate`, invalidate caches and bump version.
            storeObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("storeDidMutate"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.invalidateCaches()
                }
            }
        } catch {
            logInfo("ImprintPublicationService failed to open store: \(error)", category: "publications")
            self.isReady = false
        }
    }

    /// Invalidate internal caches and bump the data version so views re-render.
    public func invalidateCaches() {
        citeKeyCache.removeAll(keepingCapacity: true)
        dataVersion &+= 1
    }

    // MARK: - Read API

    /// Look up a publication by cite key. Cached per call to avoid redundant FFI.
    /// Returns nil if not found or the store is unavailable.
    public func findByCiteKey(_ citeKey: String) -> BibliographyRow? {
        guard let store else { return nil }
        if let cached = citeKeyCache[citeKey] { return cached }
        do {
            if let row = try store.findByCiteKey(citeKey: citeKey, libraryId: nil) {
                citeKeyCache[citeKey] = row
                return row
            }
        } catch {
            logInfo("findByCiteKey('\(citeKey)') failed: \(error)", category: "publications")
        }
        return nil
    }

    /// Find a publication by DOI. Returns the first hit — imbib allows the
    /// same DOI across libraries, so the caller may still want to disambiguate.
    public func findByDOI(_ doi: String) -> BibliographyRow? {
        guard let store else { return nil }
        do {
            return try store.findByDoi(doi: doi).first
        } catch {
            logInfo("findByDOI('\(doi)') failed: \(error)", category: "publications")
            return nil
        }
    }

    /// Find a publication by arXiv identifier.
    public func findByArxiv(_ arxivId: String) -> BibliographyRow? {
        guard let store else { return nil }
        do {
            return try store.findByArxiv(arxivId: arxivId).first
        } catch {
            logInfo("findByArxiv('\(arxivId)') failed: \(error)", category: "publications")
            return nil
        }
    }

    /// Find a publication by ADS bibcode.
    public func findByBibcode(_ bibcode: String) -> BibliographyRow? {
        guard let store else { return nil }
        do {
            return try store.findByBibcode(bibcode: bibcode).first
        } catch {
            logInfo("findByBibcode('\(bibcode)') failed: \(error)", category: "publications")
            return nil
        }
    }

    /// Multi-term search across title/authors/abstract/note.
    ///
    /// The underlying `store.searchPublications` does a single-substring
    /// `Contains` match. To support multi-word queries like "Abel Banerjee"
    /// or "halo bias expansion", we split the query into whitespace-separated
    /// terms and intersect results — one paper must match ALL terms somewhere
    /// in its searchable fields.
    ///
    /// Single-term queries fall through to a direct substring search. This
    /// is the same behavior pattern imbib's Cmd+F uses.
    public func search(_ query: String, limit: Int = 50) -> [BibliographyRow] {
        guard let store else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let terms = trimmed
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Single-term: direct call
        if terms.count == 1 {
            return performSingleTermSearch(store: store, term: terms[0], limit: limit)
        }

        // Multi-term: run one search per term (fetching a larger pool so the
        // intersection still has enough hits), then intersect by publication id.
        let pool = limit * 5
        var perTermResults: [[BibliographyRow]] = []
        for term in terms {
            let hits = performSingleTermSearch(store: store, term: term, limit: pool)
            if hits.isEmpty {
                // Short-circuit: if any term has no matches, the intersection is empty
                return []
            }
            perTermResults.append(hits)
        }
        // Use the smallest result set as the base for intersection
        guard var base = perTermResults.min(by: { $0.count < $1.count }) else { return [] }
        let otherIDSets = perTermResults
            .filter { $0.count != base.count }
            .map { Set($0.map(\.id)) }
        if !otherIDSets.isEmpty {
            base = base.filter { row in
                otherIDSets.allSatisfy { $0.contains(row.id) }
            }
        }
        return Array(base.prefix(limit))
    }

    /// Single-substring search across title/authors/abstract/note via the store.
    private func performSingleTermSearch(store: ImbibStore, term: String, limit: Int) -> [BibliographyRow] {
        do {
            return try store.searchPublications(
                query: term,
                parentId: nil,
                sortField: "date_modified",
                ascending: false,
                limit: UInt32(limit),
                offset: 0
            )
        } catch {
            logInfo("searchPublications('\(term)') failed: \(error)", category: "publications")
            return []
        }
    }

    /// Legacy alias — kept so other call sites don't break.
    public func fullTextSearch(_ query: String, limit: Int = 50) -> [BibliographyRow] {
        search(query, limit: limit)
    }

    /// Legacy alias — kept so other call sites don't break.
    public func searchPublications(_ query: String, limit: Int = 30) -> [BibliographyRow] {
        search(query, limit: limit)
    }

    /// Enumerate all publications across all libraries. Used for full-text index build.
    public func allBibliographyRows() -> [BibliographyRow] {
        guard let store else { return [] }
        var all: [BibliographyRow] = []
        do {
            let libs = try store.listLibraries()
            for lib in libs {
                let rows = try store.queryPublications(
                    parentId: lib.id,
                    sortField: "date_modified",
                    ascending: false,
                    limit: 5000,
                    offset: 0
                )
                all.append(contentsOf: rows)
            }
        } catch {
            logInfo("allBibliographyRows failed: \(error)", category: "publications")
        }
        // Deduplicate by id (a publication may appear in multiple libraries)
        var seen = Set<String>()
        return all.filter { row in
            if seen.contains(row.id) { return false }
            seen.insert(row.id)
            return true
        }
    }

    /// Get full publication details (all fields, abstract, raw BibTeX, linked files).
    public func detail(id: String) -> PublicationDetail? {
        guard let store else { return nil }
        do {
            return try store.getPublicationDetail(id: id)
        } catch {
            logInfo("detail('\(id)') failed: \(error)", category: "publications")
            return nil
        }
    }

    // MARK: - Write API

    /// Update a single field on a publication (notes, tags, etc.).
    /// Writes propagate to imbib on its next read (WAL).
    public func updateField(publicationID: String, field: String, value: String?) throws {
        guard let store else { throw PublicationServiceError.storeUnavailable }
        _ = try store.updateField(id: publicationID, field: field, value: value)
        invalidateCaches()
        // Post storeDidMutate so imbib picks up the change immediately.
        NotificationCenter.default.post(name: NSNotification.Name("storeDidMutate"), object: nil)
    }

    /// Convenience: update the `note` field on a publication.
    public func updateNote(publicationID: String, note: String) throws {
        try updateField(publicationID: publicationID, field: "note", value: note)
    }

    /// Create a new library. Returns the library UUID.
    public func createLibrary(name: String) throws -> String {
        guard let store else { throw PublicationServiceError.storeUnavailable }
        let lib = try store.createLibrary(name: name)
        invalidateCaches()
        NotificationCenter.default.post(name: NSNotification.Name("storeDidMutate"), object: nil)
        return lib.id
    }

    /// Add one or more publications to a library (imbib treats libraries as collections).
    public func addPublicationsToLibrary(libraryID: String, publicationIDs: [String]) throws {
        guard let store else { throw PublicationServiceError.storeUnavailable }
        _ = try store.addToCollection(publicationIds: publicationIDs, collectionId: libraryID)
        invalidateCaches()
        NotificationCenter.default.post(name: NSNotification.Name("storeDidMutate"), object: nil)
    }

    // No explicit deinit — singleton lives for app lifetime; the observer is cleaned up
    // automatically when the process exits. Trying to access @MainActor-isolated state
    // from deinit requires nonisolated capture which adds noise for no benefit here.
}

public enum PublicationServiceError: LocalizedError {
    case storeUnavailable

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable: return "Shared publication store is unavailable"
        }
    }
}
