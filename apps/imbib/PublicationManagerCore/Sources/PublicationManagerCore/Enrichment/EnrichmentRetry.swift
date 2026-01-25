//
//  EnrichmentRetry.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Retry Policy

/// Configuration for retry behavior during enrichment operations.
public struct RetryPolicy: Sendable {

    /// Maximum number of retry attempts
    public let maxAttempts: Int

    /// Base delay between retries (exponential backoff applied)
    public let baseDelay: TimeInterval

    /// Maximum delay between retries
    public let maxDelay: TimeInterval

    /// Jitter factor (0-1) to add randomness to delays
    public let jitterFactor: Double

    /// Whether to retry on specific error types
    public let retryableErrors: Set<RetryableErrorType>

    // MARK: - Initialization

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        jitterFactor: Double = 0.2,
        retryableErrors: Set<RetryableErrorType> = RetryableErrorType.defaultRetryable
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0.1, baseDelay)
        self.maxDelay = max(baseDelay, maxDelay)
        self.jitterFactor = max(0, min(1, jitterFactor))
        self.retryableErrors = retryableErrors
    }

    // MARK: - Presets

    /// Default retry policy for user-triggered actions
    public static let userTriggered = RetryPolicy(
        maxAttempts: 3,
        baseDelay: 0.5,
        maxDelay: 10.0
    )

    /// Aggressive retry policy for background sync
    public static let backgroundSync = RetryPolicy(
        maxAttempts: 5,
        baseDelay: 2.0,
        maxDelay: 120.0
    )

    /// No retries - fail immediately
    public static let noRetry = RetryPolicy(
        maxAttempts: 1,
        baseDelay: 0,
        maxDelay: 0
    )

    // MARK: - Delay Calculation

    /// Calculate delay for a given attempt number (1-indexed)
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }

        // Exponential backoff: baseDelay * 2^(attempt-2)
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt - 2))
        let clampedDelay = min(exponentialDelay, maxDelay)

        // Add jitter
        let jitter = clampedDelay * jitterFactor * Double.random(in: -1...1)
        return max(0, clampedDelay + jitter)
    }

    /// Check if an error should be retried
    public func shouldRetry(_ error: Error) -> Bool {
        let errorType = RetryableErrorType(from: error)
        return retryableErrors.contains(errorType)
    }
}

// MARK: - Retryable Error Types

/// Categories of errors that can be retried.
public enum RetryableErrorType: String, Sendable, Hashable {
    /// Network connectivity issues
    case networkError

    /// Server returned 5xx error
    case serverError

    /// Rate limiting / 429 response
    case rateLimited

    /// Request timed out
    case timeout

    /// Temporary failure (general)
    case temporaryFailure

    /// Parse error (not retryable by default)
    case parseError

    /// Authentication required (not retryable)
    case authenticationRequired

    /// Resource not found (not retryable)
    case notFound

    /// Unknown error type
    case unknown

    /// Default set of retryable errors
    public static let defaultRetryable: Set<RetryableErrorType> = [
        .networkError,
        .serverError,
        .rateLimited,
        .timeout,
        .temporaryFailure
    ]

    /// Initialize from an error
    public init(from error: Error) {
        if let enrichmentError = error as? EnrichmentError {
            switch enrichmentError {
            case .networkError:
                self = .networkError
            case .rateLimited:
                self = .rateLimited
            case .parseError:
                self = .parseError
            case .authenticationRequired:
                self = .authenticationRequired
            case .notFound:
                self = .notFound
            case .noIdentifier, .noSourceAvailable, .cancelled:
                self = .unknown
            }
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                self = .networkError
            case .timedOut:
                self = .timeout
            case .badServerResponse:
                self = .serverError
            default:
                self = .temporaryFailure
            }
        } else {
            self = .unknown
        }
    }
}

// MARK: - Retry Context

/// Context for a retry operation, tracking attempts and errors.
public struct RetryContext: Sendable {
    /// Current attempt number (1-indexed)
    public let attemptNumber: Int

    /// Total allowed attempts
    public let maxAttempts: Int

    /// Errors from previous attempts
    public let previousErrors: [Error]

    /// Time of the original request
    public let startTime: Date

    /// Whether this is the last attempt
    public var isLastAttempt: Bool {
        attemptNumber >= maxAttempts
    }

    /// Total elapsed time since start
    public var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    public init(
        attemptNumber: Int = 1,
        maxAttempts: Int = 3,
        previousErrors: [Error] = [],
        startTime: Date = Date()
    ) {
        self.attemptNumber = attemptNumber
        self.maxAttempts = maxAttempts
        self.previousErrors = previousErrors
        self.startTime = startTime
    }

    /// Create context for next attempt
    func nextAttempt(addingError error: Error) -> RetryContext {
        RetryContext(
            attemptNumber: attemptNumber + 1,
            maxAttempts: maxAttempts,
            previousErrors: previousErrors + [error],
            startTime: startTime
        )
    }
}

// MARK: - Retry Result

/// Result of a retry operation with additional context.
public enum RetryResult<T: Sendable>: Sendable {
    /// Operation succeeded
    case success(T, RetryContext)

    /// All retries exhausted
    case exhausted([Error], RetryContext)

    /// Operation was cancelled
    case cancelled(RetryContext)

    /// Unwrap to regular Result
    public var result: Result<T, Error> {
        switch self {
        case .success(let value, _):
            return .success(value)
        case .exhausted(let errors, _):
            return .failure(errors.last ?? EnrichmentError.noSourceAvailable)
        case .cancelled:
            return .failure(EnrichmentError.cancelled)
        }
    }
}

// MARK: - Retry Executor

/// Executes operations with retry logic.
public actor RetryExecutor {

    private let policy: RetryPolicy

    public init(policy: RetryPolicy = .userTriggered) {
        self.policy = policy
    }

    /// Execute an operation with retries.
    ///
    /// - Parameters:
    ///   - operation: The async operation to execute
    ///   - onRetry: Optional callback before each retry
    /// - Returns: The result with retry context
    public func execute<T: Sendable>(
        _ operation: @Sendable () async throws -> T,
        onRetry: (@Sendable (RetryContext, Error) async -> Void)? = nil
    ) async -> RetryResult<T> {
        var context = RetryContext(maxAttempts: policy.maxAttempts)

        while true {
            do {
                // Check for cancellation
                try Task.checkCancellation()

                // Execute the operation
                let result = try await operation()
                return .success(result, context)

            } catch is CancellationError {
                return .cancelled(context)

            } catch {
                // Check if we should retry
                guard context.attemptNumber < policy.maxAttempts,
                      policy.shouldRetry(error) else {
                    let errors = context.previousErrors + [error]
                    return .exhausted(errors, context)
                }

                // Prepare for retry
                context = context.nextAttempt(addingError: error)

                // Call retry handler
                await onRetry?(context, error)

                // Wait before retrying
                let delay = policy.delay(forAttempt: context.attemptNumber)
                if delay > 0 {
                    Logger.enrichment.infoCapture(
                        "Retry: waiting \(String(format: "%.1f", delay))s before attempt \(context.attemptNumber)/\(policy.maxAttempts)",
                        category: "enrichment"
                    )
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }
}

// MARK: - Failed Request Tracking

/// Tracks failed enrichment requests for later retry.
public actor FailedRequestTracker {

    /// A failed request with error information
    public struct FailedRequest: Sendable, Identifiable {
        public let id: UUID
        public let publicationID: UUID
        public let identifiers: [IdentifierType: String]
        public let error: String
        public let failedAt: Date
        public var retryCount: Int

        public init(
            publicationID: UUID,
            identifiers: [IdentifierType: String],
            error: Error,
            retryCount: Int = 0
        ) {
            self.id = UUID()
            self.publicationID = publicationID
            self.identifiers = identifiers
            self.error = error.localizedDescription
            self.failedAt = Date()
            self.retryCount = retryCount
        }
    }

    // MARK: - State

    private var failedRequests: [UUID: FailedRequest] = [:]
    private let maxStoredFailures = 100
    private let maxRetries = 5

    // MARK: - Tracking

    /// Record a failed enrichment request
    public func recordFailure(
        publicationID: UUID,
        identifiers: [IdentifierType: String],
        error: Error
    ) {
        // Check if already tracked
        if var existing = failedRequests[publicationID] {
            existing.retryCount += 1
            if existing.retryCount <= maxRetries {
                failedRequests[publicationID] = existing
            } else {
                // Too many retries, remove from tracking
                failedRequests.removeValue(forKey: publicationID)
            }
        } else {
            // New failure
            let request = FailedRequest(
                publicationID: publicationID,
                identifiers: identifiers,
                error: error
            )
            failedRequests[publicationID] = request

            // Evict oldest if over limit
            pruneIfNeeded()
        }

        Logger.enrichment.warningCapture(
            "Failed request recorded: \(publicationID.uuidString.prefix(8))... (retry #\(failedRequests[publicationID]?.retryCount ?? 0))",
            category: "enrichment"
        )
    }

    /// Remove a publication from tracking (e.g., after successful retry)
    public func clearFailure(for publicationID: UUID) {
        if failedRequests.removeValue(forKey: publicationID) != nil {
            Logger.enrichment.infoCapture(
                "Cleared failed request: \(publicationID.uuidString.prefix(8))...",
                category: "enrichment"
            )
        }
    }

    /// Get all failed requests ready for retry
    public func requestsForRetry() -> [FailedRequest] {
        Array(failedRequests.values)
            .filter { $0.retryCount < maxRetries }
            .sorted { $0.failedAt < $1.failedAt }
    }

    /// Get failed request count
    public var failureCount: Int {
        failedRequests.count
    }

    /// Clear all tracked failures
    public func clearAll() {
        let count = failedRequests.count
        failedRequests.removeAll()
        if count > 0 {
            Logger.enrichment.infoCapture(
                "Cleared all \(count) failed requests",
                category: "enrichment"
            )
        }
    }

    // MARK: - Private

    private func pruneIfNeeded() {
        guard failedRequests.count > maxStoredFailures else { return }

        // Remove oldest entries
        let sortedKeys = failedRequests
            .sorted { $0.value.failedAt < $1.value.failedAt }
            .prefix(failedRequests.count - maxStoredFailures)
            .map { $0.key }

        for key in sortedKeys {
            failedRequests.removeValue(forKey: key)
        }
    }
}

// MARK: - Convenience Extension

extension EnrichmentService {

    /// Enrich with automatic retries.
    ///
    /// - Parameters:
    ///   - identifiers: Available identifiers for the paper
    ///   - policy: Retry policy to use
    ///   - onRetry: Optional callback before each retry
    /// - Returns: Enrichment result
    /// - Throws: If all retries are exhausted
    public func enrichWithRetry(
        identifiers: [IdentifierType: String],
        policy: RetryPolicy = .userTriggered,
        onRetry: (@Sendable (Int, Error) async -> Void)? = nil
    ) async throws -> EnrichmentResult {
        let idDescription = identifiers.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: ", ")
        Logger.enrichment.infoCapture(
            "Starting enrichment with retry (max \(policy.maxAttempts) attempts): \(idDescription)",
            category: "enrichment"
        )

        let executor = RetryExecutor(policy: policy)

        let result = await executor.execute({
            try await self.enrichNow(identifiers: identifiers)
        }, onRetry: { context, error in
            Logger.enrichment.warningCapture(
                "Enrichment attempt \(context.attemptNumber - 1) failed: \(error.localizedDescription)",
                category: "enrichment"
            )
            await onRetry?(context.attemptNumber, error)
        })

        switch result {
        case .success(let enrichmentResult, let context):
            Logger.enrichment.infoCapture(
                "Enrichment succeeded on attempt \(context.attemptNumber): \(enrichmentResult.data.source.displayName) - citations: \(enrichmentResult.data.citationCount ?? 0)",
                category: "enrichment"
            )
            return enrichmentResult
        case .exhausted(let errors, let context):
            Logger.enrichment.errorCapture(
                "Enrichment exhausted after \(context.attemptNumber) attempts: \(errors.last?.localizedDescription ?? "unknown")",
                category: "enrichment"
            )
            throw errors.last ?? EnrichmentError.noSourceAvailable
        case .cancelled:
            Logger.enrichment.infoCapture(
                "Enrichment cancelled",
                category: "enrichment"
            )
            throw EnrichmentError.cancelled
        }
    }
}
