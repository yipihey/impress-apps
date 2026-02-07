import AppIntents
import Foundation

// MARK: - List Threads

@available(macOS 14.0, *)
public struct ListThreadsIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Threads"
    public static var description = IntentDescription(
        "List agent threads, optionally filtered by status.",
        categoryName: "Threads"
    )

    @Parameter(title: "Status", description: "Filter by thread status (optional)")
    public var status: ImpelThreadStatus?

    @Parameter(title: "Limit", description: "Maximum number of threads to return", default: 20)
    public var limit: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List threads") {
            \.$status
            \.$limit
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[ThreadEntity]> {
        // TODO: Connect to thread persistence
        return .result(value: [])
    }
}

// MARK: - Create Thread

@available(macOS 14.0, *)
public struct CreateThreadIntent: AppIntent {
    public static var title: LocalizedStringResource = "Create Thread"
    public static var description = IntentDescription(
        "Create a new agent thread with a specified persona.",
        categoryName: "Threads"
    )

    @Parameter(title: "Title", description: "Thread title")
    public var title: String

    @Parameter(title: "Persona", description: "Agent persona to use")
    public var persona: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Create thread \(\.$title) with \(\.$persona)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<ThreadEntity> {
        // TODO: Connect to thread creation service
        let thread = ThreadEntity(id: UUID(), title: title, persona: persona)
        return .result(value: thread)
    }
}

// MARK: - Ask Counsel

@available(macOS 14.0, *)
public struct AskCounselIntent: AppIntent {
    public static var title: LocalizedStringResource = "Ask Counsel"
    public static var description = IntentDescription(
        "Ask the Counsel research assistant a question.",
        categoryName: "Counsel"
    )

    @Parameter(title: "Question", description: "The research question to ask")
    public var question: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Ask counsel: \(\.$question)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: Connect to CounselEngine.makeTaskHandler
        return .result(value: "Counsel is not yet connected. Please configure the agent.")
    }
}

// MARK: - List Escalations

@available(macOS 14.0, *)
public struct ListEscalationsIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Escalations"
    public static var description = IntentDescription(
        "List items that need human review.",
        categoryName: "Escalations"
    )

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<[EscalationEntity]> {
        // TODO: Connect to escalation tracking
        return .result(value: [])
    }
}

// MARK: - Get Suite Status

@available(macOS 14.0, *)
public struct GetSuiteStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Suite Status"
    public static var description = IntentDescription(
        "Get the status of all Impress suite apps.",
        categoryName: "Suite"
    )

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: Connect to SiblingDiscovery from ImpressKit
        return .result(value: "Suite status check not yet connected.")
    }
}
