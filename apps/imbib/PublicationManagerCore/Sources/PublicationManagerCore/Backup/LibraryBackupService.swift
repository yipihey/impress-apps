//
//  LibraryBackupService.swift
//  PublicationManagerCore
//
//  Whole-store backup and restore, reimplemented on the Rust graph store.
//
//  The pre-migration service assembled a folder of BibTeX + JSON + copied
//  attachments out of Core Data. That shape cannot round-trip the graph store
//  (tags, collections, flags, manuscripts, annotations, artifacts, undo
//  history), so this version takes the faithful path instead: a consistent
//  SQLite snapshot of the whole shared store, produced by
//  `impress_core::backup` and reached through the `ImbibStore` FFI.
//
//  Everything of substance lives in Rust (`crates/impress-core/src/backup.rs`)
//  — this actor only decides *where* backups live, enforces the sync guard,
//  and logs the three-point trace.
//

import Foundation
import ImbibRustCore
import ImpressKit
import ImpressLogging
import OSLog

// MARK: - Value types

/// Rows of one schema inside a backup.
public struct BackupSchemaTally: Sendable, Codable, Hashable {
    public let schemaRef: String
    public let count: Int64
}

/// Provenance and contents of one backup, read from its JSON sidecar and
/// re-verified against the snapshot itself.
public struct LibraryBackupManifest: Sendable, Codable, Hashable {
    public let formatVersion: UInt32
    public let createdAt: Date
    public let app: String
    public let appVersion: String
    public let coreVersion: String
    public let schemaVersion: Int64
    public let originID: String
    public let label: String?
    /// Every row in `items`, including operation history.
    public let itemCount: Int64
    /// Items excluding operation history — the user-visible content.
    public let contentItemCount: Int64
    public let referenceCount: Int64
    public let tagCount: Int64
    public let tombstoneCount: Int64
    public let countsBySchema: [BackupSchemaTally]
    public let byteSize: Int64
    public let sha256: String

    /// Papers in the backup.
    ///
    /// Publications are stored under `imbib/bibliography-entry` and the
    /// unprefixed `bibliography-entry` (imprint writes the latter), so both
    /// are summed; `publication@…` is accepted for forward compatibility.
    public var publicationCount: Int64 {
        countsBySchema
            .filter { tally in
                let name = tally.schemaRef.split(separator: "/").last.map(String.init)
                    ?? tally.schemaRef
                return name.hasPrefix("bibliography-entry") || name.hasPrefix("publication")
            }
            .reduce(0) { $0 + $1.count }
    }

    public var sizeString: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// One backup file on disk.
public struct LibraryBackupRecord: Sendable, Codable, Hashable, Identifiable {
    public let path: String
    public let manifestPath: String?
    public let manifest: LibraryBackupManifest

    /// Explicit memberwise init: the synthesised one is internal, and the
    /// Settings pane builds a record from a hand-picked file.
    public init(path: String, manifestPath: String?, manifest: LibraryBackupManifest) {
        self.path = path
        self.manifestPath = manifestPath
        self.manifest = manifest
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }
}

/// Verdict on a candidate backup file.
public struct LibraryBackupInspection: Sendable, Codable, Hashable {
    public let path: String
    public let valid: Bool
    /// Why it was rejected. Empty when `valid`.
    public let issues: [String]
    public let manifest: LibraryBackupManifest?
}

/// What a restore did.
public struct LibraryRestoreReport: Sendable, Codable, Hashable {
    public let restoredFrom: String
    /// Automatic snapshot of the state that was replaced.
    public let safetySnapshot: String?
    public let itemCountBefore: Int64
    public let itemCountAfter: Int64
    public let clearedSyncState: Bool
    /// Always true — running apps hold caches for a database that is gone.
    public let requiresRelaunch: Bool
}

/// Failures the UI and the HTTP layer have to distinguish.
public enum LibraryBackupError: LocalizedError, Sendable {
    case syncEnabled
    case invalidBackup(path: String, issues: [String])
    case store(String)

    public var errorDescription: String? {
        switch self {
        case .syncEnabled:
            return "iCloud sync is on. Restoring rewinds every record, and sync would "
                + "overwrite the restored data with what other devices hold. Turn sync off "
                + "in Settings › Sync before restoring (or pass force to override)."
        case let .invalidBackup(path, issues):
            return "\(URL(fileURLWithPath: path).lastPathComponent) is not a usable backup: "
                + issues.joined(separator: "; ")
        case let .store(message):
            return message
        }
    }
}

// MARK: - Service

/// Whole-store backup and restore.
///
/// An `actor` rather than a set of static functions because `VACUUM INTO` on a
/// large library takes real time: every call must land off the main thread,
/// and two snapshots must not interleave.
public actor LibraryBackupService {

    public static let shared = LibraryBackupService()

    public init() {}

    // MARK: Locations

    /// Where automatic and one-click backups are written.
    ///
    /// `~/Library/Application Support/imbib/Backups` on macOS — deliberately
    /// *outside* the app group: a backup that lives next to the database it
    /// protects is not much of a backup, and users need to reach these in
    /// Finder to copy them elsewhere.
    ///
    /// On iOS the same reasoning points at `Documents/Backups` instead of
    /// Application Support. Application Support is invisible to the user, and
    /// a backup nobody can reach is not a backup: with `UIFileSharingEnabled`
    /// the Documents folder shows up as *Files › On My iPhone › imbib*, so a
    /// snapshot can be dragged to iCloud Drive, AirDropped to the Mac, or
    /// handed to another app without imbib having to ship an exporter.
    ///
    /// Both platforms resolve one directory for every surface — pane, HTTP
    /// routes, MCP tools — so `imbib_list_backups` can never disagree with
    /// what the user is looking at.
    public nonisolated static var backupsDirectory: URL {
        #if os(iOS)
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!
        return documents.appendingPathComponent("Backups", isDirectory: true)
        #else
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("imbib", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        #endif
    }

    /// Pre-restore safety snapshots, kept apart from user-made backups so a
    /// prune of one never eats the other.
    public nonisolated static var safetyDirectory: URL {
        backupsDirectory.appendingPathComponent("Safety", isDirectory: true)
    }

    /// File extension of a snapshot. A plain SQLite database.
    public nonisolated static let fileExtension = "impressbackup"

    private nonisolated static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (.some(s), .some(b)): return "\(s) (\(b))"
        case let (.some(s), .none): return s
        default: return "unknown"
        }
    }

    private nonisolated var store: ImbibStore {
        RustStoreAdapter.shared.imbibStore
    }

    // MARK: Create

    /// Take a consistent snapshot of the whole shared store.
    ///
    /// Safe while imbib, imprint and impel are all writing: `VACUUM INTO`
    /// snapshots the committed state under a read transaction.
    @discardableResult
    public func createBackup(
        label: String? = nil,
        directory: URL? = nil
    ) throws -> LibraryBackupRecord {
        let dir = directory ?? Self.backupsDirectory
        // (1) mutation requested
        Logger.library.infoCapture(
            "Backup requested → \(dir.path)\(label.map { " label=\($0)" } ?? "")",
            category: "backup"
        )
        do {
            let row = try store.createBackup(
                directory: dir.path,
                appVersion: Self.appVersion,
                label: label
            )
            let record = LibraryBackupRecord(row)
            // (2) persistence saw it
            Logger.library.infoCapture(
                "Backup written: \(record.filename) — \(record.manifest.contentItemCount) items, "
                    + "\(record.manifest.referenceCount) refs, \(record.manifest.sizeString), "
                    + "sha256=\(record.manifest.sha256.prefix(12))…",
                category: "backup"
            )
            return record
        } catch {
            Logger.library.errorCapture(
                "Backup failed: \(error.localizedDescription)", category: "backup")
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }

    /// Snapshot to an exact path — the Save-panel path. Never overwrites.
    @discardableResult
    public func createBackup(at url: URL, label: String? = nil) throws -> LibraryBackupRecord {
        Logger.library.infoCapture("Backup requested → \(url.path)", category: "backup")
        do {
            let row = try store.createBackupAtPath(
                path: url.path, appVersion: Self.appVersion, label: label)
            let record = LibraryBackupRecord(row)
            Logger.library.infoCapture(
                "Backup written: \(record.filename) — \(record.manifest.contentItemCount) items, "
                    + "\(record.manifest.sizeString)",
                category: "backup"
            )
            return record
        } catch {
            Logger.library.errorCapture(
                "Backup failed: \(error.localizedDescription)", category: "backup")
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }

    // MARK: Read

    /// Backups in `directory`, newest first. Junk files are skipped.
    public func listBackups(directory: URL? = nil) -> [LibraryBackupRecord] {
        let dir = directory ?? Self.backupsDirectory
        do {
            let rows = try store.listBackups(directory: dir.path)
            // (3) UI reads it back
            Logger.library.infoCapture(
                "Backup list: \(rows.count) in \(dir.lastPathComponent)", category: "backup")
            return rows.map(LibraryBackupRecord.init)
        } catch {
            Logger.library.warningCapture(
                "Backup list failed: \(error.localizedDescription)", category: "backup")
            return []
        }
    }

    /// Validate a file without touching the live store.
    public func inspect(_ url: URL) throws -> LibraryBackupInspection {
        do {
            let row = try store.inspectBackup(path: url.path)
            Logger.library.infoCapture(
                "Backup inspect \(url.lastPathComponent): valid=\(row.valid)"
                    + (row.issues.isEmpty ? "" : " issues=\(row.issues.joined(separator: "; "))"),
                category: "backup"
            )
            return LibraryBackupInspection(row)
        } catch {
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }

    // MARK: Restore

    /// Replace the live store's contents with a backup.
    ///
    /// - The backup is validated first; a corrupt file is refused before
    ///   anything is touched.
    /// - Current state is snapshotted into `safetyDirectory` first, always.
    /// - **Sync:** refuses outright while `SyncSettings.isEnabled` unless
    ///   `force` is passed. Restored rows carry old HLC clocks, so under
    ///   ADR-0020's whole-record LWW a peer's newer copies would simply win
    ///   and the restore would appear to undo itself. Sync bookkeeping in the
    ///   restored database is cleared so a rewound library is never pushed at
    ///   other devices.
    /// - A relaunch is required afterwards: every in-memory cache in this
    ///   process (and in imprint/impel) now describes rows that are gone.
    @discardableResult
    public func restore(from url: URL, force: Bool = false) throws -> LibraryRestoreReport {
        if SyncSettings.isEnabled && !force {
            Logger.library.warningCapture(
                "Restore refused: iCloud sync is enabled", category: "backup")
            throw LibraryBackupError.syncEnabled
        }

        let inspection = try inspect(url)
        guard inspection.valid else {
            throw LibraryBackupError.invalidBackup(path: url.path, issues: inspection.issues)
        }

        // (1) mutation requested
        Logger.library.infoCapture(
            "Restore requested from \(url.lastPathComponent) "
                + "(\(inspection.manifest?.contentItemCount ?? 0) items, sync="
                + "\(SyncSettings.isEnabled ? "ON — forced" : "off"))",
            category: "backup"
        )

        do {
            let row = try store.restoreBackup(
                path: url.path,
                appVersion: Self.appVersion,
                safetyDirectory: Self.safetyDirectory.path,
                clearSyncState: true
            )
            let report = LibraryRestoreReport(row)
            // (2) persistence saw it
            Logger.library.infoCapture(
                "Restore applied: items \(report.itemCountBefore) → \(report.itemCountAfter); "
                    + "safety snapshot \(report.safetySnapshot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"); "
                    + "sync state cleared=\(report.clearedSyncState)",
                category: "backup"
            )
            return report
        } catch {
            Logger.library.errorCapture(
                "Restore failed: \(error.localizedDescription)", category: "backup")
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }

    /// Tell the UI the world changed under it. Call after `restore`.
    ///
    /// A full relaunch remains the honest instruction — this only stops the
    /// visible panes from showing rows that no longer exist.
    @MainActor
    public static func announceRestoreToUI() {
        RustStoreAdapter.shared.notifyMutationFromBackground()
        Logger.library.infoCapture(
            "Restore: UI notified to re-read the store", category: "backup")
    }

    // MARK: Housekeeping

    /// Delete one backup and its manifest sidecar.
    @discardableResult
    public func delete(_ url: URL) throws -> Bool {
        do {
            let deleted = try store.deleteBackup(path: url.path)
            Logger.library.infoCapture(
                "Backup deleted: \(url.lastPathComponent) (\(deleted))", category: "backup")
            return deleted
        } catch {
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }

    /// Keep the `keep` newest backups in `directory`; delete the rest.
    @discardableResult
    public func prune(keep: Int, directory: URL? = nil) throws -> [String] {
        let dir = directory ?? Self.backupsDirectory
        do {
            let removed = try store.pruneBackups(directory: dir.path, keep: UInt32(max(0, keep)))
            if !removed.isEmpty {
                Logger.library.infoCapture(
                    "Backup prune: removed \(removed.count), kept \(keep)", category: "backup")
            }
            return removed
        } catch {
            throw LibraryBackupError.store(error.localizedDescription)
        }
    }
}

// MARK: - FFI mapping

extension BackupSchemaTally {
    init(_ row: BackupSchemaCount) {
        self.init(schemaRef: row.schemaRef, count: row.count)
    }
}

extension LibraryBackupManifest {
    init(_ row: BackupManifestRow) {
        self.init(
            formatVersion: row.formatVersion,
            createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAtMs) / 1000),
            app: row.app,
            appVersion: row.appVersion,
            coreVersion: row.coreVersion,
            schemaVersion: row.schemaVersion,
            originID: row.originId,
            label: row.label,
            itemCount: row.itemCount,
            contentItemCount: row.contentItemCount,
            referenceCount: row.referenceCount,
            tagCount: row.tagCount,
            tombstoneCount: row.tombstoneCount,
            countsBySchema: row.countsBySchema.map(BackupSchemaTally.init),
            byteSize: row.byteSize,
            sha256: row.sha256
        )
    }
}

extension LibraryBackupRecord {
    init(_ row: BackupRecordRow) {
        self.init(
            path: row.path,
            manifestPath: row.manifestPath,
            manifest: LibraryBackupManifest(row.manifest)
        )
    }
}

extension LibraryBackupInspection {
    init(_ row: BackupInspectionRow) {
        self.init(
            path: row.path,
            valid: row.valid,
            issues: row.issues,
            manifest: row.manifest.map(LibraryBackupManifest.init)
        )
    }
}

extension LibraryRestoreReport {
    init(_ row: RestoreReportRow) {
        self.init(
            restoredFrom: row.restoredFrom,
            safetySnapshot: row.safetySnapshot,
            itemCountBefore: row.itemCountBefore,
            itemCountAfter: row.itemCountAfter,
            clearedSyncState: row.clearedSyncState,
            requiresRelaunch: row.requiresRelaunch
        )
    }
}

// MARK: - JSON projection (HTTP + MCP)

extension LibraryBackupManifest {
    /// Dictionary form for the automation API. Kept here so the HTTP router
    /// and any future surface agree field-for-field.
    public var jsonObject: [String: Any] {
        [
            "formatVersion": Int(formatVersion),
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "app": app,
            "appVersion": appVersion,
            "coreVersion": coreVersion,
            "schemaVersion": schemaVersion,
            "originID": originID,
            "label": label as Any,
            "itemCount": itemCount,
            "contentItemCount": contentItemCount,
            "publicationCount": publicationCount,
            "referenceCount": referenceCount,
            "tagCount": tagCount,
            "tombstoneCount": tombstoneCount,
            "countsBySchema": countsBySchema.map { ["schema": $0.schemaRef, "count": $0.count] },
            "byteSize": byteSize,
            "sizeString": sizeString,
            "sha256": sha256,
        ]
    }
}

extension LibraryBackupRecord {
    public var jsonObject: [String: Any] {
        [
            "path": path,
            "filename": filename,
            "manifestPath": manifestPath as Any,
            "manifest": manifest.jsonObject,
        ]
    }
}

extension LibraryBackupInspection {
    public var jsonObject: [String: Any] {
        [
            "path": path,
            "valid": valid,
            "issues": issues,
            "manifest": manifest?.jsonObject as Any,
        ]
    }
}

extension LibraryRestoreReport {
    public var jsonObject: [String: Any] {
        [
            "restoredFrom": restoredFrom,
            "safetySnapshot": safetySnapshot as Any,
            "itemCountBefore": itemCountBefore,
            "itemCountAfter": itemCountAfter,
            "clearedSyncState": clearedSyncState,
            "requiresRelaunch": requiresRelaunch,
        ]
    }
}
