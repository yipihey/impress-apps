import AppIntents
import Foundation

// MARK: - Service Locator

/// Protocol for providing message services to App Intents.
/// The main app target registers a concrete implementation at launch.
@available(macOS 14.0, iOS 17.0, *)
public protocol ImpartIntentService: Sendable {
    func listConversations(limit: Int, includeArchived: Bool) async throws -> [ConversationEntity]
    func getConversation(id: UUID) async throws -> ConversationEntity?
    func composeMessage(to: String, subject: String, body: String) async throws
    func searchMessages(query: String, maxResults: Int) async throws -> [MessageEntity]
    func conversationsForIds(_ ids: [UUID]) async throws -> [ConversationEntity]
    func searchConversationsByTitle(_ query: String) async throws -> [ConversationEntity]
    func messagesForIds(_ ids: [UUID]) async throws -> [MessageEntity]
    func searchMessagesBySubject(_ query: String) async throws -> [MessageEntity]
}

/// Global service locator — set by the app at launch.
@available(macOS 14.0, iOS 17.0, *)
public enum ImpartIntentServiceLocator {
    @MainActor public static var service: (any ImpartIntentService)?
}

// MARK: - List Conversations

@available(macOS 14.0, iOS 17.0, *)
public struct ListConversationsIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Conversations"
    public static var description = IntentDescription(
        "List recent conversations.",
        categoryName: "Conversations"
    )

    @Parameter(title: "Limit", description: "Maximum number of conversations to return", default: 20)
    public var limit: Int

    @Parameter(title: "Include Archived", description: "Include archived conversations", default: false)
    public var includeArchived: Bool

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List up to \(\.$limit) conversations") {
            \.$includeArchived
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[ConversationEntity]> {
        guard let service = await ImpartIntentServiceLocator.service else {
            throw ImpartIntentError.automationDisabled
        }
        let conversations = try await service.listConversations(limit: limit, includeArchived: includeArchived)
        return .result(value: conversations)
    }
}

// MARK: - Get Conversation

@available(macOS 14.0, iOS 17.0, *)
public struct GetConversationIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Conversation"
    public static var description = IntentDescription(
        "Get details of a specific conversation.",
        categoryName: "Conversations"
    )

    @Parameter(title: "Conversation")
    public var conversation: ConversationEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Get details of \(\.$conversation)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<ConversationEntity> {
        guard let service = await ImpartIntentServiceLocator.service else {
            return .result(value: conversation)
        }
        let result = try await service.getConversation(id: conversation.id)
        return .result(value: result ?? conversation)
    }
}

// MARK: - Compose Message

@available(macOS 14.0, iOS 17.0, *)
public struct ComposeMessageIntent: AppIntent {
    public static var title: LocalizedStringResource = "Compose Message"
    public static var description = IntentDescription(
        "Compose and send a new email message.",
        categoryName: "Messages"
    )

    @Parameter(title: "To", description: "Recipient email address")
    public var to: String

    @Parameter(title: "Subject", description: "Email subject line")
    public var subject: String

    @Parameter(title: "Body", description: "Email body text")
    public var body: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Send message to \(\.$to) about \(\.$subject)") {
            \.$body
        }
    }

    public func perform() async throws -> some IntentResult {
        guard let service = await ImpartIntentServiceLocator.service else {
            throw ImpartIntentError.automationDisabled
        }
        try await service.composeMessage(to: to, subject: subject, body: body)
        return .result()
    }
}

// MARK: - Search Messages

@available(macOS 14.0, iOS 17.0, *)
public struct SearchMessagesIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search Messages"
    public static var description = IntentDescription(
        "Search for messages by subject, sender, or content.",
        categoryName: "Messages"
    )

    @Parameter(title: "Query", description: "Search query")
    public var query: String

    @Parameter(title: "Max Results", description: "Maximum number of results", default: 20)
    public var maxResults: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Search messages for \(\.$query)") {
            \.$maxResults
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[MessageEntity]> {
        guard let service = await ImpartIntentServiceLocator.service else {
            throw ImpartIntentError.automationDisabled
        }
        let messages = try await service.searchMessages(query: query, maxResults: maxResults)
        return .result(value: messages)
    }
}

// MARK: - Navigate Impart

@available(macOS 14.0, iOS 17.0, *)
public struct NavigateImpartIntent: AppIntent {
    public static var title: LocalizedStringResource = "Navigate"
    public static var description = IntentDescription(
        "Navigate to a specific section of impart.",
        categoryName: "Navigation"
    )

    @Parameter(title: "Destination", description: "Where to navigate")
    public var destination: ImpartNavigationTarget

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Navigate to \(\.$destination)")
    }

    public func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("impartNavigateFromIntent"),
                object: nil,
                userInfo: ["destination": destination.rawValue]
            )
        }
        return .result()
    }
}
