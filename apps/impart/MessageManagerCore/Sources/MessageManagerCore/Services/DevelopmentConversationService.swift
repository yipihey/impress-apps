//
//  DevelopmentConversationService.swift
//  MessageManagerCore
//
//  Service for managing development conversations with planning mode support.
//  Provides CRUD operations for conversations, messages, and artifacts.
//

import CoreData
import Foundation
import OSLog

// MARK: - Development Conversation Service

/// Service for managing Claude Code-style development conversations.
@MainActor
public final class DevelopmentConversationService: Sendable {

    private let persistence: PersistenceController

    public init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    // MARK: - Conversation Management

    /// Create a new development conversation.
    /// - Parameters:
    ///   - title: Conversation title
    ///   - mode: Conversation mode (defaults to interactive)
    ///   - artifact: Optional initial artifact to attach
    /// - Returns: The created conversation's ID
    public func createConversation(
        title: String,
        mode: ConversationMode = .interactive,
        artifact: DirectoryArtifact? = nil
    ) async throws -> UUID {
        try await persistence.performBackgroundTask { context in
            let conversation = CDResearchConversation(context: context)
            conversation.id = UUID()
            conversation.title = title
            conversation.createdAt = Date()
            conversation.lastActivityAt = Date()
            conversation.mode = mode.rawValue
            conversation.participantsJSON = "[]"
            conversation.isArchived = false

            if mode == .planning {
                conversation.planningSessionId = UUID()
            }

            // Attach directory artifact if provided
            if let artifact = artifact {
                let cdArtifact = CDArtifactReference(context: context)
                cdArtifact.id = artifact.id
                cdArtifact.artifactType = ArtifactType.externalDirectory.rawValue
                cdArtifact.displayName = artifact.name
                cdArtifact.bookmarkData = artifact.bookmarkData
                cdArtifact.createdAt = artifact.createdAt
                cdArtifact.isResolved = true
                // Note: sourceConversation relationship set automatically via inverse
                conversation.artifacts = [cdArtifact]
            }

            try context.save()

            Logger.research.info("Created development conversation: \(title) [mode: \(mode.rawValue)]")
            return conversation.id
        }
    }

    /// Start a planning session within an existing conversation.
    /// - Parameters:
    ///   - conversationId: Parent conversation ID
    ///   - title: Planning session title
    /// - Returns: The created planning conversation's ID
    public func startPlanningSession(
        conversationId: UUID,
        title: String
    ) async throws -> UUID {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let parent = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            // Create a new planning conversation as a branch
            let planning = CDResearchConversation(context: context)
            planning.id = UUID()
            planning.title = title
            planning.createdAt = Date()
            planning.lastActivityAt = Date()
            planning.mode = ConversationMode.planning.rawValue
            planning.planningSessionId = UUID()
            planning.parentConversation = parent
            planning.participantsJSON = parent.participantsJSON
            planning.isArchived = false

            // Copy artifacts from parent
            if let parentArtifacts = parent.artifacts {
                var newArtifacts: Set<CDArtifactReference> = []
                for artifact in parentArtifacts {
                    let copy = CDArtifactReference(context: context)
                    copy.id = UUID()
                    copy.uri = artifact.uri
                    copy.artifactType = artifact.artifactType
                    copy.displayName = artifact.displayName
                    copy.bookmarkData = artifact.bookmarkData
                    copy.createdAt = Date()
                    copy.introducedBy = artifact.introducedBy
                    copy.isResolved = artifact.isResolved
                    newArtifacts.insert(copy)
                }
                planning.artifacts = newArtifacts
            }

            try context.save()

            Logger.research.info("Started planning session: \(title)")
            return planning.id
        }
    }

    /// Update conversation mode.
    /// - Parameters:
    ///   - conversationId: Conversation ID
    ///   - mode: New mode
    public func updateMode(
        conversationId: UUID,
        mode: ConversationMode
    ) async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let conversation = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            conversation.mode = mode.rawValue
            conversation.lastActivityAt = Date()

            try context.save()
        }
    }

    // MARK: - Message Management

    /// Add a message to a conversation.
    /// - Parameters:
    ///   - conversationId: Target conversation ID
    ///   - content: Message content (Markdown)
    ///   - role: Sender role ("user" or "assistant")
    ///   - intent: Message intent
    /// - Returns: The created message's ID
    public func addMessage(
        to conversationId: UUID,
        content: String,
        role: ResearchSenderRole,
        intent: MessageIntent = .converse
    ) async throws -> UUID {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let conversation = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            // Get next sequence number
            let sequence = (conversation.messages?.count ?? 0) + 1

            let message = CDResearchMessage(context: context)
            message.id = UUID()
            message.contentMarkdown = content
            message.senderRoleRaw = role.rawValue
            message.senderId = role == .human ? "user" : "assistant"
            message.sentAt = Date()
            message.intent = intent.rawValue
            message.conversationSequence = Int32(sequence)
            message.conversation = conversation

            conversation.lastActivityAt = Date()

            try context.save()

            return message.id
        }
    }

    // MARK: - Artifact Management

    /// Attach a directory artifact to a conversation.
    /// - Parameters:
    ///   - conversationId: Target conversation ID
    ///   - artifact: Directory artifact to attach
    public func attachArtifact(
        to conversationId: UUID,
        artifact: DirectoryArtifact
    ) async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let conversation = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            let cdArtifact = CDArtifactReference(context: context)
            cdArtifact.id = artifact.id
            cdArtifact.artifactType = ArtifactType.externalDirectory.rawValue
            cdArtifact.displayName = artifact.name
            cdArtifact.bookmarkData = artifact.bookmarkData
            cdArtifact.createdAt = artifact.createdAt
            cdArtifact.isResolved = true

            var artifacts = conversation.artifacts ?? []
            artifacts.insert(cdArtifact)
            conversation.artifacts = artifacts

            try context.save()

            Logger.research.info("Attached artifact: \(artifact.name) to conversation")
        }
    }

    /// Remove an artifact from a conversation.
    /// - Parameters:
    ///   - conversationId: Conversation ID
    ///   - artifactId: Artifact ID to remove
    public func removeArtifact(
        from conversationId: UUID,
        artifactId: UUID
    ) async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDArtifactReference.fetchRequest()
            request.predicate = NSPredicate(
                format: "id == %@ AND sourceConversation.id == %@",
                artifactId as CVarArg,
                conversationId as CVarArg
            )

            guard let artifact = try context.fetch(request).first else {
                throw DevelopmentConversationError.artifactNotFound(artifactId)
            }

            context.delete(artifact)
            try context.save()
        }
    }

    // MARK: - Fetch Operations

    /// Fetch conversations with optional filters.
    /// - Parameters:
    ///   - mode: Optional mode filter
    ///   - includeArchived: Whether to include archived conversations
    ///   - limit: Maximum results
    /// - Returns: Array of development conversations
    public func fetchConversations(
        mode: ConversationMode? = nil,
        includeArchived: Bool = false,
        limit: Int = 50
    ) async throws -> [DevelopmentConversation] {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()

            var predicates: [NSPredicate] = []

            if let mode = mode {
                predicates.append(NSPredicate(format: "mode == %@", mode.rawValue))
            }

            if !includeArchived {
                predicates.append(NSPredicate(format: "isArchived == NO"))
            }

            // Only root conversations (not branches)
            predicates.append(NSPredicate(format: "parentConversation == nil"))

            if !predicates.isEmpty {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            }

            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDResearchConversation.lastActivityAt, ascending: false)]
            request.fetchLimit = limit

            let results = try context.fetch(request)
            return results.map { $0.toDevelopmentConversation() }
        }
    }

    /// Fetch a single conversation by ID.
    /// - Parameter id: Conversation ID
    /// - Returns: The conversation if found
    public func fetchConversation(id: UUID) async throws -> DevelopmentConversation? {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            return try context.fetch(request).first?.toDevelopmentConversation()
        }
    }

    /// Fetch planning sessions for a conversation.
    /// - Parameter conversationId: Parent conversation ID
    /// - Returns: Array of planning session conversations
    public func fetchPlanningSessions(
        for conversationId: UUID
    ) async throws -> [DevelopmentConversation] {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "parentConversation.id == %@ AND mode == %@",
                conversationId as CVarArg,
                ConversationMode.planning.rawValue
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDResearchConversation.createdAt, ascending: true)]

            let results = try context.fetch(request)
            return results.map { $0.toDevelopmentConversation() }
        }
    }

    /// Fetch messages for a conversation.
    /// - Parameters:
    ///   - conversationId: Conversation ID
    ///   - limit: Maximum messages to fetch
    /// - Returns: Array of messages
    public func fetchMessages(
        for conversationId: UUID,
        limit: Int = 100
    ) async throws -> [DevelopmentMessage] {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchMessage.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", conversationId as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CDResearchMessage.conversationSequence, ascending: true)]
            request.fetchLimit = limit

            let results = try context.fetch(request)
            return results.map { $0.toDevelopmentMessage() }
        }
    }

    /// Fetch artifacts for a conversation.
    /// - Parameter conversationId: Conversation ID
    /// - Returns: Array of directory artifacts
    public func fetchArtifacts(
        for conversationId: UUID
    ) async throws -> [DirectoryArtifact] {
        try await persistence.performBackgroundTask { context in
            let request = CDArtifactReference.fetchRequest()
            request.predicate = NSPredicate(
                format: "sourceConversation.id == %@ AND artifactType == %@",
                conversationId as CVarArg,
                ArtifactType.externalDirectory.rawValue
            )

            let results = try context.fetch(request)
            return results.compactMap { cdArtifact -> DirectoryArtifact? in
                guard let bookmarkData = cdArtifact.bookmarkData,
                      let displayName = cdArtifact.displayName else {
                    return nil
                }
                return DirectoryArtifact(
                    id: cdArtifact.id,
                    name: displayName,
                    bookmarkData: bookmarkData,
                    createdAt: cdArtifact.createdAt ?? Date(),
                    lastAccessedAt: cdArtifact.lastAccessedAt ?? Date()
                )
            }
        }
    }

    // MARK: - Archive Operations

    /// Archive a conversation.
    /// - Parameter conversationId: Conversation ID
    public func archiveConversation(_ conversationId: UUID) async throws {
        try await updateMode(conversationId: conversationId, mode: .archival)
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let conversation = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            conversation.isArchived = true
            try context.save()
        }
    }

    /// Delete a conversation.
    /// - Parameter conversationId: Conversation ID
    public func deleteConversation(_ conversationId: UUID) async throws {
        try await persistence.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)

            guard let conversation = try context.fetch(request).first else {
                throw DevelopmentConversationError.notFound(conversationId)
            }

            context.delete(conversation)
            try context.save()

            Logger.research.info("Deleted conversation: \(conversationId)")
        }
    }
}

// MARK: - Supporting Types

/// A development conversation DTO.
public struct DevelopmentConversation: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let mode: ConversationMode
    public let createdAt: Date
    public let lastActivityAt: Date
    public let messageCount: Int
    public let artifactCount: Int
    public let planningSessionId: UUID?
    public let isArchived: Bool
    public let parentConversationId: UUID?

    public init(
        id: UUID,
        title: String,
        mode: ConversationMode,
        createdAt: Date,
        lastActivityAt: Date,
        messageCount: Int,
        artifactCount: Int,
        planningSessionId: UUID?,
        isArchived: Bool,
        parentConversationId: UUID?
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.artifactCount = artifactCount
        self.planningSessionId = planningSessionId
        self.isArchived = isArchived
        self.parentConversationId = parentConversationId
    }
}

/// A development message DTO.
public struct DevelopmentMessage: Identifiable, Sendable {
    public let id: UUID
    public let content: String
    public let role: ResearchSenderRole
    public let intent: MessageIntent
    public let createdAt: Date
    public let sequence: Int

    public init(
        id: UUID,
        content: String,
        role: ResearchSenderRole,
        intent: MessageIntent,
        createdAt: Date,
        sequence: Int
    ) {
        self.id = id
        self.content = content
        self.role = role
        self.intent = intent
        self.createdAt = createdAt
        self.sequence = sequence
    }
}

/// Errors for development conversation operations.
public enum DevelopmentConversationError: LocalizedError {
    case notFound(UUID)
    case artifactNotFound(UUID)
    case invalidMode

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Conversation not found: \(id)"
        case .artifactNotFound(let id):
            return "Artifact not found: \(id)"
        case .invalidMode:
            return "Invalid conversation mode"
        }
    }
}

// MARK: - Core Data Extensions

extension CDResearchConversation {
    func toDevelopmentConversation() -> DevelopmentConversation {
        DevelopmentConversation(
            id: id,
            title: title,
            mode: ConversationMode(rawValue: mode) ?? .interactive,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            messageCount: messages?.count ?? 0,
            artifactCount: artifacts?.count ?? 0,
            planningSessionId: planningSessionId,
            isArchived: isArchived,
            parentConversationId: parentConversation?.id
        )
    }
}

extension CDResearchMessage {
    func toDevelopmentMessage() -> DevelopmentMessage {
        DevelopmentMessage(
            id: id,
            content: contentMarkdown,
            role: senderRole,
            intent: MessageIntent(rawValue: intent) ?? .converse,
            createdAt: sentAt,
            sequence: Int(conversationSequence)
        )
    }
}
