//
//  ResearchConversationRepository.swift
//  MessageManagerCore
//
//  Core Data repository for research conversations.
//  Provides CRUD operations and queries for research dialogues.
//

import CoreData
import Foundation
import OSLog

private let repositoryLogger = Logger(subsystem: "com.impart", category: "research-repository")

// MARK: - Research Conversation Repository

/// Actor for managing research conversation persistence.
public actor ResearchConversationRepository {

    private let persistenceController: PersistenceController

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
    }

    // MARK: - Conversation Operations

    /// Fetch all conversations, sorted by last activity.
    public func fetchConversations(
        includeArchived: Bool = false
    ) async throws -> [ResearchConversation] {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastActivityAt", ascending: false)
            ]

            if !includeArchived {
                request.predicate = NSPredicate(format: "isArchived == NO")
            }

            let results = try context.fetch(request)
            return results.map { $0.toDTO() }
        }
    }

    /// Fetch a single conversation by ID.
    public func fetchConversation(id: UUID) async throws -> ResearchConversation? {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1

            guard let result = try context.fetch(request).first else {
                return nil
            }
            return result.toDTO()
        }
    }

    /// Save a conversation.
    public func save(_ conversation: ResearchConversation) async throws {
        try await persistenceController.performBackgroundTask { context in
            // Check if it exists
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversation.id as CVarArg)
            request.fetchLimit = 1

            let cd: CDResearchConversation
            if let existing = try context.fetch(request).first {
                cd = existing
            } else {
                cd = CDResearchConversation(context: context)
                cd.id = conversation.id
            }

            // Update fields
            cd.title = conversation.title
            cd.setParticipants(conversation.participants)
            cd.createdAt = conversation.createdAt
            cd.lastActivityAt = conversation.lastActivityAt
            cd.summaryText = conversation.summaryText
            cd.isArchived = conversation.isArchived
            cd.setTags(conversation.tags)

            // Handle parent relationship
            if let parentId = conversation.parentConversationId {
                let parentRequest = CDResearchConversation.fetchRequest()
                parentRequest.predicate = NSPredicate(format: "id == %@", parentId as CVarArg)
                parentRequest.fetchLimit = 1
                cd.parentConversation = try context.fetch(parentRequest).first
            }

            try context.save()
            repositoryLogger.info("Saved conversation: \(conversation.id)")
        }
    }

    /// Delete a conversation.
    public func delete(_ conversationId: UUID) async throws {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
            request.fetchLimit = 1

            guard let conversation = try context.fetch(request).first else {
                return
            }

            context.delete(conversation)
            try context.save()
            repositoryLogger.info("Deleted conversation: \(conversationId)")
        }
    }

    /// Archive a conversation.
    public func archive(_ conversationId: UUID) async throws {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
            request.fetchLimit = 1

            guard let conversation = try context.fetch(request).first else {
                return
            }

            conversation.isArchived = true
            try context.save()
            repositoryLogger.info("Archived conversation: \(conversationId)")
        }
    }

    // MARK: - Message Operations

    /// Fetch messages for a conversation.
    public func fetchMessages(
        for conversationId: UUID
    ) async throws -> [ResearchMessage] {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchMessage.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", conversationId as CVarArg)
            request.sortDescriptors = [
                NSSortDescriptor(key: "conversationSequence", ascending: true)
            ]

            let results = try context.fetch(request)
            return results.map { $0.toDTO() }
        }
    }

    /// Save a message to a conversation.
    public func saveMessage(
        _ message: ResearchMessage,
        to conversationId: UUID
    ) async throws {
        try await persistenceController.performBackgroundTask { context in
            // Fetch the conversation
            let convRequest = CDResearchConversation.fetchRequest()
            convRequest.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
            convRequest.fetchLimit = 1

            guard let conversation = try context.fetch(convRequest).first else {
                throw RepositoryError.conversationNotFound(conversationId)
            }

            // Check if message exists
            let msgRequest = CDResearchMessage.fetchRequest()
            msgRequest.predicate = NSPredicate(format: "id == %@", message.id as CVarArg)
            msgRequest.fetchLimit = 1

            let cd: CDResearchMessage
            if let existing = try context.fetch(msgRequest).first {
                cd = existing
            } else {
                cd = CDResearchMessage(context: context)
                cd.id = message.id
            }

            // Update fields
            cd.conversationSequence = Int32(message.sequence)
            cd.senderRole = message.senderRole
            cd.senderId = message.senderId
            cd.modelUsed = message.modelUsed
            cd.contentMarkdown = message.contentMarkdown
            cd.sentAt = message.sentAt
            cd.correlationId = message.correlationId
            cd.causationId = message.causationId
            cd.isSideConversationSynthesis = message.isSideConversationSynthesis
            cd.tokenCount = Int32(message.tokenCount ?? 0)
            cd.processingDurationMs = Int32(message.processingDurationMs ?? 0)
            cd.conversation = conversation

            // Update conversation last activity
            conversation.lastActivityAt = message.sentAt

            try context.save()
            repositoryLogger.info("Saved message \(message.id) to conversation \(conversationId)")
        }
    }

    /// Delete a message.
    public func deleteMessage(_ messageId: UUID) async throws {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchMessage.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
            request.fetchLimit = 1

            guard let message = try context.fetch(request).first else {
                return
            }

            context.delete(message)
            try context.save()
            repositoryLogger.info("Deleted message: \(messageId)")
        }
    }

    // MARK: - Search

    /// Search conversations by title or content.
    public func searchConversations(
        query: String
    ) async throws -> [ResearchConversation] {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchConversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "title CONTAINS[cd] %@ OR summaryText CONTAINS[cd] %@",
                query, query
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastActivityAt", ascending: false)
            ]

            let results = try context.fetch(request)
            return results.map { $0.toDTO() }
        }
    }

    /// Search messages by content.
    public func searchMessages(
        query: String,
        in conversationId: UUID? = nil
    ) async throws -> [ResearchMessage] {
        try await persistenceController.performBackgroundTask { context in
            let request = CDResearchMessage.fetchRequest()

            var predicates: [NSPredicate] = [
                NSPredicate(format: "contentMarkdown CONTAINS[cd] %@", query)
            ]

            if let convId = conversationId {
                predicates.append(NSPredicate(format: "conversation.id == %@", convId as CVarArg))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "sentAt", ascending: false)
            ]

            let results = try context.fetch(request)
            return results.map { $0.toDTO() }
        }
    }

    // MARK: - Statistics

    /// Get statistics for a conversation.
    public func getStatistics(
        for conversationId: UUID
    ) async throws -> ResearchConversationSummary? {
        try await persistenceController.performBackgroundTask { context in
            let convRequest = CDResearchConversation.fetchRequest()
            convRequest.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
            convRequest.fetchLimit = 1

            guard let conversation = try context.fetch(convRequest).first else {
                return nil
            }

            let messages = conversation.sortedMessages
            let humanCount = messages.filter { $0.senderRole == .human }.count
            let counselCount = messages.filter { $0.senderRole == .counsel }.count
            let totalTokens = messages.reduce(0) { $0 + Int($1.tokenCount) }

            let duration: TimeInterval
            if let first = messages.first, let last = messages.last {
                duration = last.sentAt.timeIntervalSince(first.sentAt)
            } else {
                duration = 0
            }

            let artifacts = conversation.artifacts ?? []
            let paperCount = artifacts.filter { $0.type == .paper }.count
            let repoCount = artifacts.filter { $0.type == .repository }.count

            return ResearchConversationSummary(
                messageCount: messages.count,
                humanMessageCount: humanCount,
                counselMessageCount: counselCount,
                artifactCount: artifacts.count,
                paperCount: paperCount,
                repositoryCount: repoCount,
                totalTokens: totalTokens,
                duration: duration,
                branchCount: conversation.childConversations?.count ?? 0
            )
        }
    }
}

// MARK: - Repository Errors

/// Errors from the research conversation repository.
public enum RepositoryError: LocalizedError {
    case conversationNotFound(UUID)
    case messageNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        }
    }
}
