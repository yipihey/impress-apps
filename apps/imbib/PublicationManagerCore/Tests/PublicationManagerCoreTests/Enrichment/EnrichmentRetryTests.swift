//
//  EnrichmentRetryTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-04.
//

import XCTest
@testable import PublicationManagerCore

final class EnrichmentRetryTests: XCTestCase {

    // MARK: - RetryPolicy Tests

    func testRetryPolicy_defaultValues() {
        let policy = RetryPolicy()

        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.baseDelay, 1.0)
        XCTAssertEqual(policy.maxDelay, 60.0)
        XCTAssertEqual(policy.jitterFactor, 0.2)
    }

    func testRetryPolicy_presets() {
        let userTriggered = RetryPolicy.userTriggered
        XCTAssertEqual(userTriggered.maxAttempts, 3)
        XCTAssertEqual(userTriggered.baseDelay, 0.5)

        let background = RetryPolicy.backgroundSync
        XCTAssertEqual(background.maxAttempts, 5)
        XCTAssertEqual(background.baseDelay, 2.0)

        let noRetry = RetryPolicy.noRetry
        XCTAssertEqual(noRetry.maxAttempts, 1)
    }

    func testRetryPolicy_clampsInvalidValues() {
        let policy = RetryPolicy(
            maxAttempts: 0,
            baseDelay: -1,
            maxDelay: 0.5,
            jitterFactor: 2.0
        )

        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.baseDelay, 0.1)
        XCTAssertGreaterThanOrEqual(policy.maxDelay, policy.baseDelay)
        XCTAssertEqual(policy.jitterFactor, 1.0)
    }

    func testRetryPolicy_delayCalculation() {
        let policy = RetryPolicy(
            baseDelay: 1.0,
            maxDelay: 60.0,
            jitterFactor: 0  // No jitter for predictable testing
        )

        // First attempt has no delay
        XCTAssertEqual(policy.delay(forAttempt: 1), 0)

        // Second attempt: baseDelay * 2^0 = 1.0
        XCTAssertEqual(policy.delay(forAttempt: 2), 1.0)

        // Third attempt: baseDelay * 2^1 = 2.0
        XCTAssertEqual(policy.delay(forAttempt: 3), 2.0)

        // Fourth attempt: baseDelay * 2^2 = 4.0
        XCTAssertEqual(policy.delay(forAttempt: 4), 4.0)
    }

    func testRetryPolicy_delayClampsToMax() {
        let policy = RetryPolicy(
            baseDelay: 10.0,
            maxDelay: 20.0,
            jitterFactor: 0
        )

        // High attempt should be clamped
        let delay = policy.delay(forAttempt: 10)
        XCTAssertLessThanOrEqual(delay, 20.0)
    }

    func testRetryPolicy_shouldRetry_networkError() {
        let policy = RetryPolicy()

        let networkError = EnrichmentError.networkError("Connection failed")
        XCTAssertTrue(policy.shouldRetry(networkError))
    }

    func testRetryPolicy_shouldNotRetry_parseError() {
        let policy = RetryPolicy()

        let parseError = EnrichmentError.parseError("Invalid JSON")
        XCTAssertFalse(policy.shouldRetry(parseError))
    }

    func testRetryPolicy_shouldNotRetry_notFound() {
        let policy = RetryPolicy()

        let notFound = EnrichmentError.notFound
        XCTAssertFalse(policy.shouldRetry(notFound))
    }

    func testRetryPolicy_shouldRetry_rateLimited() {
        let policy = RetryPolicy()

        let rateLimited = EnrichmentError.rateLimited(retryAfter: 60)
        XCTAssertTrue(policy.shouldRetry(rateLimited))
    }

    // MARK: - RetryableErrorType Tests

    func testRetryableErrorType_fromEnrichmentError() {
        XCTAssertEqual(
            RetryableErrorType(from: EnrichmentError.networkError("test")),
            .networkError
        )
        XCTAssertEqual(
            RetryableErrorType(from: EnrichmentError.rateLimited(retryAfter: nil)),
            .rateLimited
        )
        XCTAssertEqual(
            RetryableErrorType(from: EnrichmentError.parseError("test")),
            .parseError
        )
        XCTAssertEqual(
            RetryableErrorType(from: EnrichmentError.authenticationRequired("test")),
            .authenticationRequired
        )
        XCTAssertEqual(
            RetryableErrorType(from: EnrichmentError.notFound),
            .notFound
        )
    }

    func testRetryableErrorType_fromURLError() {
        XCTAssertEqual(
            RetryableErrorType(from: URLError(.notConnectedToInternet)),
            .networkError
        )
        XCTAssertEqual(
            RetryableErrorType(from: URLError(.timedOut)),
            .timeout
        )
        XCTAssertEqual(
            RetryableErrorType(from: URLError(.badServerResponse)),
            .serverError
        )
    }

    func testRetryableErrorType_defaultRetryableSet() {
        let defaults = RetryableErrorType.defaultRetryable

        XCTAssertTrue(defaults.contains(.networkError))
        XCTAssertTrue(defaults.contains(.serverError))
        XCTAssertTrue(defaults.contains(.rateLimited))
        XCTAssertTrue(defaults.contains(.timeout))
        XCTAssertFalse(defaults.contains(.parseError))
        XCTAssertFalse(defaults.contains(.authenticationRequired))
        XCTAssertFalse(defaults.contains(.notFound))
    }

    // MARK: - RetryContext Tests

    func testRetryContext_initialState() {
        let context = RetryContext()

        XCTAssertEqual(context.attemptNumber, 1)
        XCTAssertEqual(context.maxAttempts, 3)
        XCTAssertTrue(context.previousErrors.isEmpty)
        XCTAssertFalse(context.isLastAttempt)
    }

    func testRetryContext_isLastAttempt() {
        let context = RetryContext(attemptNumber: 3, maxAttempts: 3)

        XCTAssertTrue(context.isLastAttempt)
    }

    func testRetryContext_nextAttempt() {
        let context = RetryContext(attemptNumber: 1, maxAttempts: 3)
        let error = EnrichmentError.networkError("test")

        let next = context.nextAttempt(addingError: error)

        XCTAssertEqual(next.attemptNumber, 2)
        XCTAssertEqual(next.previousErrors.count, 1)
        XCTAssertEqual(next.startTime, context.startTime)
    }

    // MARK: - RetryExecutor Tests

    func testRetryExecutor_successOnFirstAttempt() async {
        let executor = RetryExecutor(policy: .userTriggered)

        let result = await executor.execute {
            return "success"
        }

        switch result {
        case .success(let value, let context):
            XCTAssertEqual(value, "success")
            XCTAssertEqual(context.attemptNumber, 1)
        default:
            XCTFail("Expected success")
        }
    }

    func testRetryExecutor_successAfterRetry() async {
        let executor = RetryExecutor(policy: RetryPolicy(
            maxAttempts: 3,
            baseDelay: 0.01,  // Fast for testing
            jitterFactor: 0
        ))

        var attempts = 0

        let result = await executor.execute {
            attempts += 1
            if attempts < 2 {
                throw EnrichmentError.networkError("Temporary failure")
            }
            return "success"
        }

        switch result {
        case .success(let value, let context):
            XCTAssertEqual(value, "success")
            XCTAssertEqual(context.attemptNumber, 2)
            XCTAssertEqual(attempts, 2)
        default:
            XCTFail("Expected success after retry")
        }
    }

    func testRetryExecutor_exhaustsRetries() async {
        let executor = RetryExecutor(policy: RetryPolicy(
            maxAttempts: 3,
            baseDelay: 0.01,
            jitterFactor: 0
        ))

        var attempts = 0

        let result: RetryResult<String> = await executor.execute {
            attempts += 1
            throw EnrichmentError.networkError("Always fails")
        }

        switch result {
        case .exhausted(let errors, let context):
            XCTAssertEqual(errors.count, 3)
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(context.attemptNumber, 3)
        default:
            XCTFail("Expected exhausted")
        }
    }

    func testRetryExecutor_doesNotRetryNonRetryableError() async {
        let executor = RetryExecutor(policy: .userTriggered)

        var attempts = 0

        let result: RetryResult<String> = await executor.execute {
            attempts += 1
            throw EnrichmentError.parseError("Not retryable")
        }

        switch result {
        case .exhausted(let errors, _):
            XCTAssertEqual(errors.count, 1)
            XCTAssertEqual(attempts, 1)
        default:
            XCTFail("Expected immediate failure for non-retryable error")
        }
    }

    func testRetryExecutor_callsOnRetryHandler() async {
        let executor = RetryExecutor(policy: RetryPolicy(
            maxAttempts: 3,
            baseDelay: 0.01,
            jitterFactor: 0
        ))

        var attempts = 0
        var retryContexts: [RetryContext] = []

        let _ = await executor.execute({
            attempts += 1
            if attempts < 3 {
                throw EnrichmentError.networkError("Retry me")
            }
            return "success"
        }, onRetry: { context, _ in
            retryContexts.append(context)
        })

        XCTAssertEqual(retryContexts.count, 2)
        XCTAssertEqual(retryContexts[0].attemptNumber, 2)
        XCTAssertEqual(retryContexts[1].attemptNumber, 3)
    }

    // MARK: - FailedRequestTracker Tests

    func testFailedRequestTracker_recordsFailure() async {
        let tracker = FailedRequestTracker()
        let pubID = UUID()

        await tracker.recordFailure(
            publicationID: pubID,
            identifiers: [.doi: "10.1234/test"],
            error: EnrichmentError.networkError("test")
        )

        let count = await tracker.failureCount
        XCTAssertEqual(count, 1)
    }

    func testFailedRequestTracker_incrementsRetryCount() async {
        let tracker = FailedRequestTracker()
        let pubID = UUID()

        await tracker.recordFailure(
            publicationID: pubID,
            identifiers: [.doi: "10.1234/test"],
            error: EnrichmentError.networkError("first")
        )

        await tracker.recordFailure(
            publicationID: pubID,
            identifiers: [.doi: "10.1234/test"],
            error: EnrichmentError.networkError("second")
        )

        let requests = await tracker.requestsForRetry()
        XCTAssertEqual(requests.first?.retryCount, 1)
    }

    func testFailedRequestTracker_clearsFailure() async {
        let tracker = FailedRequestTracker()
        let pubID = UUID()

        await tracker.recordFailure(
            publicationID: pubID,
            identifiers: [.doi: "10.1234/test"],
            error: EnrichmentError.networkError("test")
        )

        await tracker.clearFailure(for: pubID)

        let count = await tracker.failureCount
        XCTAssertEqual(count, 0)
    }

    func testFailedRequestTracker_requestsForRetry() async {
        let tracker = FailedRequestTracker()

        for i in 0..<3 {
            await tracker.recordFailure(
                publicationID: UUID(),
                identifiers: [.doi: "10.1234/\(i)"],
                error: EnrichmentError.networkError("test")
            )
        }

        let requests = await tracker.requestsForRetry()
        XCTAssertEqual(requests.count, 3)
    }

    func testFailedRequestTracker_clearAll() async {
        let tracker = FailedRequestTracker()

        for i in 0..<5 {
            await tracker.recordFailure(
                publicationID: UUID(),
                identifiers: [.doi: "10.1234/\(i)"],
                error: EnrichmentError.networkError("test")
            )
        }

        await tracker.clearAll()

        let count = await tracker.failureCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - RetryResult Tests

    func testRetryResult_successUnwrapsToResult() {
        let context = RetryContext()
        let retryResult = RetryResult<String>.success("value", context)

        let result = retryResult.result
        switch result {
        case .success(let value):
            XCTAssertEqual(value, "value")
        case .failure:
            XCTFail("Expected success")
        }
    }

    func testRetryResult_exhaustedUnwrapsToFailure() {
        let context = RetryContext()
        let error = EnrichmentError.networkError("test")
        let retryResult = RetryResult<String>.exhausted([error], context)

        let result = retryResult.result
        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure:
            break // Success
        }
    }

    func testRetryResult_cancelledUnwrapsToFailure() {
        let context = RetryContext()
        let retryResult = RetryResult<String>.cancelled(context)

        let result = retryResult.result
        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failure(let error):
            XCTAssertTrue(error is EnrichmentError)
        }
    }
}
