import Foundation

/// Provides the canonical shared database path for all impress apps.
///
/// All five apps (imbib, impart, imprint, implore, impel) should open their
/// impress-core store at `SharedWorkspace.databaseURL`.
///
/// Layout:
/// ```
/// group.com.impress.suite/
///   workspace/
///     impress.sqlite        ← shared impress-core store
/// ```
public enum SharedWorkspace: Sendable {
    /// The canonical URL for the shared impress-core SQLite database.
    ///
    /// All apps must use this path when opening their `SqliteItemStore`.
    public static var databaseURL: URL {
        rootDirectory.appendingPathComponent("workspace/impress.sqlite")
    }

    /// The shared workspace directory (parent of the database file).
    public static var workspaceDirectory: URL {
        rootDirectory.appendingPathComponent("workspace")
    }

    /// Creates the workspace directory if it does not already exist.
    ///
    /// Call this at app startup before opening the database.
    public static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: workspaceDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// The app group container root, with fallback for non-sandboxed builds.
    private static var rootDirectory: URL {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SiblingDiscovery.suiteGroupID
        ) {
            return url
        }
        // Fallback for development / non-sandboxed builds
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("com.impress.suite-dev")
    }

    // MARK: - Store Access

    /// The filesystem path to the shared impress-core SQLite database.
    ///
    /// Use this path with `ImpressRustCore.SharedStore.open(path:)`:
    ///
    /// ```swift
    /// import ImpressRustCore
    /// try SharedWorkspace.ensureDirectoryExists()
    /// let store = try SharedStore.open(path: SharedWorkspace.databasePath)
    /// try store.upsertItem(id: id, schemaRef: "bibliography-entry", payloadJson: json)
    /// ```
    public static var databasePath: String {
        databaseURL.path
    }

    /// Migrates a legacy per-app SQLite database to the shared workspace.
    ///
    /// If `legacyURL` exists and the shared database does not yet exist,
    /// copies the file and returns `true`. Safe to call multiple times.
    ///
    /// - Parameter legacyURL: The old database path (e.g., imbib.sqlite in app support).
    /// - Returns: `true` if migration occurred, `false` if not needed.
    @discardableResult
    public static func migrateLegacyDatabase(from legacyURL: URL) throws -> Bool {
        let destination = databaseURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return false // already migrated
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return false // no legacy database to migrate
        }
        try ensureDirectoryExists()
        try FileManager.default.copyItem(at: legacyURL, to: destination)
        return true
    }
}
