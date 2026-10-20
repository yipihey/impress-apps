//
//  RateLimiter.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Rate Limit

/// Rate limiting configuration for a query assistant.
public struct RateLimit: Sendable, Equatable {

    /// Maximum requests per interval
    public let requestsPerInterval: Int

    /// Time interval in seconds
    public let intervalSeconds: TimeInterval

    public init(requestsPerInterval: Int, intervalSeconds: TimeInterval) {
        self.requestsPerInterval = requestsPerInterval
        self.intervalSeconds = intervalSeconds
    }

    /// No rate limiting
    public static let none = RateLimit(requestsPerInterval: Int.max, intervalSeconds: 1)

    /// Minimum delay between requests
    public var minDelay: TimeInterval {
        guard requestsPerInterval > 0 else { return 0 }
        return intervalSeconds / Double(requestsPerInterval)
    }
}
import OSLog

// MARK: - Rate Limiter

/// Actor that manages rate limiting for API requests.
/// Ensures requests don't exceed the configured rate.
public actor RateLimiter {

    // MARK: - Properties

    private let rateLimit: RateLimit
    private var lastRequestTime: Date?
    private var requestCount: Int = 0
    private var windowStart: Date?

    // MARK: - Initialization

    public init(rateLimit: RateLimit) {
        self.rateLimit = rateLimit
    }

    // MARK: - Rate Limiting

    /// Wait if necessary to respect rate limits
    public func waitIfNeeded() async {
        guard rateLimit.requestsPerInterval < Int.max else { return }

        let now = Date()

        // Simple approach: enforce minimum delay between requests
        if let lastTime = lastRequestTime {
            let elapsed = now.timeIntervalSince(lastTime)
            let requiredDelay = rateLimit.minDelay

            if elapsed < requiredDelay {
                let waitTime = requiredDelay - elapsed
                Logger.rateLimiter.debug("Rate limiting: waiting \(waitTime, format: .fixed(precision: 2))s")
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }

        lastRequestTime = Date()
    }

    /// Record a request (for more complex rate limiting)
    public func recordRequest() {
        let now = Date()

        // Reset window if needed
        if let start = windowStart, now.timeIntervalSince(start) > rateLimit.intervalSeconds {
            windowStart = now
            requestCount = 0
        }

        if windowStart == nil {
            windowStart = now
        }

        requestCount += 1
        lastRequestTime = now
    }

    /// Check if we can make a request without waiting
    public func canMakeRequest() -> Bool {
        guard rateLimit.requestsPerInterval < Int.max else { return true }

        let now = Date()

        // Check window-based limit
        if let start = windowStart {
            if now.timeIntervalSince(start) > rateLimit.intervalSeconds {
                return true  // Window expired
            }
            return requestCount < rateLimit.requestsPerInterval
        }

        return true
    }

    /// Reset the rate limiter
    public func reset() {
        lastRequestTime = nil
        requestCount = 0
        windowStart = nil
    }
}
