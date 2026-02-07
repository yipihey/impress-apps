import Foundation

/// Provides access to the shared App Group container for cross-app file exchange.
///
/// Layout:
/// ```
/// group.com.impress.suite/
///   Documents/notifications/   — Darwin notification payloads
///   Documents/shared-artifacts/ — files exchanged between apps
/// ```
public struct SharedContainer: Sendable {
    /// The shared container root directory.
    public static var rootDirectory: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SiblingDiscovery.suiteGroupID
        ) else {
            // Fallback for non-sandboxed development builds
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("com.impress.suite-dev")
        }
        return url
    }

    /// Directory for Darwin notification payload files.
    public static var notificationsDirectory: URL {
        let url = rootDirectory.appendingPathComponent("Documents/notifications")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Directory for shared artifact files exchanged between apps.
    public static var sharedArtifactsDirectory: URL {
        let url = rootDirectory.appendingPathComponent("Documents/shared-artifacts")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a notification payload file atomically.
    /// - Parameters:
    ///   - name: The notification name (used as filename prefix).
    ///   - data: The JSON-encoded payload data.
    public static func writeNotificationPayload(name: String, data: Data) throws {
        let fileURL = notificationsDirectory.appendingPathComponent("\(name)-latest.json")
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads the latest notification payload for the given name.
    /// - Parameter name: The notification name.
    /// - Returns: The JSON data, or nil if no payload exists.
    public static func readNotificationPayload(name: String) -> Data? {
        let fileURL = notificationsDirectory.appendingPathComponent("\(name)-latest.json")
        return try? Data(contentsOf: fileURL)
    }

    /// Writes a shared artifact file.
    /// - Parameters:
    ///   - filename: The artifact filename.
    ///   - data: The file data.
    /// - Returns: The URL of the written file.
    @discardableResult
    public static func writeArtifact(filename: String, data: Data) throws -> URL {
        let fileURL = sharedArtifactsDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Reads a shared artifact file.
    /// - Parameter filename: The artifact filename.
    /// - Returns: The file data, or nil if not found.
    public static func readArtifact(filename: String) -> Data? {
        let fileURL = sharedArtifactsDirectory.appendingPathComponent(filename)
        return try? Data(contentsOf: fileURL)
    }
}
