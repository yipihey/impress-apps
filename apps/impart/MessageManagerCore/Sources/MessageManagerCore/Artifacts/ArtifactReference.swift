//
//  ArtifactReference.swift
//  MessageManagerCore
//
//  Versioned external resource reference for research conversations.
//  Artifacts maintain full provenance tracking for reproducibility.
//

import Foundation

// MARK: - Artifact Reference

/// A versioned reference to an external resource.
/// Artifacts can be papers, code repositories, datasets, documents, etc.
/// Every reference captures a version for reproducibility.
public struct ArtifactReference: Identifiable, Codable, Sendable, Equatable {
    /// Unique identifier for this reference
    public let id: UUID

    /// The impress:// URI for this artifact
    public let uri: ArtifactURI

    /// Human-readable display name
    public let displayName: String

    /// When this reference was created
    public let createdAt: Date

    /// Who/what introduced this reference (user ID or agent ID)
    public let introducedBy: String?

    /// The conversation where this artifact was first introduced
    public let sourceConversationId: UUID?

    /// The message where this artifact was first introduced
    public let sourceMessageId: UUID?

    /// Additional metadata about the artifact
    public let metadata: ArtifactMetadata?

    /// Whether this artifact has been resolved (content fetched/verified)
    public var isResolved: Bool

    /// Last time this artifact was accessed or verified
    public var lastAccessedAt: Date?

    /// Initialize a new artifact reference.
    public init(
        id: UUID = UUID(),
        uri: ArtifactURI,
        displayName: String,
        createdAt: Date = Date(),
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        metadata: ArtifactMetadata? = nil,
        isResolved: Bool = false,
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.uri = uri
        self.displayName = displayName
        self.createdAt = createdAt
        self.introducedBy = introducedBy
        self.sourceConversationId = sourceConversationId
        self.sourceMessageId = sourceMessageId
        self.metadata = metadata
        self.isResolved = isResolved
        self.lastAccessedAt = lastAccessedAt
    }

    /// Initialize from a URI string with automatic display name.
    public init?(
        uriString: String,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        metadata: ArtifactMetadata? = nil
    ) {
        guard let uri = ArtifactURI(uri: uriString) else {
            return nil
        }

        self.init(
            uri: uri,
            displayName: metadata?.title ?? uri.displayName,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// The artifact type.
    public var type: ArtifactType {
        uri.type
    }

    /// The URI string.
    public var uriString: String {
        uri.uri
    }

    /// Version identifier if present.
    public var version: String? {
        uri.version
    }

    /// Create a copy with updated resolution status.
    public func resolved(at date: Date = Date()) -> ArtifactReference {
        var copy = self
        copy.isResolved = true
        copy.lastAccessedAt = date
        return copy
    }

    /// Create a copy with new metadata.
    public func with(metadata: ArtifactMetadata) -> ArtifactReference {
        ArtifactReference(
            id: id,
            uri: uri,
            displayName: metadata.title ?? displayName,
            createdAt: createdAt,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata,
            isResolved: isResolved,
            lastAccessedAt: lastAccessedAt
        )
    }
}

// MARK: - Convenience Initializers

public extension ArtifactReference {
    /// Create a paper reference from a cite key.
    static func paper(
        citeKey: String,
        title: String? = nil,
        authors: [String]? = nil,
        year: Int? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) -> ArtifactReference {
        let metadata = ArtifactMetadata(
            title: title,
            authors: authors,
            date: year.map { Calendar.current.date(from: DateComponents(year: $0)) } ?? nil,
            doi: doi,
            arxivId: arxivId
        )

        return ArtifactReference(
            uri: .paper(citeKey: citeKey),
            displayName: title ?? citeKey,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// Create a repository reference.
    static func repository(
        host: String,
        owner: String,
        repo: String,
        commit: String,
        title: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) -> ArtifactReference {
        let metadata = ArtifactMetadata(
            title: title ?? "\(owner)/\(repo)"
        )

        return ArtifactReference(
            uri: .repository(host: host, owner: owner, repo: repo, commit: commit),
            displayName: title ?? "\(owner)/\(repo)",
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// Create a document reference.
    static func document(
        id documentId: String,
        title: String,
        version: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) -> ArtifactReference {
        let metadata = ArtifactMetadata(title: title)

        return ArtifactReference(
            uri: .document(id: documentId, version: version),
            displayName: title,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// Create a dataset reference.
    static func dataset(
        provider: String,
        dataset: String,
        version: String,
        title: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) -> ArtifactReference {
        let metadata = ArtifactMetadata(title: title ?? dataset)

        return ArtifactReference(
            uri: .dataset(provider: provider, dataset: dataset, version: version),
            displayName: title ?? dataset,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }
}

// MARK: - Artifact Collection

/// A collection of artifact references with lookup helpers.
public struct ArtifactCollection: Codable, Sendable {
    /// All artifacts in the collection
    public private(set) var artifacts: [ArtifactReference]

    /// Index by URI for fast lookup
    private var byURI: [String: Int]

    /// Index by ID for fast lookup
    private var byId: [UUID: Int]

    /// Initialize an empty collection.
    public init() {
        self.artifacts = []
        self.byURI = [:]
        self.byId = [:]
    }

    /// Initialize with existing artifacts.
    public init(artifacts: [ArtifactReference]) {
        self.artifacts = artifacts
        self.byURI = [:]
        self.byId = [:]
        for (index, artifact) in artifacts.enumerated() {
            byURI[artifact.uriString] = index
            byId[artifact.id] = index
        }
    }

    /// Number of artifacts.
    public var count: Int {
        artifacts.count
    }

    /// Whether the collection is empty.
    public var isEmpty: Bool {
        artifacts.isEmpty
    }

    /// Add an artifact to the collection.
    /// Returns the existing artifact if one with the same URI already exists.
    @discardableResult
    public mutating func add(_ artifact: ArtifactReference) -> ArtifactReference {
        if let existingIndex = byURI[artifact.uriString] {
            return artifacts[existingIndex]
        }

        let index = artifacts.count
        artifacts.append(artifact)
        byURI[artifact.uriString] = index
        byId[artifact.id] = index
        return artifact
    }

    /// Get an artifact by URI.
    public func artifact(forURI uri: String) -> ArtifactReference? {
        guard let index = byURI[uri] else { return nil }
        return artifacts[index]
    }

    /// Get an artifact by ID.
    public func artifact(forId id: UUID) -> ArtifactReference? {
        guard let index = byId[id] else { return nil }
        return artifacts[index]
    }

    /// Get all artifacts of a specific type.
    public func artifacts(ofType type: ArtifactType) -> [ArtifactReference] {
        artifacts.filter { $0.type == type }
    }

    /// Get all artifacts introduced by a specific actor.
    public func artifacts(introducedBy actorId: String) -> [ArtifactReference] {
        artifacts.filter { $0.introducedBy == actorId }
    }

    /// Get all artifacts from a specific conversation.
    public func artifacts(fromConversation conversationId: UUID) -> [ArtifactReference] {
        artifacts.filter { $0.sourceConversationId == conversationId }
    }

    /// Update an artifact in the collection.
    public mutating func update(_ artifact: ArtifactReference) {
        guard let index = byId[artifact.id] else { return }
        artifacts[index] = artifact
    }

    /// Remove an artifact by ID.
    public mutating func remove(id: UUID) {
        guard let index = byId[id] else { return }
        let artifact = artifacts[index]
        artifacts.remove(at: index)
        byURI.removeValue(forKey: artifact.uriString)
        byId.removeValue(forKey: id)

        // Rebuild indices for elements after the removed one
        for i in index..<artifacts.count {
            let a = artifacts[i]
            byURI[a.uriString] = i
            byId[a.id] = i
        }
    }

    /// Get papers (convenience accessor).
    public var papers: [ArtifactReference] {
        artifacts(ofType: .paper)
    }

    /// Get repositories (convenience accessor).
    public var repositories: [ArtifactReference] {
        artifacts(ofType: .repository)
    }

    /// Get documents (convenience accessor).
    public var documents: [ArtifactReference] {
        artifacts(ofType: .document)
    }

    /// Get datasets (convenience accessor).
    public var datasets: [ArtifactReference] {
        artifacts(ofType: .dataset)
    }
}

// MARK: - Codable Conformance for ArtifactCollection

extension ArtifactCollection {
    enum CodingKeys: String, CodingKey {
        case artifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let artifacts = try container.decode([ArtifactReference].self, forKey: .artifacts)
        self.init(artifacts: artifacts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artifacts, forKey: .artifacts)
    }
}
