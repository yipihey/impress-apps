import AppIntents
import Foundation

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
        // TODO: Connect to DevelopmentConversationService
        return .result(value: [])
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
        return .result(value: conversation)
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
        // TODO: Connect to SMTP send pipeline via MessageRegistry
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
        // TODO: Connect to message search service
        return .result(value: [])
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
        // TODO: Post navigation notification
        return .result()
    }
}
