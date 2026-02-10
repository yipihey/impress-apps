import Foundation
import ImpressAI
import ImpressKit
import OSLog

/// A structured request to submit a task to the counsel engine.
public struct TaskRequest: Codable, Sendable {
    public var intent: String
    public var query: String
    public var sourceApp: String
    public var conversationID: String?
    public var callbackURL: String?

    /// When true, the orchestrator skips persisting the user message (because the
    /// caller already did it with additional metadata, e.g. email threading headers).
    public var skipUserPersistence: Bool

    /// When true, the orchestrator skips persisting the assistant response.
    public var skipAssistantPersistence: Bool

    public init(
        intent: String = "general",
        query: String,
        sourceApp: String = "api",
        conversationID: String? = nil,
        callbackURL: String? = nil,
        skipUserPersistence: Bool = false,
        skipAssistantPersistence: Bool = false
    ) {
        self.intent = intent
        self.query = query
        self.sourceApp = sourceApp
        self.conversationID = conversationID
        self.callbackURL = callbackURL
        self.skipUserPersistence = skipUserPersistence
        self.skipAssistantPersistence = skipAssistantPersistence
    }
}

/// A structured result returned when a task completes.
public struct TaskResult: Codable, Sendable {
    public let taskID: String
    public let status: CounselTaskStatus
    public let responseText: String?
    public let toolExecutions: [TaskToolExecution]
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let roundsUsed: Int
    public let finishReason: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let startedAt: Date?
    public let completedAt: Date?

    public var totalTokensUsed: Int { totalInputTokens + totalOutputTokens }
}

/// A simplified tool execution record for task results.
public struct TaskToolExecution: Codable, Sendable {
    public let toolName: String
    public let outputSummary: String
    public let isError: Bool
    public let durationMs: Int
}

/// An event emitted during task execution for progress tracking.
public enum TaskEvent: Sendable {
    case queued(taskID: String)
    case started(taskID: String)
    case toolStart(taskID: String, toolName: String, toolInput: [String: String])
    case toolComplete(taskID: String, toolName: String, outputSummary: String, durationMs: Int)
    case completed(taskID: String, responseText: String)
    case failed(taskID: String, error: String)
    case cancelled(taskID: String)
}

/// A serializable event record for polling-based progress.
public struct TaskEventRecord: Codable, Sendable {
    public let sequence: Int
    public let eventType: String
    public let taskID: String
    public let timestamp: Date
    public var toolName: String?
    public var toolInput: [String: String]?
    public var outputSummary: String?
    public var durationMs: Int?
    public var responseText: String?
    public var error: String?

    init(sequence: Int, event: TaskEvent) {
        self.sequence = sequence
        self.timestamp = Date()
        switch event {
        case .queued(let id):
            self.eventType = "queued"
            self.taskID = id
        case .started(let id):
            self.eventType = "started"
            self.taskID = id
        case .toolStart(let id, let name, let input):
            self.eventType = "tool_start"
            self.taskID = id
            self.toolName = name
            self.toolInput = input
        case .toolComplete(let id, let name, let summary, let ms):
            self.eventType = "tool_complete"
            self.taskID = id
            self.toolName = name
            self.outputSummary = summary
            self.durationMs = ms
        case .completed(let id, let text):
            self.eventType = "completed"
            self.taskID = id
            self.responseText = text
        case .failed(let id, let err):
            self.eventType = "failed"
            self.taskID = id
            self.error = err
        case .cancelled(let id):
            self.eventType = "cancelled"
            self.taskID = id
        }
    }
}

/// Central orchestrator for counsel tasks.
///
/// Wraps `CounselEngine`'s request handling into a structured task lifecycle.
/// Any entry point (email gateway, HTTP API, App Intents, MCP) submits a
/// `TaskRequest` and gets a task ID back. Results are available via polling,
/// callbacks, or SSE streaming.
public actor TaskOrchestrator {
    private let logger = Logger(subsystem: "com.impress.impel", category: "task-orchestrator")
    private let database: CounselDatabase
    private let conversationManager: CounselConversationManager
    private let contextCompressor: ContextCompressor
    private let nativeLoop: NativeAgentLoop

    /// Active event streams keyed by task ID.
    private var eventContinuations: [String: [AsyncStream<TaskEvent>.Continuation]] = [:]

    /// In-flight task IDs for cancellation.
    private var runningTasks: Set<String> = []

    /// Accumulated events per task for polling-based progress (capped).
    private var taskEvents: [String: [TaskEventRecord]] = [:]
    private let maxEventsPerTask = 200

    public init(
        database: CounselDatabase,
        conversationManager: CounselConversationManager,
        contextCompressor: ContextCompressor,
        nativeLoop: NativeAgentLoop
    ) {
        self.database = database
        self.conversationManager = conversationManager
        self.contextCompressor = contextCompressor
        self.nativeLoop = nativeLoop
    }

    // MARK: - Task Submission

    /// Submit a new task. Returns the task ID immediately.
    /// The task runs asynchronously in the background.
    public func submit(_ request: TaskRequest) async throws -> String {
        let task = CounselTask(
            intent: request.intent,
            query: request.query,
            sourceApp: request.sourceApp,
            conversationID: request.conversationID,
            callbackURL: request.callbackURL
        )

        try database.createTask(task)
        logger.info("Task \(task.id) queued: '\(request.query.prefix(80))' [intent: \(request.intent), source: \(request.sourceApp)]")

        emit(.queued(taskID: task.id), for: task.id)

        // Execute in a detached task so submit() returns immediately
        let orchestrator = self
        Task.detached {
            await orchestrator.executeTask(id: task.id, request: request)
        }

        return task.id
    }

    /// Submit a task and wait for its result.
    public func submitAndWait(_ request: TaskRequest) async throws -> TaskResult {
        let taskID = try await submit(request)
        return try await awaitResult(taskID: taskID)
    }

    // MARK: - Task Queries

    /// Get a task by ID.
    public func getTask(_ taskID: String) throws -> CounselTask? {
        try database.fetchTask(id: taskID)
    }

    /// Get the full result for a completed task.
    public func getResult(_ taskID: String) throws -> TaskResult? {
        guard let task = try database.fetchTask(id: taskID) else { return nil }

        let toolExecutions: [TaskToolExecution]
        if let convID = task.conversationID {
            let executions = try database.fetchToolExecutions(conversationID: convID)
            toolExecutions = executions.map {
                TaskToolExecution(
                    toolName: $0.toolName,
                    outputSummary: String($0.toolOutput.prefix(500)),
                    isError: $0.isError,
                    durationMs: $0.durationMs
                )
            }
        } else {
            toolExecutions = []
        }

        return TaskResult(
            taskID: task.id,
            status: task.status,
            responseText: task.responseText,
            toolExecutions: toolExecutions,
            totalInputTokens: task.totalInputTokens,
            totalOutputTokens: task.totalOutputTokens,
            roundsUsed: task.roundsUsed,
            finishReason: task.finishReason,
            errorMessage: task.errorMessage,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt
        )
    }

    /// List tasks with optional status filter.
    public func listTasks(status: CounselTaskStatus? = nil, limit: Int = 50) throws -> [CounselTask] {
        try database.fetchTasks(status: status, limit: limit)
    }

    // MARK: - Task Cancellation

    /// Cancel a running or queued task.
    public func cancel(_ taskID: String) throws -> Bool {
        guard var task = try database.fetchTask(id: taskID) else { return false }
        guard task.status == .queued || task.status == .running else { return false }

        task.status = .cancelled
        task.completedAt = Date()
        try database.updateTask(task)

        runningTasks.remove(taskID)
        emit(.cancelled(taskID: taskID), for: taskID)
        closeEventStreams(for: taskID)

        logger.info("Task \(taskID) cancelled")
        return true
    }

    // MARK: - Event Streaming

    /// Subscribe to events for a specific task.
    public func events(for taskID: String) -> AsyncStream<TaskEvent> {
        AsyncStream { continuation in
            var continuations = eventContinuations[taskID] ?? []
            continuations.append(continuation)
            eventContinuations[taskID] = continuations

            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(for: taskID, continuation: continuation)
                }
            }
        }
    }

    // MARK: - Awaiting Results

    /// Wait for a task to complete and return its result.
    public func awaitResult(taskID: String, timeoutSeconds: Int = 300) async throws -> TaskResult {
        let stream = events(for: taskID)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        for await event in stream {
            switch event {
            case .completed, .failed, .cancelled:
                if let result = try getResult(taskID) {
                    return result
                }
            default:
                break
            }
            if Date() > deadline { break }
        }

        // Fallback: check the database directly
        if let result = try getResult(taskID) {
            return result
        }
        throw TaskOrchestratorError.timeout(taskID: taskID)
    }

    // MARK: - Internal Execution

    private func executeTask(id taskID: String, request: TaskRequest) async {
        // Mark as running
        let task: CounselTask
        do {
            guard let fetched = try database.fetchTask(id: taskID) else {
                logger.error("Task \(taskID) not found in database")
                return
            }
            task = fetched
        } catch {
            logger.error("Failed to fetch task \(taskID): \(error.localizedDescription)")
            return
        }
        var mutableTask = task
        mutableTask.status = .running
        mutableTask.startedAt = Date()
        do {
            try database.updateTask(mutableTask)
        } catch {
            logger.error("Failed to mark task \(taskID) as running: \(error.localizedDescription)")
        }
        runningTasks.insert(taskID)

        emit(.started(taskID: taskID), for: taskID)
        logger.info("Task \(taskID) started")

        // Check persistence setting
        let persistenceEnabled = UserDefaults.standard.object(forKey: "counselPersistenceEnabled") as? Bool ?? true

        // Resolve or create conversation
        let conversation: CounselConversation
        do {
            if persistenceEnabled {
                if let existingConvID = request.conversationID,
                   let existing = try database.fetchConversation(id: existingConvID) {
                    conversation = existing
                } else {
                    let conv = CounselConversation(
                        subject: String(request.query.prefix(100)),
                        participantEmail: "\(request.sourceApp)@impress.local"
                    )
                    try database.createConversation(conv)
                    conversation = conv
                }

                // Link task to conversation
                task.conversationID = conversation.id
                try database.updateTask(task)
            } else {
                conversation = CounselConversation(
                    subject: String(request.query.prefix(100)),
                    participantEmail: "\(request.sourceApp)@impress.local"
                )
            }
        } catch {
            await failTask(taskID, error: "Failed to resolve conversation: \(error.localizedDescription)")
            return
        }

        // Persist user message (unless caller already did it, e.g. email gateway)
        if persistenceEnabled && !request.skipUserPersistence {
            do {
                _ = try conversationManager.persistUserMessage(
                    conversationID: conversation.id,
                    content: request.query,
                    emailMessageID: "<task-\(taskID)@impress.local>",
                    inReplyTo: nil,
                    intent: request.intent
                )
            } catch {
                logger.error("Failed to persist user message for task \(taskID): \(error.localizedDescription)")
            }
        }

        // Load conversation history
        var history: [AIMessage]
        if persistenceEnabled {
            do {
                history = try conversationManager.loadHistory(conversationID: conversation.id)
            } catch {
                history = [AIMessage(role: .user, text: request.query)]
            }
        } else {
            history = [AIMessage(role: .user, text: request.query)]
        }

        // Compress if needed
        history = await contextCompressor.compressIfNeeded(
            messages: history,
            database: database,
            conversationID: conversation.id
        )

        // Build system prompt
        let customPrompt = UserDefaults.standard.string(forKey: "counselSystemPrompt")
            .flatMap { $0.isEmpty ? nil : $0 }
        let systemPrompt = CounselSystemPrompt.build(
            basePrompt: customPrompt,
            conversationSummary: conversation.summary
        )

        // Read config
        let modelId = UserDefaults.standard.string(forKey: "counselModel")
            .flatMap { $0.isEmpty ? nil : $0 }
        let maxTurns = UserDefaults.standard.integer(forKey: "counselMaxTurns")
        let effectiveMaxTurns = maxTurns > 0 ? maxTurns : 40

        // Check for cancellation before starting the loop
        guard runningTasks.contains(taskID) else {
            logger.info("Task \(taskID) was cancelled before agent loop started")
            return
        }

        // Wire progress callback for event streaming
        let capturedTaskID = taskID
        let orchestrator = self
        await nativeLoop.setProgressCallback { event in
            switch event {
            case .toolStart(let name, let input):
                await orchestrator.emit(
                    .toolStart(taskID: capturedTaskID, toolName: name, toolInput: input),
                    for: capturedTaskID
                )
            case .toolComplete(let name, let summary, let ms):
                await orchestrator.emit(
                    .toolComplete(taskID: capturedTaskID, toolName: name, outputSummary: summary, durationMs: ms),
                    for: capturedTaskID
                )
            }
        }

        // Run the agentic loop
        let agentLoop = CounselAgentLoop(
            database: database,
            config: AgentLoopConfig(maxTurns: effectiveMaxTurns, modelId: modelId),
            nativeLoop: nativeLoop
        )

        let result = await agentLoop.run(
            conversationID: conversation.id,
            systemPrompt: systemPrompt,
            messages: history
        )

        // Clear progress callback
        await nativeLoop.setProgressCallback(nil)

        // Persist assistant response (unless caller handles it, e.g. email gateway)
        if persistenceEnabled && !request.skipAssistantPersistence {
            do {
                _ = try conversationManager.persistAssistantMessage(
                    conversationID: conversation.id,
                    content: result.responseText
                )
            } catch {
                logger.error("Failed to persist assistant message for task \(taskID): \(error.localizedDescription)")
            }
        }

        // Always update conversation metadata
        if persistenceEnabled {
            do {
                var updated = conversation
                updated.updatedAt = Date()
                updated.totalTokensUsed = conversation.totalTokensUsed + result.totalTokensUsed
                try database.updateConversation(updated)
            } catch {
                logger.error("Failed to update conversation for task \(taskID): \(error.localizedDescription)")
            }
        }

        // Update task with results — but respect cancellation
        do {
            guard var completedTask = try database.fetchTask(id: taskID) else {
                logger.error("Task \(taskID) disappeared from database after completion")
                return
            }

            // If the task was cancelled while the loop was running, don't overwrite
            if completedTask.status == .cancelled {
                logger.info("Task \(taskID) was cancelled during execution, preserving cancelled status")
                runningTasks.remove(taskID)
                closeEventStreams(for: taskID)
                return
            }

            completedTask.status = result.finishReason == .error ? .failed : .completed
            completedTask.responseText = result.responseText
            completedTask.toolExecutionCount = result.toolExecutions.count
            completedTask.roundsUsed = result.roundsUsed
            completedTask.totalInputTokens = result.totalInputTokens
            completedTask.totalOutputTokens = result.totalOutputTokens
            completedTask.finishReason = result.finishReason.rawValue
            completedTask.completedAt = Date()
            try database.updateTask(completedTask)
        } catch {
            logger.error("Failed to persist task \(taskID) result: \(error.localizedDescription)")
        }

        runningTasks.remove(taskID)

        // Emit completion event
        emit(.completed(taskID: taskID, responseText: result.responseText), for: taskID)
        closeEventStreams(for: taskID)

        // Post Darwin notification so sibling apps can react
        ImpressNotification.post(ImpressNotification.taskCompleted, from: .impel, resourceIDs: [taskID])

        // Deliver callback if configured
        if let callbackURL = completedTask.callbackURL {
            await deliverCallback(taskID: taskID, to: callbackURL)
        }

        logger.info("Task \(taskID) completed: \(result.roundsUsed) turns, \(result.totalTokensUsed) tokens, \(result.toolExecutions.count) tools")
    }

    private func failTask(_ taskID: String, error: String) async {
        guard var task = try? database.fetchTask(id: taskID) else { return }
        task.status = .failed
        task.errorMessage = error
        task.completedAt = Date()
        try? database.updateTask(task)

        runningTasks.remove(taskID)
        emit(.failed(taskID: taskID, error: error), for: taskID)
        closeEventStreams(for: taskID)

        logger.error("Task \(taskID) failed: \(error)")
    }

    private func deliverCallback(taskID: String, to urlString: String) async {
        guard let url = URL(string: urlString) else {
            logger.error("Invalid callback URL for task \(taskID): \(urlString)")
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let result = try? getResult(taskID),
              let body = try? encoder.encode(result) else {
            logger.error("Failed to encode result for callback on task \(taskID)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Callback delivered for task \(taskID) → \(urlString) [\(status)]")
        } catch {
            logger.error("Callback delivery failed for task \(taskID): \(error.localizedDescription)")
        }
    }

    // MARK: - Event Polling

    /// Get accumulated events for a task, optionally starting after a given sequence number.
    /// Used by the HTTP polling endpoint as a practical alternative to SSE streaming.
    public func getEvents(for taskID: String, afterSequence: Int = 0) -> [TaskEventRecord] {
        guard let events = taskEvents[taskID] else { return [] }
        return events.filter { $0.sequence > afterSequence }
    }

    // MARK: - Event Helpers

    private func emit(_ event: TaskEvent, for taskID: String) {
        // Record for polling
        let nextSeq = (taskEvents[taskID]?.last?.sequence ?? 0) + 1
        let record = TaskEventRecord(sequence: nextSeq, event: event)
        var events = taskEvents[taskID] ?? []
        events.append(record)
        if events.count > maxEventsPerTask {
            events = Array(events.suffix(maxEventsPerTask))
        }
        taskEvents[taskID] = events

        // Forward to AsyncStream subscribers
        guard let continuations = eventContinuations[taskID] else { return }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func closeEventStreams(for taskID: String) {
        if let continuations = eventContinuations.removeValue(forKey: taskID) {
            for continuation in continuations {
                continuation.finish()
            }
        }
        // Keep event history for 5 minutes after completion for late pollers,
        // then clean up. For now, just leave it — the cap prevents unbounded growth.
    }

    private func removeContinuation(for taskID: String, continuation: AsyncStream<TaskEvent>.Continuation) {
        // Clean up — we can't compare continuations directly, so just leave the array
        // as-is; finished continuations will be cleaned up on closeEventStreams.
    }
}

// MARK: - Errors

public enum TaskOrchestratorError: Error, LocalizedError {
    case timeout(taskID: String)
    case taskNotFound(taskID: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let taskID): return "Task \(taskID) timed out waiting for result"
        case .taskNotFound(let taskID): return "Task \(taskID) not found"
        }
    }
}
