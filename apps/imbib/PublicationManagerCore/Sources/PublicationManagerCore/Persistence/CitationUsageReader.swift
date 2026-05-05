//
//  CitationUsageReader.swift
//  PublicationManagerCore
//
//  Reads `citation-usage@1.0.0` records from the shared impress-core
//  SQLite store and exposes them to imbib.
//
//  The records are written by imprint's `CitationUsageTracker` whenever
//  the user edits a manuscript. Imbib consumes them to surface a
//  "Cited in Manuscripts" sidebar entry — every publication that
//  appears in any manuscript shows up there, updated on demand.
//
//  Why a separate SharedStore handle:
//  Imbib's `ImbibStore` (via ImbibRustCore) only exposes publication-
//  typed operations; it has no `queryBySchema`. The shared impress-core
//  database accepts multiple concurrent readers via WAL mode, so we
//  open a second Swift handle here against the same SQLite file.
//

import Foundation
import ImpressKit
import ImpressLogging
import ImpressRustCore
import ImpressStoreKit
import OSLog

private let readerLog = Logger(subsystem: "com.imbib.app", category: "citation-usage-reader")

/// Actor that owns a `SharedStore` handle pointed at the shared
/// impress-core database and serves read-only queries for
/// `citation-usage@1.0.0` records.
public actor CitationUsageReader {

    public static let shared = CitationUsageReader()

    /// The underlying impress-core store handle. Opened lazily on first
    /// access and reused for every subsequent query. `nil` means the
    /// shared workspace is unavailable — all queries return empty in
    /// that state so callers don't have to special-case missing data.
    private var store: SharedStore?
    private var openAttempted = false

    public init() {}

    // MARK: - Read API

    /// List every citation-usage record in the store.
    public func listAll(limit: UInt32 = 5000, offset: UInt32 = 0) -> [CitationUsageRecord] {
        StoreTimings.shared.measure("CitationUsageReader.listAll") {
            guard let store = handle() else { return [] }
            do {
                let rows = try store.queryBySchema(
                    schemaRef: "citation-usage@1.0.0",
                    limit: limit,
                    offset: offset
                )
                return rows.compactMap { CitationUsageRecord(row: $0) }
            } catch {
                readerLog.errorCapture(
                    "CitationUsageReader.listAll failed: \(error.localizedDescription)",
                    category: "citation-usage-reader"
                )
                return []
            }
        }
    }

    /// Distinct imbib publication IDs that appear in at least one
    /// citation-usage record. Used by the sidebar smart-library.
    public func citedPaperIDs() -> Set<UUID> {
        var ids: Set<UUID> = []
        for record in listAll() {
            if let paperID = record.paperID {
                ids.insert(paperID)
            }
        }
        return ids
    }

    /// Records that resolve to a specific publication. One publication
    /// may be cited from many sections across many manuscripts, so this
    /// returns an array.
    public func recordsForPaper(id: UUID) -> [CitationUsageRecord] {
        listAll().filter { $0.paperID == id }
    }

    /// Records for cite keys that haven't been resolved to a publication
    /// yet. Useful for a "needs import" view.
    public func unresolvedRecords() -> [CitationUsageRecord] {
        listAll().filter { $0.paperID == nil }
    }

    // MARK: - Internals

    private func handle() -> SharedStore? {
        if let store { return store }
        if openAttempted { return nil }
        openAttempted = true
        do {
            try SharedWorkspace.ensureDirectoryExists()
            let path = SharedWorkspace.databaseURL.path
            let s = try SharedStore.open(path: path)
            self.store = s
            readerLog.infoCapture(
                "CitationUsageReader opened SharedStore at \(path)",
                category: "citation-usage-reader"
            )
            return s
        } catch {
            readerLog.warningCapture(
                "CitationUsageReader could not open SharedStore: \(error.localizedDescription)",
                category: "citation-usage-reader"
            )
            return nil
        }
    }
}
