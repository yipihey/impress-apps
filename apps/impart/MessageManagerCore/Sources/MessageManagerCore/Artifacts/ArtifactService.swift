//
//  ArtifactService.swift
//  MessageManagerCore
//
//  Actor-based service for managing artifact references across research conversations.
//  Handles artifact lifecycle, resolution, and mention tracking.
//

import CoreData
import Foundation
import OSLog

private let artifactLogger = Logger(subsystem: "com.impart", category: "artifacts")

// MARK: - Artifact Service

/// Actor-based service for managing artifacts in research conversations.
public actor ArtifactService {

    // MARK: - Properties

    /// Persistence controller for Core Data operations
    private let persistenceController: PersistenceController

    /// In-memory cache of recently accessed artifacts
    private var artifactCache: [String: ArtifactReference] = [:]

    /// Cache expiration interval
    private let cacheExpiration: TimeInterval = 300 // 5 minutes

    /// Last cache cleanup time
    private var lastCacheCleanup: Date = Date()

    // MARK: - Initialization

    /// Initialize with a persistence controller.
    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - Artifact CRUD

    /// Create or retrieve an artifact reference.
    /// If an artifact with the same URI exists, returns the existing one.
    public func getOrCreateArtifact(
        uri: ArtifactURI,
        displayName: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        metadata: ArtifactMetadata? = nil
    ) async throws -> ArtifactReference {
        // Check cache first
        if let cached = artifactCache[uri.uri] {
            return cached
        }

        let context = persistenceController.container.viewContext

        // Check if artifact exists in Core Data
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uri == %@", uri.uri)
        fetchRequest.fetchLimit = 1

        let existing = try context.fetch(fetchRequest).first

        if let existing = existing {
            let artifact = existing.toArtifactReference()
            artifactCache[uri.uri] = artifact
            return artifact
        }

        // Create new artifact
        let cdArtifact = CDArtifactReference(context: context)
        cdArtifact.id = UUID()
        cdArtifact.uri = uri.uri
        cdArtifact.artifactType = uri.type.rawValue
        cdArtifact.displayName = displayName ?? uri.displayName
        cdArtifact.versionIdentifier = uri.version
        cdArtifact.createdAt = Date()
        cdArtifact.introducedBy = introducedBy
        cdArtifact.sourceConversationId = sourceConversationId
        cdArtifact.sourceMessageId = sourceMessageId
        cdArtifact.isResolved = false

        if let metadata = metadata,
           let data = try? JSONEncoder().encode(metadata),
           let jsonString = String(data: data, encoding: .utf8) {
            cdArtifact.metadataJSON = jsonString
        }

        try context.save()
        artifactLogger.info("Created artifact: \(uri.uri)")

        let artifact = cdArtifact.toArtifactReference()
        artifactCache[uri.uri] = artifact
        return artifact
    }

    /// Get an artifact by URI.
    public func getArtifact(uri: String) async throws -> ArtifactReference? {
        // Check cache
        if let cached = artifactCache[uri] {
            return cached
        }

        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uri == %@", uri)
        fetchRequest.fetchLimit = 1

        guard let cdArtifact = try context.fetch(fetchRequest).first else {
            return nil
        }

        let artifact = cdArtifact.toArtifactReference()
        artifactCache[uri] = artifact
        return artifact
    }

    /// Get an artifact by ID.
    public func getArtifact(id: UUID) async throws -> ArtifactReference? {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let cdArtifact = try context.fetch(fetchRequest).first else {
            return nil
        }

        return cdArtifact.toArtifactReference()
    }

    /// Update artifact metadata.
    public func updateArtifact(
        id: UUID,
        displayName: String? = nil,
        metadata: ArtifactMetadata? = nil,
        isResolved: Bool? = nil
    ) async throws {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        guard let cdArtifact = try context.fetch(fetchRequest).first else {
            return
        }

        if let displayName = displayName {
            cdArtifact.displayName = displayName
        }

        if let metadata = metadata,
           let data = try? JSONEncoder().encode(metadata),
           let jsonString = String(data: data, encoding: .utf8) {
            cdArtifact.metadataJSON = jsonString
        }

        if let isResolved = isResolved {
            cdArtifact.isResolved = isResolved
            if isResolved {
                cdArtifact.lastAccessedAt = Date()
            }
        }

        try context.save()

        // Invalidate cache
        artifactCache.removeValue(forKey: cdArtifact.uri ?? "")
        artifactLogger.info("Updated artifact: \(id)")
    }

    /// Get all artifacts of a specific type.
    public func getArtifacts(ofType type: ArtifactType) async throws -> [ArtifactReference] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "artifactType == %@", type.rawValue)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDArtifactReference.createdAt, ascending: false)]

        let results = try context.fetch(fetchRequest)
        return results.map { $0.toArtifactReference() }
    }

    /// Get all artifacts for a conversation.
    public func getArtifacts(forConversation conversationId: UUID) async throws -> [ArtifactReference] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactReference> = CDArtifactReference.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "sourceConversationId == %@", conversationId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDArtifactReference.createdAt, ascending: true)]

        let results = try context.fetch(fetchRequest)
        return results.map { $0.toArtifactReference() }
    }

    // MARK: - Mention Tracking

    /// Record an artifact mention in a message.
    public func recordMention(
        artifactId: UUID,
        artifactURI: String,
        messageId: UUID,
        conversationId: UUID,
        mentionType: ArtifactMentionType,
        characterOffset: Int? = nil,
        characterLength: Int? = nil,
        contextSnippet: String? = nil,
        mentionedBy: String? = nil
    ) async throws -> ArtifactMention {
        let context = persistenceController.container.viewContext

        // Check if this is the first mention of the artifact in the conversation
        let existingMentionRequest: NSFetchRequest<CDArtifactMention> = CDArtifactMention.fetchRequest()
        existingMentionRequest.predicate = NSPredicate(
            format: "artifactURI == %@ AND conversationId == %@",
            artifactURI, conversationId as CVarArg
        )
        existingMentionRequest.fetchLimit = 1
        let existingCount = try context.count(for: existingMentionRequest)
        let isFirstMention = existingCount == 0

        // Create the mention
        let cdMention = CDArtifactMention(context: context)
        cdMention.id = UUID()
        cdMention.artifactId = artifactId
        cdMention.artifactURI = artifactURI
        cdMention.messageId = messageId
        cdMention.conversationId = conversationId
        cdMention.mentionTypeRaw = mentionType.rawValue
        cdMention.characterOffset = Int32(characterOffset ?? 0)
        cdMention.characterLength = Int32(characterLength ?? 0)
        cdMention.contextSnippet = contextSnippet
        cdMention.recordedAt = Date()
        cdMention.mentionedBy = mentionedBy
        cdMention.isFirstMention = isFirstMention

        try context.save()
        artifactLogger.info("Recorded mention of \(artifactURI) in message \(messageId)")

        return cdMention.toArtifactMention()
    }

    /// Get all mentions for an artifact.
    public func getMentions(forArtifact artifactURI: String) async throws -> [ArtifactMention] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactMention> = CDArtifactMention.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "artifactURI == %@", artifactURI)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDArtifactMention.recordedAt, ascending: true)]

        let results = try context.fetch(fetchRequest)
        return results.map { $0.toArtifactMention() }
    }

    /// Get all mentions in a message.
    public func getMentions(inMessage messageId: UUID) async throws -> [ArtifactMention] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactMention> = CDArtifactMention.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "messageId == %@", messageId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDArtifactMention.characterOffset, ascending: true)]

        let results = try context.fetch(fetchRequest)
        return results.map { $0.toArtifactMention() }
    }

    /// Get all mentions in a conversation.
    public func getMentions(inConversation conversationId: UUID) async throws -> [ArtifactMention] {
        let context = persistenceController.container.viewContext
        let fetchRequest: NSFetchRequest<CDArtifactMention> = CDArtifactMention.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "conversationId == %@", conversationId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \CDArtifactMention.recordedAt, ascending: true)]

        let results = try context.fetch(fetchRequest)
        return results.map { $0.toArtifactMention() }
    }

    /// Get mention statistics for a conversation.
    public func getMentionStatistics(forConversation conversationId: UUID) async throws -> MentionStatistics {
        let mentions = try await getMentions(inConversation: conversationId)
        return MentionStatistics(mentions: mentions)
    }

    // MARK: - Batch Operations

    /// Process message content and extract/record all artifact mentions.
    public func processMessageContent(
        content: String,
        messageId: UUID,
        conversationId: UUID,
        mentionedBy: String?
    ) async throws -> [ArtifactMention] {
        // Get existing artifact URIs for this conversation
        let existingArtifacts = try await getArtifacts(forConversation: conversationId)
        let existingURIs = Set(existingArtifacts.map(\.uriString))

        // Extract mentions from content
        let extractedMentions = ArtifactMentionExtractor.extractMentions(
            from: content,
            messageId: messageId,
            conversationId: conversationId,
            mentionedBy: mentionedBy,
            existingArtifacts: existingURIs
        )

        var recordedMentions: [ArtifactMention] = []

        for extracted in extractedMentions {
            // Get or create the artifact
            let artifact = try await getOrCreateArtifact(
                uri: extracted.uri,
                introducedBy: mentionedBy,
                sourceConversationId: conversationId,
                sourceMessageId: messageId
            )

            // Record the mention
            let mention = try await recordMention(
                artifactId: artifact.id,
                artifactURI: extracted.uri.uri,
                messageId: messageId,
                conversationId: conversationId,
                mentionType: extracted.mentionType,
                characterOffset: extracted.characterOffset,
                characterLength: extracted.characterLength,
                contextSnippet: extracted.contextSnippet,
                mentionedBy: mentionedBy
            )

            recordedMentions.append(mention)
        }

        return recordedMentions
    }

    // MARK: - Cache Management

    /// Clear the artifact cache.
    public func clearCache() {
        artifactCache.removeAll()
        lastCacheCleanup = Date()
        artifactLogger.debug("Artifact cache cleared")
    }

    /// Perform cache cleanup if needed.
    private func cleanupCacheIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastCacheCleanup) > cacheExpiration {
            artifactCache.removeAll()
            lastCacheCleanup = now
        }
    }
}

// MARK: - Paper-Specific Helpers

public extension ArtifactService {
    /// Create or retrieve a paper artifact from imbib data.
    func getOrCreatePaper(
        citeKey: String,
        title: String? = nil,
        authors: [String]? = nil,
        year: Int? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) async throws -> ArtifactReference {
        let metadata = ArtifactMetadata(
            title: title,
            authors: authors,
            date: year.map { Calendar.current.date(from: DateComponents(year: $0)) } ?? nil,
            doi: doi,
            arxivId: arxivId
        )

        return try await getOrCreateArtifact(
            uri: .paper(citeKey: citeKey),
            displayName: title ?? citeKey,
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// Get all paper artifacts.
    func getAllPapers() async throws -> [ArtifactReference] {
        try await getArtifacts(ofType: .paper)
    }

    /// Get papers mentioned in a conversation.
    func getPapers(forConversation conversationId: UUID) async throws -> [ArtifactReference] {
        let allArtifacts = try await getArtifacts(forConversation: conversationId)
        return allArtifacts.filter { $0.type == .paper }
    }
}

// MARK: - Repository-Specific Helpers

public extension ArtifactService {
    /// Create or retrieve a repository artifact.
    func getOrCreateRepository(
        host: String,
        owner: String,
        repo: String,
        commit: String,
        title: String? = nil,
        introducedBy: String? = nil,
        sourceConversationId: UUID? = nil,
        sourceMessageId: UUID? = nil
    ) async throws -> ArtifactReference {
        let metadata = ArtifactMetadata(title: title ?? "\(owner)/\(repo)")

        return try await getOrCreateArtifact(
            uri: .repository(host: host, owner: owner, repo: repo, commit: commit),
            displayName: title ?? "\(owner)/\(repo)",
            introducedBy: introducedBy,
            sourceConversationId: sourceConversationId,
            sourceMessageId: sourceMessageId,
            metadata: metadata
        )
    }

    /// Get all repository artifacts.
    func getAllRepositories() async throws -> [ArtifactReference] {
        try await getArtifacts(ofType: .repository)
    }
}
