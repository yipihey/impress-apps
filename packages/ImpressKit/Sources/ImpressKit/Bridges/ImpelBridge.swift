import Foundation

/// Typed bridge for communicating with impel (agent orchestration) via its HTTP API.
///
/// Provides structured task submission, status polling, progress streaming,
/// and result retrieval. Any sibling app can use this to submit work to the
/// counsel agent engine running in impel.
///
/// All methods use `SiblingBridge.shared` to send HTTP requests to impel's
/// automation server (default port 23124).
public struct ImpelBridge: Sendable {

    // MARK: - Task Submission

    /// Submit a structured task to impel's counsel engine.
    /// Returns immediately with a task ID for polling.
    public static func submitTask(
        query: String,
        intent: String = "general",
        sourceApp: String = "api",
        conversationID: String? = nil,
        callbackURL: String? = nil
    ) async throws -> ImpelTaskSubmission {
        var body: [String: Any] = [
            "query": query,
            "intent": intent,
            "source_app": sourceApp
        ]
        if let conversationID { body["conversation_id"] = conversationID }
        if let callbackURL { body["callback_url"] = callbackURL }

        let data = try await SiblingBridge.shared.postRaw(
            "/api/tasks",
            to: .impel,
            body: body
        )
        return try JSONDecoder().decode(ImpelTaskSubmission.self, from: data)
    }

    // MARK: - Task Status

    /// Get the current status of a task.
    public static func getTask(_ taskID: String) async throws -> ImpelTaskInfo {
        let data = try await SiblingBridge.shared.getRaw(
            "/api/tasks/\(taskID)",
            from: .impel
        )
        let wrapper = try JSONDecoder().decode(ImpelTaskInfoWrapper.self, from: data)
        return wrapper.task
    }

    /// Get the full result of a completed task including tool executions.
    public static func getTaskResult(_ taskID: String) async throws -> ImpelTaskResult {
        try await SiblingBridge.shared.get(
            "/api/tasks/\(taskID)/result",
            from: .impel
        )
    }

    // MARK: - Task Progress

    /// Poll for progress events on a task.
    /// - Parameters:
    ///   - taskID: The task to poll.
    ///   - afterSequence: Only return events after this sequence number (default 0 = all events).
    ///   - timeout: Max seconds to wait for new events (default 10).
    public static func pollTaskProgress(
        _ taskID: String,
        afterSequence: Int = 0,
        timeout: Int = 10
    ) async throws -> ImpelTaskProgress {
        try await SiblingBridge.shared.get(
            "/api/tasks/\(taskID)/stream",
            from: .impel,
            query: [
                "after_sequence": String(afterSequence),
                "timeout": String(timeout)
            ]
        )
    }

    // MARK: - Task Cancellation

    /// Cancel a running or queued task.
    public static func cancelTask(_ taskID: String) async -> Bool {
        do {
            let _: [String: String] = try await SiblingBridge.shared.deleteRequest(
                "/api/tasks/\(taskID)",
                from: .impel
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Task Listing

    /// List tasks with optional status filter.
    public static func listTasks(status: String? = nil, limit: Int = 50) async throws -> [ImpelTaskInfo] {
        var query: [String: String] = ["limit": String(limit)]
        if let status { query["status"] = status }

        let data = try await SiblingBridge.shared.getRaw(
            "/api/tasks",
            from: .impel,
            query: query
        )
        let wrapper = try JSONDecoder().decode(ImpelTaskListWrapper.self, from: data)
        return wrapper.tasks
    }

    // MARK: - Availability

    /// Check if impel's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.impel)
    }
}

// MARK: - Result Types

/// Response from task submission.
public struct ImpelTaskSubmission: Codable, Sendable {
    public let status: String
    public let task_id: String
    public let task_status: String

    /// The task ID.
    public var taskID: String { task_id }
}

/// Task information from status queries.
public struct ImpelTaskInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let intent: String
    public let query: String
    public let source_app: String
    public let status: String
    public let tool_execution_count: Int?
    public let rounds_used: Int?
    public let total_tokens_used: Int?
    public let response_text: String?
    public let finish_reason: String?
    public let error_message: String?
    public let conversation_id: String?
    public let created_at: String?
    public let started_at: String?
    public let completed_at: String?
}

/// Full task result with tool execution details.
public struct ImpelTaskResult: Codable, Sendable {
    public let status: String
    public let task_id: String
    public let task_status: String
    public let response_text: String?
    public let tool_executions: [ImpelToolExecution]?
    public let rounds_used: Int?
    public let total_input_tokens: Int?
    public let total_output_tokens: Int?
    public let total_tokens_used: Int?
    public let finish_reason: String?
    public let error_message: String?
    public let created_at: String?
    public let started_at: String?
    public let completed_at: String?
}

/// A tool execution record within a task result.
public struct ImpelToolExecution: Codable, Sendable {
    public let tool_name: String
    public let output_summary: String
    public let is_error: Bool
    public let duration_ms: Int
}

/// A progress event from task streaming.
public struct ImpelTaskProgressEvent: Codable, Sendable {
    public let sequence: Int
    public let event_type: String
    public let task_id: String
    public let timestamp: String?
    public let tool_name: String?
    public let tool_input: [String: String]?
    public let output_summary: String?
    public let duration_ms: Int?
    public let response_text: String?
    public let error: String?
}

/// Response from progress polling.
public struct ImpelTaskProgress: Codable, Sendable {
    public let status: String
    public let task_id: String
    public let task_status: String
    public let events: [ImpelTaskProgressEvent]
    public let last_sequence: Int
}

// MARK: - Internal Wrappers

struct ImpelTaskInfoWrapper: Codable {
    let status: String
    let task: ImpelTaskInfo
}

struct ImpelTaskListWrapper: Codable {
    let status: String
    let count: Int
    let tasks: [ImpelTaskInfo]
}
