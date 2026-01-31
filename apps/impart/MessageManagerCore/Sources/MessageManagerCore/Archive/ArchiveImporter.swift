//
//  ArchiveImporter.swift
//  MessageManagerCore
//
//  Imports research conversations from .impartarchive format.
//  Handles migration from older format versions.
//

import Foundation
import OSLog

private let importLogger = Logger(subsystem: "com.impart", category: "archive-import")

// MARK: - Import Options

/// Options for archive import.
public struct ArchiveImportOptions: Sendable {
    /// Import attachments.
    public var importAttachments: Bool

    /// Import provenance events.
    public var importProvenance: Bool

    /// Merge with existing conversations (vs replace).
    public var mergeExisting: Bool

    /// Prefix to add to imported conversation titles.
    public var titlePrefix: String?

    public init(
        importAttachments: Bool = true,
        importProvenance: Bool = true,
        mergeExisting: Bool = false,
        titlePrefix: String? = nil
    ) {
        self.importAttachments = importAttachments
        self.importProvenance = importProvenance
        self.mergeExisting = mergeExisting
        self.titlePrefix = titlePrefix
    }

    /// Full import with everything.
    public static var full: ArchiveImportOptions {
        ArchiveImportOptions(
            importAttachments: true,
            importProvenance: true,
            mergeExisting: false
        )
    }
}

// MARK: - Import Result

/// Result of an archive import operation.
public struct ArchiveImportResult: Sendable {
    /// Number of conversations imported.
    public let conversationsImported: Int

    /// Number of messages imported.
    public let messagesImported: Int

    /// Number of artifacts imported.
    public let artifactsImported: Int

    /// Number of provenance events imported.
    public let provenanceEventsImported: Int

    /// Number of attachments imported.
    public let attachmentsImported: Int

    /// Warnings encountered during import.
    public let warnings: [String]

    /// Errors encountered (non-fatal).
    public let errors: [String]

    /// IDs of imported conversations.
    public let importedConversationIds: [UUID]

    public init(
        conversationsImported: Int = 0,
        messagesImported: Int = 0,
        artifactsImported: Int = 0,
        provenanceEventsImported: Int = 0,
        attachmentsImported: Int = 0,
        warnings: [String] = [],
        errors: [String] = [],
        importedConversationIds: [UUID] = []
    ) {
        self.conversationsImported = conversationsImported
        self.messagesImported = messagesImported
        self.artifactsImported = artifactsImported
        self.provenanceEventsImported = provenanceEventsImported
        self.attachmentsImported = attachmentsImported
        self.warnings = warnings
        self.errors = errors
        self.importedConversationIds = importedConversationIds
    }
}

// MARK: - Import Progress

/// Progress callback for archive import.
public struct ArchiveImportProgress: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int
    public let message: String

    public enum Phase: String, Sendable {
        case validating
        case conversations
        case artifacts
        case provenance
        case attachments
        case finalizing
    }

    public var fractionComplete: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

// MARK: - Archive Importer

/// Actor for importing research conversations from archive format.
public actor ArchiveImporter {

    // MARK: - Properties

    private let persistenceController: PersistenceController
    private let provenanceService: ProvenanceService
    private let artifactService: ArtifactService

    // MARK: - Initialization

    public init(
        persistenceController: PersistenceController,
        provenanceService: ProvenanceService,
        artifactService: ArtifactService
    ) {
        self.persistenceController = persistenceController
        self.provenanceService = provenanceService
        self.artifactService = artifactService
    }

    // MARK: - Import

    /// Import an archive.
    public func importArchive(
        from sourceURL: URL,
        options: ArchiveImportOptions = .full,
        progressHandler: (@Sendable (ArchiveImportProgress) -> Void)? = nil
    ) async throws -> ArchiveImportResult {
        importLogger.info("Starting archive import from \(sourceURL.path)")

        var warnings: [String] = []
        var errors: [String] = []

        // Determine if compressed
        let archiveURL = try prepareArchive(from: sourceURL)

        // Validate and read manifest
        progressHandler?(ArchiveImportProgress(
            phase: .validating,
            current: 0,
            total: 1,
            message: "Reading manifest..."
        ))

        let manifest = try readManifest(from: archiveURL)

        // Check version compatibility
        if manifest.formatVersion > ArchiveFormatVersion.current {
            warnings.append("Archive format version \(manifest.formatVersion.string) is newer than supported \(ArchiveFormatVersion.current.string)")
        }

        // Import conversations
        var conversationsImported = 0
        var messagesImported = 0
        var importedConversationIds: [UUID] = []

        for (index, entry) in manifest.conversations.enumerated() {
            progressHandler?(ArchiveImportProgress(
                phase: .conversations,
                current: index,
                total: manifest.conversations.count,
                message: "Importing conversation \(index + 1) of \(manifest.conversations.count)"
            ))

            do {
                let (conversationId, messageCount) = try await importConversation(
                    entry,
                    from: archiveURL,
                    options: options
                )
                importedConversationIds.append(conversationId)
                conversationsImported += 1
                messagesImported += messageCount
            } catch {
                errors.append("Failed to import conversation \(entry.id): \(error.localizedDescription)")
            }
        }

        // Import artifacts
        progressHandler?(ArchiveImportProgress(
            phase: .artifacts,
            current: 0,
            total: 1,
            message: "Importing artifacts..."
        ))
        let artifactsImported = try await importArtifacts(from: archiveURL)

        // Import provenance
        var provenanceEventsImported = 0
        if options.importProvenance {
            progressHandler?(ArchiveImportProgress(
                phase: .provenance,
                current: 0,
                total: 1,
                message: "Importing provenance events..."
            ))
            provenanceEventsImported = try await importProvenance(from: archiveURL)
        }

        // Import attachments
        var attachmentsImported = 0
        if options.importAttachments {
            progressHandler?(ArchiveImportProgress(
                phase: .attachments,
                current: 0,
                total: 1,
                message: "Importing attachments..."
            ))
            attachmentsImported = try await importAttachments(from: archiveURL)
        }

        // Cleanup temp directory if we extracted a compressed archive
        if sourceURL.pathExtension == "zip" {
            try? FileManager.default.removeItem(at: archiveURL)
        }

        importLogger.info("Archive import complete: \(conversationsImported) conversations")

        return ArchiveImportResult(
            conversationsImported: conversationsImported,
            messagesImported: messagesImported,
            artifactsImported: artifactsImported,
            provenanceEventsImported: provenanceEventsImported,
            attachmentsImported: attachmentsImported,
            warnings: warnings,
            errors: errors,
            importedConversationIds: importedConversationIds
        )
    }

    /// Preview an archive without importing.
    public func preview(from sourceURL: URL) async throws -> ArchiveManifest {
        let archiveURL = try prepareArchive(from: sourceURL)
        return try readManifest(from: archiveURL)
    }

    // MARK: - Private Helpers

    private func prepareArchive(from url: URL) throws -> URL {
        // If compressed, extract first
        if url.pathExtension == "zip" || url.lastPathComponent.hasSuffix(".impartarchive.zip") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", url.path, "-d", tempDir.path]

            try process.run()
            process.waitUntilExit()

            // Find the extracted archive directory
            let contents = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil
            )
            if let archiveDir = contents.first(where: { $0.pathExtension == "impartarchive" }) {
                return archiveDir
            }

            return tempDir
        }

        return url
    }

    private func readManifest(from archiveURL: URL) throws -> ArchiveManifest {
        let manifestURL = archiveURL.appendingPathComponent(ArchiveStructure.manifestFileName)
        let data = try Data(contentsOf: manifestURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(ArchiveManifest.self, from: data)
    }

    private func importConversation(
        _ entry: ArchiveConversationEntry,
        from archiveURL: URL,
        options: ArchiveImportOptions
    ) async throws -> (UUID, Int) {
        let fileURL = archiveURL.appendingPathComponent(entry.filePath)
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")

        var messageCount = 0

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            switch type {
            case "conversation":
                // Create/update conversation
                break
            case "message":
                messageCount += 1
                // Create message
                break
            case "artifact_mention":
                // Record mention
                break
            default:
                break
            }
        }

        return (entry.id, messageCount)
    }

    private func importArtifacts(from archiveURL: URL) async throws -> Int {
        let referencesURL = archiveURL.appendingPathComponent(ArchiveStructure.artifactReferencesFile)

        guard FileManager.default.fileExists(atPath: referencesURL.path) else {
            return 0
        }

        let content = try String(contentsOf: referencesURL, encoding: .utf8)
        let lines = content.split(separator: "\n")

        var count = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = json["uri"] as? String else {
                continue
            }

            // Create artifact reference
            if let artifactURI = ArtifactURI(uri: uri) {
                _ = try await artifactService.getOrCreateArtifact(
                    uri: artifactURI,
                    displayName: json["displayName"] as? String,
                    introducedBy: json["introducedBy"] as? String
                )
                count += 1
            }
        }

        return count
    }

    private func importProvenance(from archiveURL: URL) async throws -> Int {
        let eventsURL = archiveURL.appendingPathComponent(ArchiveStructure.provenanceEventsFile)

        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            return 0
        }

        let content = try String(contentsOf: eventsURL, encoding: .utf8)
        let lines = content.split(separator: "\n")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var count = 0
        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }

            do {
                let event = try decoder.decode(ProvenanceEvent.self, from: data)
                await provenanceService.record(event)
                count += 1
            } catch {
                importLogger.warning("Failed to decode provenance event: \(error.localizedDescription)")
            }
        }

        return count
    }

    private func importAttachments(from archiveURL: URL) async throws -> Int {
        let attachmentsURL = archiveURL.appendingPathComponent(ArchiveStructure.attachmentsDirectory)

        guard FileManager.default.fileExists(atPath: attachmentsURL.path) else {
            return 0
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: attachmentsURL,
            includingPropertiesForKeys: nil
        )

        // Placeholder - actual implementation would import to content-addressed store
        return contents.count
    }
}
