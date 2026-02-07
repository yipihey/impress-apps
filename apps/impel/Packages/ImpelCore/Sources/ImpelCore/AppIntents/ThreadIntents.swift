import AppIntents
import Foundation
import ImpressKit

// MARK: - Counsel Service Protocol

/// Protocol for providing counsel responses to App Intents.
/// The main app target registers a concrete implementation.
@available(macOS 14.0, *)
public protocol CounselIntentService: Sendable {
    func ask(question: String) async throws -> String
}

/// Global service locator for counsel — set by the app at launch.
@available(macOS 14.0, *)
public enum CounselIntentServiceLocator {
    @MainActor public static var service: (any CounselIntentService)?
}

// MARK: - ImpelClient Service Locator

/// Protocol for providing thread/escalation data to App Intents.
/// The main app target registers a concrete implementation at launch.
@available(macOS 14.0, *)
public protocol ImpelClientIntentService: Sendable {
    func listThreads(status: String?, limit: Int) async throws -> [ThreadEntity]
    func createThread(title: String, persona: String) async throws -> ThreadEntity
    func listEscalations() async throws -> [EscalationEntity]
    func threadsForIds(_ ids: [UUID]) async throws -> [ThreadEntity]
    func searchThreadsByTitle(_ query: String) async throws -> [ThreadEntity]
    func escalationsForIds(_ ids: [UUID]) async throws -> [EscalationEntity]
}

/// Global service locator for ImpelClient — set by the app at launch.
@available(macOS 14.0, *)
public enum ImpelClientLocator {
    @MainActor public static var service: (any ImpelClientIntentService)?
}

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
        guard let service = await ImpelClientLocator.service else {
            throw ImpelIntentError.automationDisabled
        }
        let threads = try await service.listThreads(status: status?.rawValue, limit: limit)
        return .result(value: threads)
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
        guard let service = await ImpelClientLocator.service else {
            throw ImpelIntentError.automationDisabled
        }
        let thread = try await service.createThread(title: title, persona: persona)
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
        guard let service = await CounselIntentServiceLocator.service else {
            throw ImpelIntentError.counselUnavailable
        }
        let response = try await service.ask(question: question)
        return .result(value: response)
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
        guard let service = await ImpelClientLocator.service else {
            throw ImpelIntentError.automationDisabled
        }
        let escalations = try await service.listEscalations()
        return .result(value: escalations)
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
        let discovery = SiblingDiscovery.shared
        var lines: [String] = ["Impress Suite Status:"]
        for app in SiblingApp.allCases {
            let installed = discovery.isInstalled(app)
            let running = discovery.isRunning(app)
            let status = running ? "running" : (installed ? "installed" : "not found")
            lines.append("  \(app.rawValue): \(status)")
        }
        return .result(value: lines.joined(separator: "\n"))
    }
}
