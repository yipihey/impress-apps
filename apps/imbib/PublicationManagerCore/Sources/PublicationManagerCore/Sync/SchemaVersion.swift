//
//  SchemaVersion.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import OSLog

/// Schema version registry for Core Data and CloudKit compatibility.
///
/// This provides explicit versioning with compatibility checks to ensure safe
/// migrations and prevent data corruption during sync.
///
/// # Version Numbering
///
/// Versions use a three-digit scheme: major (100s), minor (10s), patch (1s).
/// - Major: Breaking changes requiring migration (100, 200, 300...)
/// - Minor: Additive changes (110, 120, 130...)
/// - Patch: Bug fixes, no schema change (111, 112, 113...)
///
/// # Compatibility Rules
///
/// - Devices can sync if both are >= minimumCompatible
/// - Newer devices can read older data, but older devices may not read newer data
/// - Breaking changes require incrementing major version and updating minimumCompatible
public enum SchemaVersion: Int, Comparable, Codable, Sendable {
    /// Initial release (1.0)
    case v1_0 = 100

    /// Added manuscript support (1.1)
    case v1_1 = 110

    /// Added annotation fields (1.2)
    case v1_2 = 120

    // MARK: - Current Version

    /// The current schema version.
    ///
    /// Update this when making schema changes. New fields should be added
    /// as new cases, never by modifying existing cases.
    public static let current: SchemaVersion = .v1_2

    /// The minimum schema version this app can read from CloudKit.
    ///
    /// Update this when making breaking changes that require migration.
    /// Old devices below this version will be prompted to update.
    public static let minimumCompatible: SchemaVersion = .v1_0

    // MARK: - Comparable

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - Properties

    /// Human-readable version string (e.g., "1.2")
    public var displayString: String {
        let major = rawValue / 100
        let minor = (rawValue % 100) / 10
        return "\(major).\(minor)"
    }

    /// Whether this version is compatible with the current app.
    public var isCompatibleWithCurrentApp: Bool {
        self >= Self.minimumCompatible
    }

    /// Whether this version can be upgraded to the current version.
    public var canUpgradeToCurrent: Bool {
        self < Self.current && self >= Self.minimumCompatible
    }

    // MARK: - Migration Info

    /// Description of changes in this version.
    public var changeDescription: String {
        switch self {
        case .v1_0:
            return "Initial release with publications, libraries, smart searches, and CloudKit sync"
        case .v1_1:
            return "Added manuscript support for academic paper writing integration"
        case .v1_2:
            return "Added PDF annotation fields and highlights support"
        }
    }

    /// Whether migration from the previous version requires a full re-sync.
    public var requiresFullResync: Bool {
        switch self {
        case .v1_0:
            return false  // No previous version
        case .v1_1:
            return false  // Additive change
        case .v1_2:
            return false  // Additive change
        }
    }
}

// MARK: - Version Check

/// Result of checking schema version compatibility.
public enum SchemaVersionCheckResult: Sendable {
    /// Schema is current, no migration needed.
    case current

    /// Schema can be upgraded to current version.
    case needsMigration(from: SchemaVersion)

    /// Schema is from a newer app version. User should update the app.
    case newerThanApp(remoteVersion: Int)

    /// Schema is too old and incompatible. Data may need recovery.
    case incompatible(remoteVersion: Int)
}

// MARK: - Schema Version Checker

/// Checks schema versions for compatibility before sync operations.
public struct SchemaVersionChecker: Sendable {

    public init() {}

    /// Check if a remote schema version is compatible with this app.
    ///
    /// - Parameter remoteVersionRaw: The raw version integer from CloudKit or another device.
    /// - Returns: The compatibility result.
    public func check(remoteVersionRaw: Int) -> SchemaVersionCheckResult {
        // Try to parse as known version
        if let remoteVersion = SchemaVersion(rawValue: remoteVersionRaw) {
            if remoteVersion == .current {
                return .current
            } else if remoteVersion < .current {
                if remoteVersion >= .minimumCompatible {
                    return .needsMigration(from: remoteVersion)
                } else {
                    return .incompatible(remoteVersion: remoteVersionRaw)
                }
            } else {
                // Remote is newer than current
                return .newerThanApp(remoteVersion: remoteVersionRaw)
            }
        }

        // Unknown version number
        if remoteVersionRaw > SchemaVersion.current.rawValue {
            return .newerThanApp(remoteVersion: remoteVersionRaw)
        } else {
            return .incompatible(remoteVersion: remoteVersionRaw)
        }
    }

    /// Check if this device should warn the user before syncing.
    ///
    /// Returns true if the user should be warned about potential issues.
    public func shouldWarnBeforeSync(remoteVersionRaw: Int) -> Bool {
        switch check(remoteVersionRaw: remoteVersionRaw) {
        case .current, .needsMigration:
            return false
        case .newerThanApp, .incompatible:
            return true
        }
    }
}

// MARK: - Storage Keys

extension SchemaVersion {
    /// Key for storing schema version in CloudKit metadata.
    public static let cloudKitMetadataKey = "schemaVersion"

    /// Key for storing schema version in UserDefaults.
    public static let userDefaultsKey = "imbib.schema.version"

    /// Key for storing last known remote version.
    public static let lastKnownRemoteVersionKey = "imbib.schema.lastKnownRemoteVersion"
}

// MARK: - Logging

extension SchemaVersion {
    /// Log schema version information.
    public static func logCurrentVersion() {
        Logger.sync.info("""
            Schema version info:
            - Current: \(current.displayString) (\(current.rawValue))
            - Minimum compatible: \(minimumCompatible.displayString) (\(minimumCompatible.rawValue))
            """)
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let sync = Logger(subsystem: "com.imbib.app", category: "sync")
}
