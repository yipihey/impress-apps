//
//  AIMultiModelExecutor.swift
//  ImpressAI
//
//  Parallel execution of AI requests across multiple models.
//

import Foundation

// MARK: - Execution Result

/// Result of executing a request against a single model.
public struct AIModelExecutionResult: Identifiable, Sendable {
    public let id: UUID
    public let modelReference: AIModelReference
    public let status: ExecutionStatus
    public let response: AICompletionResponse?
    public let error: Error?
    public let duration: TimeInterval
    public let startTime: Date

    public var endTime: Date {
        startTime.addingTimeInterval(duration)
    }

    public var isSuccess: Bool {
        if case .completed = status { return true }
        return false
    }

    public var text: String? {
        response?.text
    }

    public enum ExecutionStatus: Sendable {
        case pending
        case streaming
        case completed
        case failed(String)
        case cancelled

        public var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .streaming: return "Streaming..."
            case .completed: return "Completed"
            case .failed(let reason): return "Failed: \(reason)"
            case .cancelled: return "Cancelled"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        modelReference: AIModelReference,
        status: ExecutionStatus,
        response: AICompletionResponse? = nil,
        error: Error? = nil,
        duration: TimeInterval = 0,
        startTime: Date = Date()
    ) {
        self.id = id
        self.modelReference = modelReference
        self.status = status
        self.response = response
        self.error = error
        self.duration = duration
        self.startTime = startTime
    }
}

// MARK: - Comparison Result

/// Combined result from multiple model executions.
public struct AIComparisonResult: Sendable {
    public let categoryId: String
    public let request: AICompletionRequest
    public let results: [AIModelExecutionResult]
    public let startTime: Date
    public let endTime: Date

    /// All successful results.
    public var successfulResults: [AIModelExecutionResult] {
        results.filter { $0.isSuccess }
    }

    /// All failed results.
    public var failedResults: [AIModelExecutionResult] {
        results.filter { !$0.isSuccess }
    }

    /// Whether all executions completed successfully.
    public var allSucceeded: Bool {
        results.allSatisfy { $0.isSuccess }
    }

    /// Whether at least one execution succeeded.
    public var hasAnySuccess: Bool {
        results.contains { $0.isSuccess }
    }

    /// Total execution duration.
    public var totalDuration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    public init(
        categoryId: String,
        request: AICompletionRequest,
        results: [AIModelExecutionResult],
        startTime: Date,
        endTime: Date
    ) {
        self.categoryId = categoryId
        self.request = request
        self.results = results
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Streaming Progress

/// Progress update during multi-model streaming execution.
public struct AIStreamingProgress: Sendable {
    public let modelReference: AIModelReference
    public let partialText: String
    public let isComplete: Bool
    public let error: Error?

    public init(
        modelReference: AIModelReference,
        partialText: String,
        isComplete: Bool = false,
        error: Error? = nil
    ) {
        self.modelReference = modelReference
        self.partialText = partialText
        self.isComplete = isComplete
        self.error = error
    }
}

// MARK: - Multi-Model Executor

/// Actor that executes AI requests across multiple models in parallel.
public actor AIMultiModelExecutor {

    /// Shared singleton instance.
    public static let shared = AIMultiModelExecutor()

    private let providerManager: AIProviderManager
    private let categoryManager: AITaskCategoryManager
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        providerManager: AIProviderManager = .shared,
        categoryManager: AITaskCategoryManager = .shared
    ) {
        self.providerManager = providerManager
        self.categoryManager = categoryManager
    }

    // MARK: - Non-Streaming Execution

    /// Execute a request for a category against all assigned models.
    ///
    /// - Parameters:
    ///   - request: The base completion request.
    ///   - categoryId: The category ID to get assigned models.
    /// - Returns: Combined comparison result.
    public func execute(
        _ request: AICompletionRequest,
        for categoryId: String
    ) async throws -> AIComparisonResult {
        let models = await categoryManager.modelsForExecution(categoryId: categoryId)

        guard !models.isEmpty else {
            throw AIError.providerNotConfigured("No models configured for category '\(categoryId)'")
        }

        let startTime = Date()

        let results = await withTaskGroup(of: AIModelExecutionResult.self) { group in
            for model in models {
                group.addTask {
                    await self.executeForModel(request, model: model)
                }
            }

            var collected: [AIModelExecutionResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let endTime = Date()

        return AIComparisonResult(
            categoryId: categoryId,
            request: request,
            results: results,
            startTime: startTime,
            endTime: endTime
        )
    }

    /// Execute a request against specific models (not category-based).
    ///
    /// - Parameters:
    ///   - request: The completion request.
    ///   - models: Array of model references to execute against.
    /// - Returns: Combined comparison result.
    public func execute(
        _ request: AICompletionRequest,
        models: [AIModelReference]
    ) async throws -> AIComparisonResult {
        guard !models.isEmpty else {
            throw AIError.invalidRequest("No models specified")
        }

        let startTime = Date()

        let results = await withTaskGroup(of: AIModelExecutionResult.self) { group in
            for model in models {
                group.addTask {
                    await self.executeForModel(request, model: model)
                }
            }

            var collected: [AIModelExecutionResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let endTime = Date()

        return AIComparisonResult(
            categoryId: "custom",
            request: request,
            results: results,
            startTime: startTime,
            endTime: endTime
        )
    }

    // MARK: - Streaming Execution

    /// Execute a streaming request for a category.
    ///
    /// - Parameters:
    ///   - request: The base completion request.
    ///   - categoryId: The category ID.
    /// - Returns: Stream of progress updates from all models.
    public func executeStreaming(
        _ request: AICompletionRequest,
        for categoryId: String
    ) async throws -> AsyncThrowingStream<AIStreamingProgress, Error> {
        let models = await categoryManager.modelsForExecution(categoryId: categoryId)

        guard !models.isEmpty else {
            throw AIError.providerNotConfigured("No models configured for category '\(categoryId)'")
        }

        return executeStreaming(request, models: models)
    }

    /// Execute a streaming request against specific models.
    ///
    /// - Parameters:
    ///   - request: The completion request.
    ///   - models: Array of model references.
    /// - Returns: Stream of progress updates from all models.
    public func executeStreaming(
        _ request: AICompletionRequest,
        models: [AIModelReference]
    ) -> AsyncThrowingStream<AIStreamingProgress, Error> {
        AsyncThrowingStream { continuation in
            let executionId = UUID()

            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for model in models {
                        group.addTask {
                            await self.streamForModel(
                                request,
                                model: model,
                                continuation: continuation
                            )
                        }
                    }
                }
                continuation.finish()
            }

            self.registerTask(executionId, task: task)

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Cancellation

    /// Cancel all active executions.
    public func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
    }

    // MARK: - Private Methods

    private func registerTask(_ id: UUID, task: Task<Void, Never>) {
        activeTasks[id] = task
    }

    private func executeForModel(
        _ request: AICompletionRequest,
        model: AIModelReference
    ) async -> AIModelExecutionResult {
        let startTime = Date()

        guard let provider = await providerManager.provider(for: model.providerId) else {
            return AIModelExecutionResult(
                modelReference: model,
                status: .failed("Provider not found"),
                startTime: startTime
            )
        }

        // Create request with specific model
        let modelRequest = AICompletionRequest(
            providerId: model.providerId,
            modelId: model.modelId,
            messages: request.messages,
            systemPrompt: request.systemPrompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stopSequences: request.stopSequences,
            stream: request.stream,
            tools: request.tools,
            additionalParameters: request.additionalParameters
        )

        do {
            let response = try await provider.complete(modelRequest)
            let duration = Date().timeIntervalSince(startTime)

            return AIModelExecutionResult(
                modelReference: model,
                status: .completed,
                response: response,
                duration: duration,
                startTime: startTime
            )
        } catch {
            let duration = Date().timeIntervalSince(startTime)

            if Task.isCancelled {
                return AIModelExecutionResult(
                    modelReference: model,
                    status: .cancelled,
                    error: error,
                    duration: duration,
                    startTime: startTime
                )
            }

            return AIModelExecutionResult(
                modelReference: model,
                status: .failed(error.localizedDescription),
                error: error,
                duration: duration,
                startTime: startTime
            )
        }
    }

    private func streamForModel(
        _ request: AICompletionRequest,
        model: AIModelReference,
        continuation: AsyncThrowingStream<AIStreamingProgress, Error>.Continuation
    ) async {
        guard let provider = await providerManager.provider(for: model.providerId) else {
            continuation.yield(AIStreamingProgress(
                modelReference: model,
                partialText: "",
                isComplete: true,
                error: AIError.providerNotFound(model.providerId)
            ))
            return
        }

        let modelRequest = AICompletionRequest(
            providerId: model.providerId,
            modelId: model.modelId,
            messages: request.messages,
            systemPrompt: request.systemPrompt,
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP,
            stopSequences: request.stopSequences,
            stream: true,
            tools: request.tools,
            additionalParameters: request.additionalParameters
        )

        do {
            let stream = try await provider.stream(modelRequest)
            var accumulatedText = ""

            for try await chunk in stream {
                if Task.isCancelled { break }

                let text = chunk.text
                if !text.isEmpty {
                    accumulatedText += text
                    continuation.yield(AIStreamingProgress(
                        modelReference: model,
                        partialText: accumulatedText,
                        isComplete: false
                    ))
                }
            }

            continuation.yield(AIStreamingProgress(
                modelReference: model,
                partialText: accumulatedText,
                isComplete: true
            ))
        } catch {
            continuation.yield(AIStreamingProgress(
                modelReference: model,
                partialText: "",
                isComplete: true,
                error: error
            ))
        }
    }
}

// MARK: - Convenience Extensions

public extension AIMultiModelExecutor {
    /// Execute a simple text prompt for a category.
    func execute(
        prompt: String,
        systemPrompt: String? = nil,
        categoryId: String
    ) async throws -> AIComparisonResult {
        let request = AICompletionRequest(
            messages: [AIMessage(role: .user, text: prompt)],
            systemPrompt: systemPrompt
        )
        return try await execute(request, for: categoryId)
    }

    /// Execute with a single primary model (no comparison).
    func executePrimary(
        _ request: AICompletionRequest,
        categoryId: String
    ) async throws -> AIModelExecutionResult? {
        guard let model = await categoryManager.primaryModel(for: categoryId) else {
            return nil
        }

        return await executeForModel(request, model: model)
    }
}
