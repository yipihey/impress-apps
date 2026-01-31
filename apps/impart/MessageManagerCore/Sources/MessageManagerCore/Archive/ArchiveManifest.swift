//
//  ArchiveManifest.swift
//  MessageManagerCore
//
//  Manifest structure for .impartarchive format.
//  Defines the structure and metadata of archived research conversations.
//

import Foundation

// MARK: - Archive Format Version

/// Version of the archive format.
public struct ArchiveFormatVersion: Codable, Sendable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public static let current = ArchiveFormatVersion(major: 1, minor: 0, patch: 0)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var string: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: ArchiveFormatVersion, rhs: ArchiveFormatVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

// MARK: - Archive Manifest

/// Manifest for a .impartarchive file.
public struct ArchiveManifest: Codable, Sendable {
    /// Format version.
    public let formatVersion: ArchiveFormatVersion

    /// When this archive was created.
    public let createdAt: Date

    /// Who/what created this archive.
    public let createdBy: String

    /// Application version that created the archive.
    public let appVersion: String

    /// Conversation metadata.
    public let conversations: [ArchiveConversationEntry]

    /// Artifact metadata.
    public let artifacts: ArchiveArtifactsEntry

    /// Provenance metadata.
    public let provenance: ArchiveProvenanceEntry

    /// Attachment metadata.
    public let attachments: ArchiveAttachmentsEntry

    /// Optional notes about the archive.
    public let notes: String?

    public init(
        formatVersion: ArchiveFormatVersion = .current,
        createdAt: Date = Date(),
        createdBy: String,
        appVersion: String,
        conversations: [ArchiveConversationEntry],
        artifacts: ArchiveArtifactsEntry,
        provenance: ArchiveProvenanceEntry,
        attachments: ArchiveAttachmentsEntry,
        notes: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.appVersion = appVersion
        self.conversations = conversations
        self.artifacts = artifacts
        self.provenance = provenance
        self.attachments = attachments
        self.notes = notes
    }
}

// MARK: - Conversation Entry

/// Metadata for an archived conversation.
public struct ArchiveConversationEntry: Codable, Sendable {
    /// Conversation ID.
    public let id: UUID

    /// Title.
    public let title: String

    /// Participants.
    public let participants: [String]

    /// When created.
    public let createdAt: Date

    /// Last activity.
    public let lastActivityAt: Date

    /// Number of messages.
    public let messageCount: Int

    /// Path to the JSONL file within the archive.
    public let filePath: String

    /// Parent conversation ID if this is a branch.
    public let parentConversationId: UUID?

    /// Child conversation IDs.
    public let childConversationIds: [UUID]

    public init(
        id: UUID,
        title: String,
        participants: [String],
        createdAt: Date,
        lastActivityAt: Date,
        messageCount: Int,
        filePath: String,
        parentConversationId: UUID? = nil,
        childConversationIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.filePath = filePath
        self.parentConversationId = parentConversationId
        self.childConversationIds = childConversationIds
    }
}

// MARK: - Artifacts Entry

/// Metadata for archived artifacts.
public struct ArchiveArtifactsEntry: Codable, Sendable {
    /// Number of artifact references.
    public let count: Int

    /// Path to references JSONL file.
    public let referencesPath: String

    /// Snapshot directories.
    public let snapshots: ArchiveSnapshotsEntry

    public init(
        count: Int,
        referencesPath: String = "artifacts/references.jsonl",
        snapshots: ArchiveSnapshotsEntry = ArchiveSnapshotsEntry()
    ) {
        self.count = count
        self.referencesPath = referencesPath
        self.snapshots = snapshots
    }
}

/// Metadata for artifact snapshots.
public struct ArchiveSnapshotsEntry: Codable, Sendable {
    /// Number of paper snapshots (BibTeX + PDFs).
    public let paperCount: Int

    /// Number of repository snapshots (git bundles).
    public let repoCount: Int

    /// Papers directory path.
    public let papersPath: String

    /// Repos directory path.
    public let reposPath: String

    public init(
        paperCount: Int = 0,
        repoCount: Int = 0,
        papersPath: String = "artifacts/snapshots/papers",
        reposPath: String = "artifacts/snapshots/repos"
    ) {
        self.paperCount = paperCount
        self.repoCount = repoCount
        self.papersPath = papersPath
        self.reposPath = reposPath
    }
}

// MARK: - Provenance Entry

/// Metadata for archived provenance events.
public struct ArchiveProvenanceEntry: Codable, Sendable {
    /// Number of provenance events.
    public let eventCount: Int

    /// Path to events JSONL file.
    public let eventsPath: String

    /// First event timestamp.
    public let firstEventAt: Date?

    /// Last event timestamp.
    public let lastEventAt: Date?

    public init(
        eventCount: Int,
        eventsPath: String = "provenance/events.jsonl",
        firstEventAt: Date? = nil,
        lastEventAt: Date? = nil
    ) {
        self.eventCount = eventCount
        self.eventsPath = eventsPath
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
    }
}

// MARK: - Attachments Entry

/// Metadata for archived attachments.
public struct ArchiveAttachmentsEntry: Codable, Sendable {
    /// Number of attachments.
    public let count: Int

    /// Total size in bytes.
    public let totalSize: Int64

    /// Attachments directory path.
    public let path: String

    public init(
        count: Int = 0,
        totalSize: Int64 = 0,
        path: String = "attachments"
    ) {
        self.count = count
        self.totalSize = totalSize
        self.path = path
    }
}

// MARK: - Archive Structure

/// Expected structure of a .impartarchive directory.
///
/// ```
/// MyResearch.impartarchive/
/// ├── manifest.json
/// ├── conversations/
/// │   └── {id}.jsonl              # One file per conversation
/// ├── artifacts/
/// │   ├── references.jsonl
/// │   └── snapshots/              # Cached content
/// │       ├── papers/             # BibTeX + PDFs
/// │       └── repos/              # Git bundles
/// ├── provenance/
/// │   └── events.jsonl            # Complete event log
/// └── attachments/
///     └── {sha256}.{ext}          # Content-addressed
/// ```
public enum ArchiveStructure {
    public static let manifestFileName = "manifest.json"
    public static let conversationsDirectory = "conversations"
    public static let artifactsDirectory = "artifacts"
    public static let artifactReferencesFile = "artifacts/references.jsonl"
    public static let artifactSnapshotsDirectory = "artifacts/snapshots"
    public static let papersSnapshotsDirectory = "artifacts/snapshots/papers"
    public static let reposSnapshotsDirectory = "artifacts/snapshots/repos"
    public static let provenanceDirectory = "provenance"
    public static let provenanceEventsFile = "provenance/events.jsonl"
    public static let attachmentsDirectory = "attachments"

    /// Get the path for a conversation file.
    public static func conversationPath(id: UUID) -> String {
        "\(conversationsDirectory)/\(id.uuidString.lowercased()).jsonl"
    }

    /// Get the path for a content-addressed attachment.
    public static func attachmentPath(sha256: String, ext: String) -> String {
        "\(attachmentsDirectory)/\(sha256).\(ext)"
    }
}
