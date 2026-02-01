//
//  MboxResearchConversion.swift
//  MessageManagerCore
//
//  Conversion between ResearchMessage and MboxMessage formats.
//  Enables storing research conversations in standard mbox files.
//

import Foundation

// MARK: - ResearchMessage to MboxMessage Conversion

extension ResearchMessage {
    /// Convert a research message to mbox format.
    public func toMboxMessage(userEmail: String) -> MboxMessage {
        let from: EmailAddress
        let to: [EmailAddress]

        switch senderRole {
        case .human:
            from = EmailAddress(email: userEmail)
            to = [EmailAddress(name: "AI Counsel", email: "counsel@impart.local")]

        case .counsel:
            let modelName = modelUsed ?? "unknown"
            from = EmailAddress(name: "AI Counsel (\(modelName))", email: "counsel@impart.local")
            to = [EmailAddress(email: userEmail)]

        case .system:
            from = EmailAddress(name: "System", email: "system@impart.local")
            to = [EmailAddress(email: userEmail)]
        }

        // Build subject from conversation context
        let subject = isSideConversationSynthesis
            ? "Side Conversation Synthesis"
            : "Research Message"

        return MboxMessage(
            id: id,
            messageId: "<\(id.uuidString)@impart.local>",
            inReplyTo: causationId.map { "<\($0.uuidString)@impart.local>" },
            references: [],
            from: from,
            to: to,
            subject: subject,
            date: sentAt,
            body: contentMarkdown,
            role: senderRole.toMboxRole(),
            model: modelUsed,
            artifactURI: mentionedArtifactURIs.first,
            artifactType: mentionedArtifactURIs.isEmpty ? nil : "reference"
        )
    }
}

// MARK: - MboxMessage to ResearchMessage Conversion

extension MboxMessage {
    /// Convert an mbox message to research message format.
    public func toResearchMessage(
        conversationId: UUID,
        sequence: Int
    ) -> ResearchMessage {
        ResearchMessage(
            id: id,
            conversationId: conversationId,
            sequence: sequence,
            senderRole: role.toResearchRole(),
            senderId: from.email,
            modelUsed: model,
            contentMarkdown: body,
            sentAt: date,
            correlationId: nil,
            causationId: inReplyTo.flatMap { extractUUID(from: $0) },
            isSideConversationSynthesis: false,
            sideConversationId: nil,
            tokenCount: nil,
            processingDurationMs: nil,
            mentionedArtifactURIs: artifactURI.map { [$0] } ?? []
        )
    }

    /// Extract UUID from a message ID string like "<UUID@impart.local>".
    private func extractUUID(from messageId: String) -> UUID? {
        let cleaned = messageId
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "@impart.local", with: "")
        return UUID(uuidString: cleaned)
    }
}

// MARK: - Role Conversions

extension ResearchSenderRole {
    /// Convert to mbox conversation role.
    func toMboxRole() -> ConversationRole {
        switch self {
        case .human:
            return .human
        case .counsel:
            return .counsel
        case .system:
            return .system
        }
    }
}

extension ConversationRole {
    /// Convert to research sender role.
    func toResearchRole() -> ResearchSenderRole {
        switch self {
        case .human:
            return .human
        case .counsel:
            return .counsel
        case .system:
            return .system
        case .artifact:
            return .system // Treat artifact messages as system messages
        }
    }
}

// MARK: - MboxConversation to ResearchConversation Conversion

extension MboxConversation {
    /// Convert an mbox conversation to research conversation format.
    public func toResearchConversation() -> ResearchConversation {
        ResearchConversation(
            id: id,
            title: title,
            participants: participants,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            summaryText: nil,
            isArchived: false,
            tags: [],
            parentConversationId: nil,
            messageCount: messageCount,
            latestSnippet: latestSnippet
        )
    }
}

