// Persistence SEAM file — CROSS-PLATFORM (macOS + iOS).
//
//  WatchedFolderStoreAdapter.swift
//  PublicationManagerCore
//
//  ADR-0023 W2 — the Swift seam for the watched-folder store verbs.
//
//  ── What it is ──────────────────────────────────────────────────────────────
//
//  `CollectionStoreAdapter` for watched folders: the one file in Swift that
//  knows `SharedStore.watched*` exists. Everything above it — the ingest
//  coordinator, the sidebar, the provenance row in the Info tab — talks in
//  Swift values and never touches the FFI.
//
//  The verbs are the SAME EIGHT the CLI and MCP expose through
//  `DocsImportService`, over the same Rust kernel
//  (`impress_core::watched_folder_ops`). Two surfaces, one implementation —
//  which is why "watch this directory" said by an agent and said by the user
//  produce byte-identical rows.
//
//  ── The one rule ────────────────────────────────────────────────────────────
//
//  **Lowercase at the boundary.** `UUID().uuidString` is uppercase; the store's
//  canonical id form is lowercase and payload refs are matched by string
//  equality (imbib CLAUDE.md's invariant, and `CollectionStoreAdapter`'s rule
//  1). `WatchedFolderID.storageKey` already lowercases; every OTHER id crossing
//  this file — publication ids on their way into `recordProduced` — is
//  lowercased here.
//
//  ── What it deliberately does NOT do ────────────────────────────────────────
//
//  No undo registration. A watched folder's writes are index entries and
//  provenance, not user edits: there is nothing a user did that a ⌘Z should
//  invert, and the rows the files PRODUCED register their own undo through the
//  importer that made them. `CollectionStoreAdapter`'s rule 3 does not apply
//  here because rule 3's premise does not.
//

import Foundation
import ImpressKit
import ImpressRustCore
import OSLog

/// One watched folder, as Swift reads it back from the store.
///
/// A value mirror of `SharedWatchedFolder` so nothing above this file imports
/// `ImpressRustCore` — the same relationship `CollectionKernelRow` has to
/// `SharedCollectionRow`.
public struct WatchedFolderRecord: Equatable, Sendable, Identifiable {

    /// Lowercase UUID string. Derived by the kernel from `(path, kindScope)`,
    /// so it is stable across launches and across re-adds.
    public let id: String
    public let path: String
    /// The record kind whose declaration decides what counts —
    /// `FileDiscoveryFilter.id` on the Swift side.
    public let kindScope: String
    public let displayName: String
    public let isEnabled: Bool
    public let isRecursive: Bool
    /// The ADR-0023 D6 declaration the store holds: `indexed` / `unindexed` /
    /// `scan-on-demand` / `unavailable`, or nil when nothing has declared one.
    public let volumeState: String?
    public let bookmarkBase64: String?
    public let lastScanAt: String?
    public let lastScanFileCount: Int
    public let lastScanNewCount: Int
    public let lastScanChangedCount: Int
    public let lastScanMissingCount: Int
    public let lastScanDurationMS: Int

    init(_ row: SharedWatchedFolder) {
        self.id = row.id
        self.path = row.path
        self.kindScope = row.kindScope
        self.displayName = row.displayName
        self.isEnabled = row.enabled
        self.isRecursive = row.recursive
        self.volumeState = row.volumeState
        self.bookmarkBase64 = row.bookmarkBase64
        self.lastScanAt = row.lastScanAt
        self.lastScanFileCount = Int(row.lastScanFileCount)
        self.lastScanNewCount = Int(row.lastScanNewCount)
        self.lastScanChangedCount = Int(row.lastScanChangedCount)
        self.lastScanMissingCount = Int(row.lastScanMissingCount)
        self.lastScanDurationMS = Int(row.lastScanDurationMs)
    }
}

/// One discovered file's provenance row.
public struct WatchedFileRecord: Equatable, Sendable, Identifiable {

    public let id: String
    public let watchedFolderID: String
    public let path: String
    public let contentHash: String
    /// `present` | `missing`. A `missing` row is kept, flagged — never deleted.
    public let state: String
    public let kindScope: String
    public let sizeBytes: Int
    public let firstSeenAt: String?
    public let lastSeenAt: String?
    public let missingSince: String?
    /// Store rows this file produced, lowercase UUID strings.
    public let producedIDs: [String]
    public let producedAt: String?
    /// True when the file's content moved on after the last fan-out.
    public let needsReimport: Bool

    public var isMissing: Bool { state == "missing" }

    /// The produced ids as `UUID`s, dropping anything unparseable.
    public var producedPublicationIDs: [UUID] {
        producedIDs.compactMap { UUID(uuidString: $0) }
    }

    init(_ row: SharedWatchedFile) {
        self.id = row.id
        self.watchedFolderID = row.watchedFolderId
        self.path = row.path
        self.contentHash = row.contentHash
        self.state = row.state
        self.kindScope = row.kindScope
        self.sizeBytes = Int(row.sizeBytes)
        self.firstSeenAt = row.firstSeenAt
        self.lastSeenAt = row.lastSeenAt
        self.missingSince = row.missingSince
        self.producedIDs = row.producedIds
        self.producedAt = row.producedAt
        self.needsReimport = row.needsReimport
    }
}

/// What one discovery batch did (ADR-0023 D4).
public struct WatchedDiscoveryReport: Equatable, Sendable {

    /// `(fileID, path, action)` for every file acted on, in path order.
    /// `action` is `created` | `changed` | `unchanged` | `restored`.
    public struct Outcome: Equatable, Sendable {
        public let fileID: String
        public let path: String
        public let action: String
        public let contentHash: String

        /// Whether the app's importer must run on this file again.
        ///
        /// `unchanged` is the one that must not: the whole zero-write property
        /// of a settled re-scan is undone if the expensive half runs anyway.
        public var needsImport: Bool {
            action == "created" || action == "changed" || action == "restored"
        }
    }

    public let created: Int
    public let changed: Int
    public let unchanged: Int
    public let restored: Int
    public let batches: Int
    public let files: [Outcome]
    public let skipped: [(path: String, reason: String)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.created == rhs.created && lhs.changed == rhs.changed
            && lhs.unchanged == rhs.unchanged && lhs.restored == rhs.restored
            && lhs.batches == rhs.batches && lhs.files == rhs.files
            && lhs.skipped.map(\.path) == rhs.skipped.map(\.path)
    }

    /// Files whose importer pass is still owed.
    public var needingImport: [Outcome] { files.filter(\.needsImport) }

    init(_ report: SharedDiscoveryReport) {
        self.created = Int(report.created)
        self.changed = Int(report.changed)
        self.unchanged = Int(report.unchanged)
        self.restored = Int(report.restored)
        self.batches = Int(report.batches)
        self.files = report.files.map {
            Outcome(fileID: $0.id, path: $0.path, action: $0.action, contentHash: $0.contentHash)
        }
        self.skipped = report.skipped.map { (path: $0.path, reason: $0.reason) }
    }
}

/// What the terminal sweep of a scan found. Nothing here was deleted.
public struct WatchedScanReport: Equatable, Sendable {
    public let examined: Int
    public let present: Int
    public let markedMissing: Int
    public let missing: [WatchedFileRecord]
    public let folder: WatchedFolderRecord?

    init(_ report: SharedWatchedScanReport) {
        self.examined = Int(report.examined)
        self.present = Int(report.present)
        self.markedMissing = Int(report.markedMissing)
        self.missing = report.missing.map(WatchedFileRecord.init)
        self.folder = report.folder.map(WatchedFolderRecord.init)
    }
}

/// What attributing rows to a file changed.
public struct WatchedProducedReport: Equatable, Sendable {
    public let file: WatchedFileRecord
    public let added: Int
    /// Ids this file used to account for and no longer does — the entries the
    /// source dropped. **Nothing was deleted**; the disposition is the app's.
    public let removedIDs: [UUID]

    init(_ report: SharedProducedRowsReport) {
        self.file = WatchedFileRecord(report.file)
        self.added = Int(report.added)
        self.removedIDs = report.removedIds.compactMap { UUID(uuidString: $0) }
    }
}

// MARK: - Adapter

/// The eight watched-folder store verbs, for Swift.
///
/// `@MainActor` matching `CollectionStoreAdapter` and `FigureStoreReader`: the
/// UniFFI handle carries no Swift `Sendable` conformance, and every caller here
/// (the watch service, the sidebar, the detail pane) is already main-isolated.
/// The expensive work happens inside Rust, bounded by the D7 write gate.
@MainActor
public final class WatchedFolderStoreAdapter {

    public static let shared = WatchedFolderStoreAdapter()

    private static let logger = Logger(subsystem: "com.imbib.app", category: "watched-folders")

    private let store: SharedStore?

    /// imbib's adapter, on its own handle over the same database
    /// (`SharedWorkspace.databasePath`; WAL permits concurrent handles).
    private init() {
        var opened: SharedStore?
        do {
            // The same production-store guard `RustStoreAdapter.shared` and
            // `sharedReviewStore()` apply, and it is not optional here: a UI
            // test that watched a folder against the real app-group database
            // would write watched-folder and watched-file rows into the user's
            // library. `isUnitTestProcess` alone is not enough — the APP
            // process under XCUITest sets neither `XCTestConfigurationFilePath`
            // nor an XCTest class, only `--ui-testing`.
            if UITestingEnvironment.isUITesting {
                // The same file `RustStoreAdapter` opens under UI testing.
                // Attribution is a cross-handle claim — the kernel refuses to
                // record provenance for rows it cannot see — so these two MUST
                // be one database, exactly as they are in production.
                UITestingEnvironment.prepareScratchDatabaseDirectory()
                opened = try SharedStore.open(
                    path: UITestingEnvironment.scratchDatabasePath)
            } else if ImpressRuntime.isUnitTestProcess {
                opened = try SharedStore.openInMemory()
            } else {
                try SharedWorkspace.ensureDirectoryExists()
                opened = try SharedStore.open(path: SharedWorkspace.databasePath)
            }
        } catch {
            Self.logger.error("WatchedFolderStoreAdapter failed to open shared store: \(error)")
        }
        self.store = opened
    }

    /// A test's adapter, on a scratch store. `SharedStore.openInMemory()` is
    /// the shape every test here uses; nothing touches the user's database.
    public init(store: SharedStore?) {
        self.store = store
    }

    public var isReady: Bool { store != nil }

    private func requireStore() throws -> SharedStore {
        guard let store else { throw WatchedFolderStoreError.unavailable }
        return store
    }

    // MARK: Folders

    /// Start watching a directory for one record kind. Idempotent: the id is
    /// derived from `(path, kindScope)`, so a re-add returns the existing row
    /// with `created == false` and swaps in a fresh bookmark if one is given.
    @discardableResult
    public func addFolder(
        path: String,
        kindScope: String,
        displayName: String? = nil,
        bookmarkBase64: String? = nil,
        recursive: Bool = true
    ) throws -> (folder: WatchedFolderRecord, created: Bool) {
        let outcome = try requireStore().watchedFolderAdd(
            path: path,
            kindScope: kindScope,
            displayName: displayName,
            bookmarkBase64: bookmarkBase64,
            recursive: recursive)
        let record = WatchedFolderRecord(outcome.folder)
        Self.logger.infoCapture(
            "watched folder \(record.id): \(outcome.created ? "added" : "already watching") "
                + "\(record.path) for \(record.kindScope)",
            category: "watched-folders")
        return (record, outcome.created)
    }

    public func folders(kindScope: String? = nil) throws -> [WatchedFolderRecord] {
        try requireStore().watchedFolderList(kindScope: kindScope).map(WatchedFolderRecord.init)
    }

    public func folder(id: String) throws -> WatchedFolderRecord? {
        try folders().first { $0.id == id.lowercased() }
    }

    /// Change one folder's mutable facets. `nil` leaves a field alone.
    @discardableResult
    public func updateFolder(
        id: String,
        isEnabled: Bool? = nil,
        isRecursive: Bool? = nil,
        displayName: String? = nil,
        bookmarkBase64: String? = nil,
        volumeState: String? = nil
    ) throws -> WatchedFolderRecord {
        WatchedFolderRecord(
            try requireStore().watchedFolderUpdate(
                id: id.lowercased(),
                enabled: isEnabled,
                recursive: isRecursive,
                displayName: displayName,
                bookmarkBase64: bookmarkBase64,
                volumeState: volumeState))
    }

    /// Stop watching. Touches no file on disk, and leaves every publication the
    /// folder's files produced exactly where it is.
    @discardableResult
    public func removeFolder(
        id: String, deleteFileRows: Bool = false
    ) throws -> (removed: Bool, fileRowsDeleted: Int) {
        let outcome = try requireStore().watchedFolderRemove(
            id: id.lowercased(), deleteFileRows: deleteFileRows)
        return (outcome.removed, Int(outcome.fileRowsDeleted))
    }

    // MARK: Discovery

    /// Record a batch of discovered files. Paths whose content hash has not
    /// moved write nothing at all.
    @discardableResult
    public func importDiscovered(
        folderID: String, paths: [String], dryRun: Bool = false
    ) throws -> WatchedDiscoveryReport {
        let files = paths.map {
            // The hash/mtime/size are left nil: the kernel reads them off disk,
            // and a Swift-side hash would be a second implementation of the
            // thing W0 already fixed a lossy-UTF8 bug in.
            SharedDiscoveredFile(
                path: $0, contentHash: nil, mtime: nil, sizeBytes: nil, bookmarkBase64: nil)
        }
        return WatchedDiscoveryReport(
            try requireStore().watchedImportDiscovered(
                watchedFolderId: folderID.lowercased(), files: files, dryRun: dryRun))
    }

    /// Close a scan: mark what vanished, write the folder's stats.
    ///
    /// Throws when the folder's own root is unreachable — the store declares
    /// the volume `unavailable` on the way out, so the row stays honest rather
    /// than reporting a library that just went missing all at once.
    @discardableResult
    public func finishScan(
        folderID: String,
        newCount: Int? = nil,
        changedCount: Int? = nil,
        durationMS: Int? = nil,
        dryRun: Bool = false
    ) throws -> WatchedScanReport {
        WatchedScanReport(
            try requireStore().watchedFinishScan(
                watchedFolderId: folderID.lowercased(),
                newCount: newCount.map(Int64.init),
                changedCount: changedCount.map(Int64.init),
                durationMs: durationMS.map(Int64.init),
                dryRun: dryRun))
    }

    /// Attribute the rows one file produced.
    ///
    /// Pass everything the file accounts for — including ids that deduped onto
    /// papers already in the library. An omitted id is reported as orphaned,
    /// and "the source dropped this entry" is exactly the claim that must not
    /// be made by accident.
    @discardableResult
    public func recordProduced(
        fileID: String, publicationIDs: [UUID], replace: Bool = true
    ) throws -> WatchedProducedReport {
        WatchedProducedReport(
            try requireStore().watchedRecordProduced(
                fileId: fileID.lowercased(),
                producedIds: publicationIDs.map { $0.uuidString.lowercased() },
                replace: replace))
    }

    // MARK: Provenance

    /// One folder's files, newest page first. `state` narrows to `present` or
    /// `missing`.
    public func files(
        folderID: String, state: String? = nil, limit: Int = 0, offset: Int = 0
    ) throws -> (files: [WatchedFileRecord], total: Int) {
        let page = try requireStore().watchedFilesList(
            watchedFolderId: folderID.lowercased(),
            fileId: nil,
            state: state,
            limit: Int64(limit),
            offset: Int64(offset))
        return (page.files.map(WatchedFileRecord.init), Int(page.total))
    }

    /// One file's row, by id.
    public func file(id: String) throws -> WatchedFileRecord? {
        try requireStore().watchedFilesList(
            watchedFolderId: nil, fileId: id.lowercased(), state: nil, limit: 1, offset: 0
        ).files.first.map(WatchedFileRecord.init)
    }
}

/// Why a watched-folder store verb could not run.
public enum WatchedFolderStoreError: Error, LocalizedError {

    /// The shared store never opened. Distinct from "the verb failed": the app
    /// has no database at all, and no watched-folder surface should be shown.
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The shared library database is not available."
        }
    }
}
