//
//  ConversationOperationConsumer.swift
//  MessageManagerCore
//
//  Research-conversation HTTP routes enqueue a ConversationOperation and
//  return a queue acknowledgement. Nothing popped that queue, so the
//  reserved id was never written. This consumer persists the same records
//  the native impart verbs write, using the id the route already returned.
//

import Foundation
import ImpressLogging

@MainActor
enum ConversationOperationConsumer {
    private static var running = false
    private static var again = false
    private static let repository = ResearchConversationRepository(persistenceController: .shared)
    private static let provenance = ProvenanceService.shared

    static func scheduleDrain() {
        again = true
        guard !running else { return }
        running = true
        Task { @MainActor in
            while again {
                again = false
                await drain()
            }
            running = false
        }
    }

    static func drain() async {
        let registry = ConversationRegistry.shared
        let ids = registry.entitiesWithPendingOperations
        for id in ids {
            while let operation = registry.popOperation(for: id) {
                await apply(operation, conversationID: id)
            }
        }
    }

    private static func apply(_ operation: ConversationOperation, conversationID: UUID) async {
        logInfo(
            "Applying queued \(operation.operationDescription) to \(conversationID)",
            category: "research-native"
        )
        do {
            switch operation {
            case .create(let title, let participants):
                let conversation = ResearchConversation(
                    id: conversationID, title: title, participants: participants)
                try await repository.save(conversation)
                logInfo("Save: created research conversation \(conversationID)", category: "research-native")
            case .addMessage(let senderRole, let senderId, let content, let causationId):
                let role = ResearchSenderRole(rawValue: senderRole) ?? .human
                _ = try await repository.appendMessage(
                    to: conversationID, content: content, senderRole: role,
                    senderId: senderId, causationId: causationId)
                logInfo("Save: appended message to \(conversationID)", category: "research-native")
            case .branch(let fromMessageId, let title):
                guard let parent = try await repository.fetchConversation(id: conversationID) else {
                    logInfo("Branch refused: \(conversationID) was not found", category: "research-native")
                    return
                }
                let branch = ResearchConversation(
                    title: title, participants: parent.participants, parentConversationId: conversationID)
                try await repository.save(branch)
                _ = await provenance.record(ProvenanceEvent(
                    conversationId: conversationID.uuidString,
                    payload: .conversationBranched(
                        fromMessageId: fromMessageId.uuidString,
                        reason: "Queued branch",
                        branchTitle: title),
                    actorId: "automation"))
                logInfo("Save: branched \(branch.id) from \(conversationID)", category: "research-native")
            case .update(let title, let summary, let tags):
                guard var conversation = try await repository.fetchConversation(id: conversationID) else {
                    logInfo("Update refused: \(conversationID) was not found", category: "research-native")
                    return
                }
                if let title { conversation.title = title }
                if let summary { conversation.summaryText = summary }
                if let tags { conversation.tags = tags }
                conversation.lastActivityAt = Date()
                try await repository.save(conversation)
                logInfo("Save: updated research conversation \(conversationID)", category: "research-native")
            case .archive:
                try await repository.archive(conversationID)
                logInfo("Save: archived research conversation \(conversationID)", category: "research-native")
            case .recordArtifact(let uri, _, let displayName):
                guard let artifact = ArtifactURI(uri: uri) else {
                    logInfo("Artifact refused: \(uri) is not an impress URI", category: "research-native")
                    return
                }
                try await repository.recordArtifact(
                    uri: artifact, title: displayName ?? uri, in: conversationID)
                logInfo("Save: recorded artifact on \(conversationID)", category: "research-native")
            case .recordDecision(let description, let rationale):
                guard try await repository.fetchConversation(id: conversationID) != nil else {
                    logInfo("Decision refused: \(conversationID) was not found", category: "research-native")
                    return
                }
                let event = await provenance.recordDecision(
                    conversationId: conversationID.uuidString,
                    decisionId: UUID().uuidString,
                    description: description,
                    rationale: rationale,
                    alternativesConsidered: [],
                    actorId: "automation")
                let stored = await provenance.eventsForConversation(conversationID.uuidString)
                    .contains { $0.id == event.id }
                logInfo(
                    "Save: decision provenance for \(conversationID) stored=\(stored)",
                    category: "research-native"
                )
            }
            NotificationCenter.default.post(name: .impartResearchConversationsDidChange, object: nil)
        } catch {
            logInfo(
                "Queued \(operation.operationDescription) failed: \(error.localizedDescription)",
                category: "research-native"
            )
        }
    }
}
