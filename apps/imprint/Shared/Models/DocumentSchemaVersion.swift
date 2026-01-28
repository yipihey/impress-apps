//
//  DocumentSchemaVersion.swift
//  imprint
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import OSLog

/// Schema version tracking for .imprint document format.
///
/// This provides versioning for the document bundle structure, enabling
/// safe migrations and compatibility checks when opening documents.
///
/// # Bundle Structure
///
/// An .imprint document is a package containing:
/// - `main.typ` - The Typst source content
/// - `metadata.json` - Document metadata (includes schema version)
/// - `bibliography.bib` - BibTeX bibliography
/// - `document.crdt` - Automerge CRDT state for collaboration
///
/// # Version Numbering
///
/// Uses semantic versioning encoded as integers:
/// - 1.0.0 = 100
/// - 1.1.0 = 110
/// - 2.0.0 = 200
public enum DocumentSchemaVersion: Int, Comparable, Codable, Sendable {
    /// Initial release (1.0)
    case v1_0 = 100

    /// Added linked imbib manuscript ID (1.1)
    case v1_1 = 110

    /// Added CRDT state file (1.2)
    case v1_2 = 120

    // MARK: - Current Version

    /// The current document format version.
    public static let current: DocumentSchemaVersion = .v1_2

    /// The minimum version this app can read.
    public static let minimumReadable: DocumentSchemaVersion = .v1_0

    // MARK: - Comparable

    public static func < (lhs: DocumentSchemaVersion, rhs: DocumentSchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - Properties

    /// Human-readable version string (e.g., "1.2")
    public var displayString: String {
        let major = rawValue / 100
        let minor = (rawValue % 100) / 10
        return "\(major).\(minor)"
    }

    /// Whether this version can be read by the current app.
    public var isReadableByCurrentApp: Bool {
        self >= Self.minimumReadable && self <= Self.current
    }

    /// Whether this version needs migration to current.
    public var needsMigration: Bool {
        self < Self.current && self >= Self.minimumReadable
    }

    /// Whether this version is from a newer app.
    public var isNewerThanCurrentApp: Bool {
        self > Self.current
    }

    // MARK: - Migration Info

    /// Description of changes in this version.
    public var changeDescription: String {
        switch self {
        case .v1_0:
            return "Initial document format with Typst source and metadata"
        case .v1_1:
            return "Added linked imbib manuscript ID for citation integration"
        case .v1_2:
            return "Added Automerge CRDT state for real-time collaboration"
        }
    }

    /// Files expected to be present in a bundle at this version.
    public var expectedFiles: [String] {
        switch self {
        case .v1_0:
            return ["main.typ", "metadata.json"]
        case .v1_1:
            return ["main.typ", "metadata.json", "bibliography.bib"]
        case .v1_2:
            return ["main.typ", "metadata.json", "bibliography.bib", "document.crdt"]
        }
    }

    /// Optional files that may be present.
    public var optionalFiles: [String] {
        switch self {
        case .v1_0:
            return ["bibliography.bib"]
        case .v1_1:
            return ["document.crdt"]
        case .v1_2:
            return []
        }
    }
}

// MARK: - Version Check Result

/// Result of checking document version compatibility.
public enum DocumentVersionCheckResult: Sendable {
    /// Document is at current version.
    case current

    /// Document can be upgraded to current version.
    case needsMigration(from: DocumentSchemaVersion)

    /// Document is from a newer app version.
    case newerThanApp(documentVersion: Int)

    /// Document version is too old and unsupported.
    case unsupported(documentVersion: Int)

    /// Document has no version information (legacy format).
    case legacy
}

// MARK: - Document Version Checker

/// Validates document schema versions and determines compatibility.
public struct DocumentVersionChecker: Sendable {

    public init() {}

    /// Check if a document version is compatible with this app.
    ///
    /// - Parameter versionRaw: The raw version integer from document metadata.
    /// - Returns: The compatibility result.
    public func check(versionRaw: Int?) -> DocumentVersionCheckResult {
        guard let versionRaw = versionRaw else {
            return .legacy
        }

        if let version = DocumentSchemaVersion(rawValue: versionRaw) {
            if version == .current {
                return .current
            } else if version < .current {
                if version >= .minimumReadable {
                    return .needsMigration(from: version)
                } else {
                    return .unsupported(documentVersion: versionRaw)
                }
            } else {
                return .newerThanApp(documentVersion: versionRaw)
            }
        }

        // Unknown version number
        if versionRaw > DocumentSchemaVersion.current.rawValue {
            return .newerThanApp(documentVersion: versionRaw)
        } else {
            return .unsupported(documentVersion: versionRaw)
        }
    }

    /// Check if this app can safely open a document at the given version.
    public func canOpen(versionRaw: Int?) -> Bool {
        switch check(versionRaw: versionRaw) {
        case .current, .needsMigration, .legacy:
            return true
        case .newerThanApp, .unsupported:
            return false
        }
    }
}

// MARK: - Versioned Metadata

/// Extended document metadata that includes schema version.
public struct VersionedDocumentMetadata: Codable {
    /// Schema version of this document format.
    public let schemaVersion: Int

    /// Stable document identifier.
    public let id: UUID

    /// Document title.
    public let title: String

    /// Author list.
    public let authors: [String]

    /// Creation timestamp.
    public let createdAt: Date

    /// Last modified timestamp.
    public let modifiedAt: Date

    /// UUID of the linked imbib manuscript, if any.
    public var linkedImbibManuscriptID: UUID?

    /// App version that last saved this document.
    public var lastSavedByAppVersion: String?

    public init(
        schemaVersion: DocumentSchemaVersion = .current,
        id: UUID = UUID(),
        title: String,
        authors: [String],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        linkedImbibManuscriptID: UUID? = nil,
        lastSavedByAppVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion.rawValue
        self.id = id
        self.title = title
        self.authors = authors
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.linkedImbibManuscriptID = linkedImbibManuscriptID
        self.lastSavedByAppVersion = lastSavedByAppVersion
    }

    /// Get the schema version as an enum, if valid.
    public var schemaVersionEnum: DocumentSchemaVersion? {
        DocumentSchemaVersion(rawValue: schemaVersion)
    }
}

// MARK: - Document Migrator

/// Handles migration of documents between schema versions.
public actor DocumentMigrator {

    public init() {}

    /// Migrate a document to the current schema version.
    ///
    /// - Parameter documentURL: URL of the .imprint bundle to migrate.
    /// - Returns: The migrated document URL (same as input, migrated in place).
    /// - Throws: `DocumentMigrationError` if migration fails.
    public func migrateToCurrentVersion(documentURL: URL) async throws -> URL {
        let fileManager = FileManager.default

        // Read current metadata
        let metadataURL = documentURL.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try to decode as versioned metadata
        let currentVersion: Int
        if let versioned = try? decoder.decode(VersionedDocumentMetadata.self, from: metadataData) {
            currentVersion = versioned.schemaVersion
        } else {
            // Legacy format, assume v1.0
            currentVersion = DocumentSchemaVersion.v1_0.rawValue
        }

        let checker = DocumentVersionChecker()
        let checkResult = checker.check(versionRaw: currentVersion)

        switch checkResult {
        case .current:
            Logger.document.info("Document already at current version")
            return documentURL

        case .needsMigration(let fromVersion):
            Logger.document.info("Migrating document from v\(fromVersion.displayString) to v\(DocumentSchemaVersion.current.displayString)")
            try await performMigration(at: documentURL, from: fromVersion)
            return documentURL

        case .legacy:
            Logger.document.info("Migrating legacy document to v\(DocumentSchemaVersion.current.displayString)")
            try await migrateLegacyDocument(at: documentURL)
            return documentURL

        case .newerThanApp(let version):
            throw DocumentMigrationError.newerVersion(documentVersion: version)

        case .unsupported(let version):
            throw DocumentMigrationError.unsupportedVersion(version)
        }
    }

    /// Create a backup of a document before migration.
    public func backupDocument(at url: URL) async throws -> URL {
        let fileManager = FileManager.default
        let parentDir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let backupName = "\(baseName)-backup-\(timestamp).imprint"
        let backupURL = parentDir.appendingPathComponent(backupName)

        try fileManager.copyItem(at: url, to: backupURL)
        Logger.document.info("Created backup at: \(backupURL.path)")

        return backupURL
    }

    // MARK: - Private Methods

    private func performMigration(at url: URL, from version: DocumentSchemaVersion) async throws {
        var currentVersion = version

        // Migrate step by step through versions
        while currentVersion < .current {
            switch currentVersion {
            case .v1_0:
                try await migrateFrom1_0To1_1(at: url)
                currentVersion = .v1_1
            case .v1_1:
                try await migrateFrom1_1To1_2(at: url)
                currentVersion = .v1_2
            case .v1_2:
                // Already at current
                break
            }
        }

        // Update metadata with current version
        try await updateMetadataVersion(at: url, to: .current)
    }

    private func migrateFrom1_0To1_1(at url: URL) async throws {
        // v1.0 -> v1.1: Ensure bibliography.bib exists
        let bibURL = url.appendingPathComponent("bibliography.bib")
        if !FileManager.default.fileExists(atPath: bibURL.path) {
            try "".write(to: bibURL, atomically: true, encoding: .utf8)
        }
        Logger.document.info("Migrated v1.0 → v1.1: Added bibliography.bib")
    }

    private func migrateFrom1_1To1_2(at url: URL) async throws {
        // v1.1 -> v1.2: Add empty CRDT state if not present
        // CRDT state is optional at this point, will be created on first edit
        Logger.document.info("Migrated v1.1 → v1.2: Ready for CRDT state")
    }

    private func migrateLegacyDocument(at url: URL) async throws {
        // Convert legacy metadata to versioned format
        let metadataURL = url.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try to decode as old format
        struct LegacyMetadata: Codable {
            let id: UUID
            let title: String
            let authors: [String]
            let createdAt: Date
            let modifiedAt: Date
            var linkedImbibManuscriptID: UUID?
        }

        if let legacy = try? decoder.decode(LegacyMetadata.self, from: metadataData) {
            let versioned = VersionedDocumentMetadata(
                schemaVersion: .current,
                id: legacy.id,
                title: legacy.title,
                authors: legacy.authors,
                createdAt: legacy.createdAt,
                modifiedAt: legacy.modifiedAt,
                linkedImbibManuscriptID: legacy.linkedImbibManuscriptID,
                lastSavedByAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let newData = try encoder.encode(versioned)
            try newData.write(to: metadataURL)
        }

        Logger.document.info("Migrated legacy document to versioned format")
    }

    private func updateMetadataVersion(at url: URL, to version: DocumentSchemaVersion) async throws {
        let metadataURL = url.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(VersionedDocumentMetadata.self, from: metadataData)

        // Create new metadata with updated version
        let updated = VersionedDocumentMetadata(
            schemaVersion: version,
            id: metadata.id,
            title: metadata.title,
            authors: metadata.authors,
            createdAt: metadata.createdAt,
            modifiedAt: Date(),
            linkedImbibManuscriptID: metadata.linkedImbibManuscriptID,
            lastSavedByAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let newData = try encoder.encode(updated)
        try newData.write(to: metadataURL)
    }
}

// MARK: - Errors

/// Errors that can occur during document migration.
public enum DocumentMigrationError: LocalizedError {
    case newerVersion(documentVersion: Int)
    case unsupportedVersion(Int)
    case missingFile(String)
    case corruptedDocument(reason: String)

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let version):
            return "This document was created with a newer version of imprint (v\(version)). Please update the app to open it."
        case .unsupportedVersion(let version):
            return "This document format (v\(version)) is no longer supported. Please contact support for recovery options."
        case .missingFile(let filename):
            return "Document is missing required file: \(filename)"
        case .corruptedDocument(let reason):
            return "Document appears to be corrupted: \(reason)"
        }
    }
}

// MARK: - Logger Extension

private extension Logger {
    static let document = Logger(subsystem: "com.imbib.imprint", category: "document")
}
