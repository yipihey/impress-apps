//
//  ArchiveExporter.swift
//  MessageManagerCore
//
//  Exports research conversations to .impartarchive format.
//  Produces human-readable JSONL files for long-term preservation.
//

import Foundation
import OSLog

private let archiveLogger = Logger(subsystem: "com.impart", category: "archive")

// MARK: - Export Options

/// Options for archive export.
public struct ArchiveExportOptions: Sendable {
    /// Include artifact snapshots (PDFs, git bundles).
    public var includeSnapshots: Bool

    /// Include attachments.
    public var includeAttachments: Bool

    /// Include full provenance events.
    public var includeProvenance: Bool

    /// Compress the archive.
    public var compress: Bool

    /// Notes to include in manifest.
    public var notes: String?

    public init(
        includeSnapshots: Bool = true,
        includeAttachments: Bool = true,
        includeProvenance: Bool = true,
        compress: Bool = false,
        notes: String? = nil
    ) {
        self.includeSnapshots = includeSnapshots
        self.includeAttachments = includeAttachments
        self.includeProvenance = includeProvenance
        self.compress = compress
        self.notes = notes
    }

    /// Full archive with everything.
    public static var full: ArchiveExportOptions {
        ArchiveExportOptions(
            includeSnapshots: true,
            includeAttachments: true,
            includeProvenance: true,
            compress: true
        )
    }

    /// Lightweight archive without large files.
    public static var lightweight: ArchiveExportOptions {
        ArchiveExportOptions(
            includeSnapshots: false,
            includeAttachments: false,
            includeProvenance: true,
            compress: false
        )
    }
}

// MARK: - Export Progress

/// Progress callback for archive export.
public struct ArchiveExportProgress: Sendable {
    public let phase: Phase
    public let current: Int
    public let total: Int
    public let message: String

    public enum Phase: String, Sendable {
        case preparing
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

// MARK: - Archive Exporter

/// Actor for exporting research conversations to archive format.
public actor ArchiveExporter {

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

    // MARK: - Export

    /// Export conversations to an archive.
    public func export(
        conversationIds: [UUID],
        to destinationURL: URL,
        options: ArchiveExportOptions = .full,
        progressHandler: (@Sendable (ArchiveExportProgress) -> Void)? = nil
    ) async throws -> URL {
        archiveLogger.info("Starting archive export for \(conversationIds.count) conversations")

        let fm = FileManager.default
        let archiveURL = destinationURL.appendingPathExtension("impartarchive")

        // Create archive directory structure
        try createArchiveStructure(at: archiveURL)

        // Report progress
        progressHandler?(ArchiveExportProgress(
            phase: .preparing,
            current: 0,
            total: conversationIds.count,
            message: "Preparing archive..."
        ))

        // Export conversations
        var conversationEntries: [ArchiveConversationEntry] = []
        for (index, conversationId) in conversationIds.enumerated() {
            progressHandler?(ArchiveExportProgress(
                phase: .conversations,
                current: index,
                total: conversationIds.count,
                message: "Exporting conversation \(index + 1) of \(conversationIds.count)"
            ))

            let entry = try await exportConversation(conversationId, to: archiveURL)
            conversationEntries.append(entry)
        }

        // Export artifacts
        progressHandler?(ArchiveExportProgress(
            phase: .artifacts,
            current: 0,
            total: 1,
            message: "Exporting artifact references..."
        ))
        let artifactsEntry = try await exportArtifacts(
            forConversations: conversationIds,
            to: archiveURL,
            includeSnapshots: options.includeSnapshots
        )

        // Export provenance
        var provenanceEntry = ArchiveProvenanceEntry(eventCount: 0)
        if options.includeProvenance {
            progressHandler?(ArchiveExportProgress(
                phase: .provenance,
                current: 0,
                total: 1,
                message: "Exporting provenance events..."
            ))
            provenanceEntry = try await exportProvenance(
                forConversations: conversationIds,
                to: archiveURL
            )
        }

        // Export attachments
        var attachmentsEntry = ArchiveAttachmentsEntry()
        if options.includeAttachments {
            progressHandler?(ArchiveExportProgress(
                phase: .attachments,
                current: 0,
                total: 1,
                message: "Exporting attachments..."
            ))
            attachmentsEntry = try await exportAttachments(
                forConversations: conversationIds,
                to: archiveURL
            )
        }

        // Write manifest
        progressHandler?(ArchiveExportProgress(
            phase: .finalizing,
            current: 0,
            total: 1,
            message: "Writing manifest..."
        ))

        let manifest = ArchiveManifest(
            createdBy: getCurrentUserIdentifier(),
            appVersion: getAppVersion(),
            conversations: conversationEntries,
            artifacts: artifactsEntry,
            provenance: provenanceEntry,
            attachments: attachmentsEntry,
            notes: options.notes
        )

        try writeManifest(manifest, to: archiveURL)

        // Compress if requested
        var finalURL = archiveURL
        if options.compress {
            finalURL = try compressArchive(at: archiveURL)
            try? fm.removeItem(at: archiveURL)
        }

        archiveLogger.info("Archive export complete: \(finalURL.path)")

        return finalURL
    }

    // MARK: - Private Helpers

    private func createArchiveStructure(at url: URL) throws {
        let fm = FileManager.default

        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: url.appendingPathComponent(ArchiveStructure.conversationsDirectory),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: url.appendingPathComponent(ArchiveStructure.artifactsDirectory),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: url.appendingPathComponent(ArchiveStructure.artifactSnapshotsDirectory),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: url.appendingPathComponent(ArchiveStructure.provenanceDirectory),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: url.appendingPathComponent(ArchiveStructure.attachmentsDirectory),
            withIntermediateDirectories: true
        )
    }

    private func exportConversation(
        _ conversationId: UUID,
        to archiveURL: URL
    ) async throws -> ArchiveConversationEntry {
        // Fetch conversation and messages from Core Data
        // This is a placeholder - actual implementation would fetch from persistence
        let filePath = ArchiveStructure.conversationPath(id: conversationId)
        let fileURL = archiveURL.appendingPathComponent(filePath)

        // Write JSONL format
        var lines: [String] = []

        // Conversation header
        let header: [String: Any] = [
            "type": "conversation",
            "id": conversationId.uuidString,
            "title": "Conversation \(conversationId.uuidString.prefix(8))",
            "participants": ["user@example.com"]
        ]
        if let headerData = try? JSONSerialization.data(withJSONObject: header),
           let headerString = String(data: headerData, encoding: .utf8) {
            lines.append(headerString)
        }

        // Write to file
        let content = lines.joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        return ArchiveConversationEntry(
            id: conversationId,
            title: "Conversation \(conversationId.uuidString.prefix(8))",
            participants: ["user@example.com"],
            createdAt: Date(),
            lastActivityAt: Date(),
            messageCount: 0,
            filePath: filePath
        )
    }

    private func exportArtifacts(
        forConversations conversationIds: [UUID],
        to archiveURL: URL,
        includeSnapshots: Bool
    ) async throws -> ArchiveArtifactsEntry {
        var artifactCount = 0
        var lines: [String] = []

        for conversationId in conversationIds {
            let artifacts = try await artifactService.getArtifacts(forConversation: conversationId)
            for artifact in artifacts {
                artifactCount += 1

                let entry: [String: Any?] = [
                    "uri": artifact.uriString,
                    "type": artifact.type.rawValue,
                    "displayName": artifact.displayName,
                    "version": artifact.version,
                    "introducedBy": artifact.introducedBy,
                    "createdAt": ISO8601DateFormatter().string(from: artifact.createdAt)
                ]

                if let data = try? JSONSerialization.data(withJSONObject: entry.compactMapValues { $0 }),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }

        // Write references file
        let referencesURL = archiveURL.appendingPathComponent(ArchiveStructure.artifactReferencesFile)
        let content = lines.joined(separator: "\n")
        try content.write(to: referencesURL, atomically: true, encoding: .utf8)

        return ArchiveArtifactsEntry(
            count: artifactCount,
            snapshots: ArchiveSnapshotsEntry()
        )
    }

    private func exportProvenance(
        forConversations conversationIds: [UUID],
        to archiveURL: URL
    ) async throws -> ArchiveProvenanceEntry {
        var events: [ProvenanceEvent] = []
        var firstEventAt: Date?
        var lastEventAt: Date?

        for conversationId in conversationIds {
            let conversationEvents = await provenanceService.eventsForConversation(conversationId.uuidString)
            events.append(contentsOf: conversationEvents)

            for event in conversationEvents {
                if firstEventAt == nil || event.timestamp < firstEventAt! {
                    firstEventAt = event.timestamp
                }
                if lastEventAt == nil || event.timestamp > lastEventAt! {
                    lastEventAt = event.timestamp
                }
            }
        }

        // Sort by sequence
        events.sort { $0.sequence < $1.sequence }

        // Write JSONL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var lines: [String] = []
        for event in events {
            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        let provenanceURL = archiveURL.appendingPathComponent(ArchiveStructure.provenanceEventsFile)
        let content = lines.joined(separator: "\n")
        try content.write(to: provenanceURL, atomically: true, encoding: .utf8)

        return ArchiveProvenanceEntry(
            eventCount: events.count,
            firstEventAt: firstEventAt,
            lastEventAt: lastEventAt
        )
    }

    private func exportAttachments(
        forConversations conversationIds: [UUID],
        to archiveURL: URL
    ) async throws -> ArchiveAttachmentsEntry {
        // Placeholder - actual implementation would export message attachments
        return ArchiveAttachmentsEntry()
    }

    private func writeManifest(_ manifest: ArchiveManifest, to archiveURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(manifest)
        let manifestURL = archiveURL.appendingPathComponent(ArchiveStructure.manifestFileName)
        try data.write(to: manifestURL)
    }

    private func compressArchive(at url: URL) throws -> URL {
        let compressedURL = url.deletingPathExtension().appendingPathExtension("impartarchive.zip")

        // Use zip command for simplicity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", compressedURL.path, url.lastPathComponent]
        process.currentDirectoryURL = url.deletingLastPathComponent()

        try process.run()
        process.waitUntilExit()

        return compressedURL
    }

    private func getCurrentUserIdentifier() -> String {
        NSUserName()
    }

    private func getAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
