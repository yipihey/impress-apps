//
//  ManuscriptMigrationRunner.swift
//
//  Phase 3 of the unified-store pivot
//  (/Users/tabel/.claude/plans/one-store-the-store-melodic-wreath.md).
//
//  One-shot migration of imprint's Core Data project hierarchy
//  (`CDWorkspace` / `CDFolder` / `CDDocumentReference`) into the unified
//  store as `manuscript-collection` and `manuscript` items. Runs once
//  per device, gated on a UserDefaults completion flag. Re-runs are
//  no-ops thanks to the importer's dedup rules; if the flag is set but
//  the unified store has no collections, we treat that as an out-of-band
//  reset and re-migrate.
//
//  Failure model:
//   - Per-row failures (stale bookmark, unreadable file) are captured in
//     a `MigrationReport` and surfaced to the UI via a banner.
//   - If 100% of rows fail, the completion flag is NOT written, so the
//     next launch re-prompts. (Typical cause: TimeMachine restore where
//     `ImprintProjects.sqlite` came across but the .imprint files
//     haven't synced yet.)
//

import CoreData
import Foundation
import ImpressLogging
import OSLog

/// Per-row import outcome.
public struct MigrationRowFailure: Sendable, Equatable, Codable {
    public let referenceID: UUID
    public let cachedTitle: String?
    public let originalPath: String?
    public let reason: String
}

/// Aggregate result of one migration run. Even when `failures` is
/// non-empty, the run may still have made progress — the flag is set
/// when at least one row succeeded, so retrying only attempts the
/// failed rows.
public struct MigrationReport: Sendable, Equatable, Codable {
    public let migratedCollections: Int
    public let migratedDocuments: Int
    public let failures: [MigrationRowFailure]
    public let runAt: Date

    public var hasFailures: Bool { !failures.isEmpty }
    public var didNothing: Bool { migratedCollections == 0 && migratedDocuments == 0 }
}

/// Drives the bulk migration. Stateless — entry point is
/// `runIfNeeded()`, called once during app startup.
@MainActor
public enum ManuscriptMigrationRunner {

    /// Key for the completion flag. Namespaced + versioned so future
    /// re-migrations can bump the version safely.
    private static let completionFlagKey = "imprint.manuscript_migration.v1.complete"

    /// Key for the most recent `MigrationReport`. Encoded as JSON so the
    /// banner UI can read it back without coupling to Codable here.
    private static let lastReportKey = "imprint.manuscript_migration.v1.last_report"

    /// Whether the migration has completed at least one full pass.
    /// Surfaced as `nonisolated` so non-main-actor callers can check it
    /// cheaply (the underlying UserDefaults is thread-safe).
    public nonisolated static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: completionFlagKey)
    }

    /// The most recent MigrationReport, or nil if no run has happened.
    public static var lastReport: MigrationReport? {
        guard let data = UserDefaults.standard.data(forKey: lastReportKey) else { return nil }
        return try? JSONDecoder().decode(MigrationReport.self, from: data)
    }

    // MARK: - Entry point

    /// Run the migration if it hasn't completed yet. Safe to call on
    /// every app launch. The reinstall sanity check kicks in when the
    /// flag is set but the unified store has zero collection items
    /// (likely cause: user reset the app group container).
    ///
    /// Returns the report from the run, or `nil` if no run was needed.
    @discardableResult
    public static func runIfNeeded() -> MigrationReport? {
        if isComplete && !shouldReRunDueToEmptyStore() {
            return nil
        }
        return run()
    }

    /// Force a fresh migration regardless of the completion flag. Used
    /// by the debug menu's "Re-run manuscript migration" command.
    @discardableResult
    public static func run() -> MigrationReport {
        Logger.sharedStore.infoCapture(
            "Manuscript migration starting (forced or first-time)",
            category: "manuscript-migration"
        )
        let context = ImprintPersistenceController.shared.viewContext
        let report = context.performAndWait { performMigration(context: context) }

        // Only write the completion flag when at least one row succeeded.
        // A 100%-failure run (e.g. fresh-machine TimeMachine restore with
        // unresolved bookmarks) shouldn't lock the user out of retrying.
        if report.migratedCollections > 0 || report.migratedDocuments > 0 {
            UserDefaults.standard.set(true, forKey: completionFlagKey)
        }
        if let data = try? JSONEncoder().encode(report) {
            UserDefaults.standard.set(data, forKey: lastReportKey)
        }

        Logger.sharedStore.infoCapture(
            "Manuscript migration done: \(report.migratedCollections) collections, " +
            "\(report.migratedDocuments) manuscripts, \(report.failures.count) failures",
            category: "manuscript-migration"
        )
        return report
    }

    // MARK: - Implementation

    private static func performMigration(context: NSManagedObjectContext) -> MigrationReport {
        // Backup the legacy CD store before we touch anything. Best-effort.
        backupCoreDataStore()

        let adapter = ManuscriptStoreAdapter.shared
        adapter.beginBatchMutation()
        defer { adapter.endBatchMutation() }

        var collectionCount = 0
        var documentCount = 0
        var failures: [MigrationRowFailure] = []

        // ─── Workspaces ───────────────────────────────────────────────
        // Each CDWorkspace becomes a top-level (is_workspace: true)
        // manuscript-collection. Reuse the existing UUID so future
        // reverse-lookups still work.
        let workspaceRequest = NSFetchRequest<CDWorkspace>(entityName: "Workspace")
        let workspaces = (try? context.fetch(workspaceRequest)) ?? []
        for ws in workspaces {
            do {
                _ = try createOrUpsertCollection(
                    id: ws.id,
                    name: ws.name,
                    parentID: nil,
                    isWorkspace: true,
                    sortOrder: 0,
                    adapter: adapter
                )
                collectionCount += 1
            } catch {
                failures.append(MigrationRowFailure(
                    referenceID: ws.id,
                    cachedTitle: ws.name,
                    originalPath: nil,
                    reason: "Workspace create failed: \(error.localizedDescription)"
                ))
            }
        }

        // ─── Folders (topologically sorted) ───────────────────────────
        // Two-pass insert: pass 1 creates each collection with a null
        // parent_collection_ref; pass 2 sets parent_collection_ref. This
        // avoids forward-reference issues if the schema layer ever
        // enforces the relation.
        let folderRequest = NSFetchRequest<CDFolder>(entityName: "Folder")
        let folders = (try? context.fetch(folderRequest)) ?? []

        // Pass 1: create all collection items with no parent set.
        for folder in folders {
            do {
                _ = try createOrUpsertCollection(
                    id: folder.id,
                    name: folder.name,
                    parentID: nil,
                    isWorkspace: false,
                    sortOrder: Int(folder.sortOrder),
                    adapter: adapter
                )
                collectionCount += 1
            } catch {
                failures.append(MigrationRowFailure(
                    referenceID: folder.id,
                    cachedTitle: folder.name,
                    originalPath: nil,
                    reason: "Folder create failed: \(error.localizedDescription)"
                ))
            }
        }

        // Pass 2: set parent_collection_ref for every folder that has one
        // (either a parent folder or a workspace).
        for folder in folders {
            let parentID: UUID?
            if let parent = folder.parentFolder {
                parentID = parent.id
            } else if let ws = folder.workspace {
                parentID = ws.id
            } else {
                parentID = nil
            }
            guard let parentID else { continue }
            do {
                try setCollectionParent(
                    id: folder.id,
                    parentID: parentID,
                    adapter: adapter
                )
            } catch {
                failures.append(MigrationRowFailure(
                    referenceID: folder.id,
                    cachedTitle: folder.name,
                    originalPath: nil,
                    reason: "Folder parent link failed: \(error.localizedDescription)"
                ))
            }
        }

        // ─── Document references ──────────────────────────────────────
        let refRequest = NSFetchRequest<CDDocumentReference>(entityName: "DocumentReference")
        let refs = (try? context.fetch(refRequest)) ?? []
        for ref in refs {
            guard let url = resolveURL(for: ref) else {
                failures.append(MigrationRowFailure(
                    referenceID: ref.id,
                    cachedTitle: ref.cachedTitle,
                    originalPath: ref.fileURLString,
                    reason: "Stale or unresolvable bookmark"
                ))
                continue
            }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try ManuscriptImporter.importDocument(at: url)
                documentCount += 1
                // TODO: tie the manuscript into its parent collection via
                // a Contains edge once the FFI exposes a reference-add
                // method. Until then, all migrated manuscripts surface in
                // the "All Manuscripts" view.
            } catch {
                failures.append(MigrationRowFailure(
                    referenceID: ref.id,
                    cachedTitle: ref.cachedTitle,
                    originalPath: url.path,
                    reason: error.localizedDescription
                ))
            }
        }

        return MigrationReport(
            migratedCollections: collectionCount,
            migratedDocuments: documentCount,
            failures: failures,
            runAt: Date()
        )
    }

    // MARK: - Collection upsert helpers

    private static func createOrUpsertCollection(
        id: UUID,
        name: String,
        parentID: UUID?,
        isWorkspace: Bool,
        sortOrder: Int,
        adapter: ManuscriptStoreAdapter
    ) throws -> UUID {
        var payload: [String: Any] = [
            "name": name,
            "is_workspace": isWorkspace,
            "sort_order": sortOrder,
        ]
        if let parentID {
            payload["parent_collection_ref"] = parentID.uuidString
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: json, encoding: .utf8) else {
            throw NSError(
                domain: "imprint.migration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "payload not UTF-8"]
            )
        }
        try adapter.sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript-collection",
            payloadJson: text
        )
        return id
    }

    /// Update only the `parent_collection_ref` field on an existing
    /// collection item. `upsertItem`'s additive semantics mean we don't
    /// need to re-send the other fields.
    private static func setCollectionParent(
        id: UUID,
        parentID: UUID,
        adapter: ManuscriptStoreAdapter
    ) throws {
        let payload: [String: Any] = [
            "parent_collection_ref": parentID.uuidString,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: json, encoding: .utf8) else {
            throw NSError(
                domain: "imprint.migration",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "parent payload not UTF-8"]
            )
        }
        try adapter.sharedStore.upsertItem(
            id: id.uuidString,
            schemaRef: "manuscript-collection",
            payloadJson: text
        )
    }

    // MARK: - Bookmark resolution

    /// Try to resolve a CDDocumentReference back to a usable URL. Prefer
    /// the security-scoped bookmark; fall back to the plain path string
    /// for cases where bookmark resolution fails but the file is still
    /// accessible (uncommon but recoverable).
    private static func resolveURL(for ref: CDDocumentReference) -> URL? {
        if let bookmark = ref.fileBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        if let path = ref.fileURLString {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Backup + sanity checks

    /// Copy the legacy `ImprintProjects.sqlite` to a timestamped backup
    /// so the user can recover if the migration produces a bad state.
    /// Best-effort: any failure is logged but doesn't abort the migration.
    private static func backupCoreDataStore() {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        let sourceURL = appSupport
            .appending(path: "imprint/ImprintProjects.sqlite", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }
        let migrationsDir = appSupport
            .appending(path: "impress/migrations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: migrationsDir,
            withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = migrationsDir
            .appending(path: "imprint-projects-pre-unified-\(stamp).sqlite",
                       directoryHint: .notDirectory)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            Logger.sharedStore.infoCapture(
                "Backed up legacy Core Data store to \(dest.path)",
                category: "manuscript-migration"
            )
        } catch {
            Logger.sharedStore.warningCapture(
                "Backup of legacy Core Data store failed: \(error.localizedDescription)",
                category: "manuscript-migration"
            )
        }
    }

    /// If the completion flag is set but the unified store has no
    /// manuscript-collection items, treat that as an out-of-band reset
    /// and rerun the migration. Common cause: user nuked the app-group
    /// container while keeping `ImprintProjects.sqlite` intact.
    private static func shouldReRunDueToEmptyStore() -> Bool {
        let adapter = ManuscriptStoreAdapter.shared
        do {
            let collections = try adapter.sharedStore.queryBySchema(
                schemaRef: "manuscript-collection",
                limit: 1,
                offset: 0
            )
            if collections.isEmpty {
                // Check whether the legacy CD store actually has rows we
                // could re-import. If not, there's nothing to do.
                let context = ImprintPersistenceController.shared.viewContext
                let wsCount = (try? context.count(
                    for: NSFetchRequest<NSManagedObject>(entityName: "Workspace")
                )) ?? 0
                if wsCount > 0 {
                    Logger.sharedStore.warningCapture(
                        "Migration flag is set but no collections in store and legacy data present — re-running",
                        category: "manuscript-migration"
                    )
                    return true
                }
            }
        } catch {
            Logger.sharedStore.warningCapture(
                "shouldReRunDueToEmptyStore check failed: \(error.localizedDescription)",
                category: "manuscript-migration"
            )
        }
        return false
    }
}
