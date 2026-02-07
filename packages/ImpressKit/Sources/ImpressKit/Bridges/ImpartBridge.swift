import Foundation

/// Typed bridge for communicating with impart (messaging) via its HTTP API.
public struct ImpartBridge: Sendable {

    /// List research conversations.
    public static func listConversations(limit: Int = 20) async throws -> [ConversationInfo] {
        try await SiblingBridge.shared.get(
            "/api/research/conversations",
            from: .impart,
            query: ["limit": String(limit)]
        )
    }

    /// List messages in a mailbox.
    public static func listMessages(mailbox: String? = nil, limit: Int = 50) async throws -> [MessageInfo] {
        var query: [String: String] = ["limit": String(limit)]
        if let mailbox { query["mailbox"] = mailbox }
        return try await SiblingBridge.shared.get("/api/messages", from: .impart, query: query)
    }

    /// Check if impart's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.impart)
    }
}

// MARK: - Result Types

/// Basic conversation information from impart.
public struct ConversationInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let subject: String?
    public let participants: [String]?
    public let messageCount: Int?
    public let lastActivity: Date?
}

/// Basic message information from impart.
public struct MessageInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let subject: String?
    public let sender: String?
    public let date: Date?
    public let isRead: Bool?
}
