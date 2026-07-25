//
//  BackupAutomationHandler.swift
//  PublicationManagerCore
//
//  Agent-drivable library backup & restore (standing directive: every feature
//  exposes its capability surface over HTTP + MCP so agents can drive imbib
//  without clicking).
//
//    GET    /api/backups                 → { backups: [...] }
//    POST   /api/backups                 { label?, directory? }   → { backup }
//    GET    /api/backups/inspect?path=   → { valid, issues, manifest }
//    POST   /api/backups/restore         { path, force? }         → { report }
//    POST   /api/backups/prune           { keep }                 → { removed }
//    DELETE /api/backups?path=           → { deleted }
//
//  All real work is Rust-side (`impress_core::backup` through `ImbibStore`);
//  this file only decodes parameters and shapes responses. Kept out of
//  HTTPAutomationRouter.swift on purpose — that file is a shared hot spot.
//
//  **Restore is destructive and sync-aware.** It replaces the whole shared
//  store (imbib + imprint + impel data). It refuses while CloudKit sync is
//  enabled unless `force: true` is passed, because restored rows carry old
//  HLC clocks and ADR-0020's whole-record LWW would let peers overwrite them
//  (see LibraryBackupService.restore).
//

import Foundation
import ImpressLogging

public enum BackupAutomationHandler {

    /// Resolve a `path` query parameter into a URL.
    ///
    /// The shared query-string parser percent-decodes but does not treat `+`
    /// as a space (`HTTPRequest.parse`). Since backups live under
    /// `.../Application Support/...`, a client that form-encodes its query —
    /// JavaScript's `URLSearchParams` does exactly that — sends
    /// `Application+Support` and the file "does not exist". Rather than change
    /// the parser every app shares, retry the `+`-as-space reading when the
    /// literal path is not on disk. A real path containing `+` still wins,
    /// because it is tried first.
    static func resolvePath(_ raw: String) -> URL {
        let direct = URL(fileURLWithPath: raw)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard raw.contains("+") else { return direct }
        let unplussed = raw.replacingOccurrences(of: "+", with: " ")
        let candidate = URL(fileURLWithPath: unplussed)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : direct
    }

    // MARK: - Create

    /// POST /api/backups — snapshot the whole store.
    public static func createBackup(json: [String: Any]) async -> (body: [String: Any], status: Int)
    {
        let label = json["label"] as? String
        let directory = (json["directory"] as? String).map { URL(fileURLWithPath: $0) }
        logInfo(
            "HTTP backup create requested\(label.map { " label=\($0)" } ?? "")",
            category: "backup")
        do {
            let record = try await LibraryBackupService.shared.createBackup(
                label: label, directory: directory)
            return (["backup": record.jsonObject], 201)
        } catch {
            return (["error": error.localizedDescription], 500)
        }
    }

    // MARK: - Read

    /// GET /api/backups — list backups, newest first.
    public static func listBackups(directory: String?) async -> (body: [String: Any], status: Int) {
        let dir = directory.map { URL(fileURLWithPath: $0) }
        let records = await LibraryBackupService.shared.listBackups(directory: dir)
        return (
            [
                "count": records.count,
                "directory": (dir ?? LibraryBackupService.backupsDirectory).path,
                "backups": records.map(\.jsonObject),
            ], 200
        )
    }

    /// GET /api/backups/inspect?path= — validate a file, touching nothing.
    public static func inspectBackup(path: String?) async -> (body: [String: Any], status: Int) {
        guard let path, !path.isEmpty else {
            return (["error": "Missing 'path' parameter"], 400)
        }
        do {
            let inspection = try await LibraryBackupService.shared.inspect(resolvePath(path))
            // A file that fails validation is a successful *answer*, not a
            // failed request — an agent needs to read `valid` and `issues`.
            return (inspection.jsonObject, 200)
        } catch {
            return (["error": error.localizedDescription], 500)
        }
    }

    // MARK: - Restore

    /// POST /api/backups/restore — replace the live store's contents.
    public static func restoreBackup(json: [String: Any]) async -> (
        body: [String: Any], status: Int
    ) {
        guard let path = json["path"] as? String, !path.isEmpty else {
            return (["error": "Missing 'path' field"], 400)
        }
        let force = json["force"] as? Bool ?? false
        logInfo("HTTP restore requested from \(path) force=\(force)", category: "backup")
        do {
            let report = try await LibraryBackupService.shared.restore(
                from: resolvePath(path), force: force)
            await LibraryBackupService.announceRestoreToUI()
            var body = report.jsonObject
            body["warning"] =
                "The store was replaced. Relaunch imbib (and any running imprint/impel) "
                + "so their caches match the restored database."
            return (body, 200)
        } catch LibraryBackupError.syncEnabled {
            // 409: the request was well-formed but conflicts with current
            // state. `force: true` is the documented override.
            return (
                [
                    "error": LibraryBackupError.syncEnabled.localizedDescription,
                    "code": "sync_enabled",
                ], 409
            )
        } catch let LibraryBackupError.invalidBackup(path, issues) {
            return (
                [
                    "error": "Backup is not usable",
                    "code": "invalid_backup",
                    "path": path,
                    "issues": issues,
                ], 422
            )
        } catch {
            return (["error": error.localizedDescription], 500)
        }
    }

    // MARK: - Housekeeping

    /// DELETE /api/backups?path= — delete one backup and its manifest.
    public static func deleteBackup(path: String?) async -> (body: [String: Any], status: Int) {
        guard let path, !path.isEmpty else {
            return (["error": "Missing 'path' parameter"], 400)
        }
        do {
            let deleted = try await LibraryBackupService.shared.delete(resolvePath(path))
            return (["deleted": deleted, "path": path], deleted ? 200 : 404)
        } catch {
            return (["error": error.localizedDescription], 500)
        }
    }

    /// POST /api/backups/prune — keep the newest `keep`, delete the rest.
    public static func pruneBackups(json: [String: Any]) async -> (body: [String: Any], status: Int)
    {
        guard let keep = json["keep"] as? Int, keep >= 0 else {
            return (["error": "Missing or invalid 'keep' field"], 400)
        }
        let directory = (json["directory"] as? String).map { URL(fileURLWithPath: $0) }
        do {
            let removed = try await LibraryBackupService.shared.prune(
                keep: keep, directory: directory)
            return (["removed": removed, "count": removed.count], 200)
        } catch {
            return (["error": error.localizedDescription], 500)
        }
    }
}
