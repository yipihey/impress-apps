//
//  MessageCategoryService.swift
//  MessageManagerCore
//
//  Service for detecting message categories (conversation vs broadcast).
//

import Foundation
import OSLog

private let categoryLogger = Logger(subsystem: "com.impart", category: "category")

// MARK: - Category Detection Rules

/// Rules for detecting message category.
public struct CategoryDetectionRules: Sendable {

    /// Maximum recipients for a conversation (above this = broadcast).
    public var maxConversationRecipients: Int = 5

    /// Email patterns that indicate broadcast messages.
    public var broadcastEmailPatterns: [String] = [
        "noreply",
        "no-reply",
        "newsletter",
        "notifications",
        "updates",
        "marketing",
        "announcements",
        "digest",
        "mailer-daemon",
        "postmaster"
    ]

    /// Header patterns that indicate broadcast/mailing list.
    public var listHeaders: [String] = [
        "List-Unsubscribe",
        "List-Id",
        "List-Post",
        "List-Archive",
        "Precedence: bulk",
        "Precedence: list"
    ]

    public init() {}
}

// MARK: - Message Category Service

/// Service for categorizing messages as conversation or broadcast.
public actor MessageCategoryService {

    public var rules: CategoryDetectionRules

    public init(rules: CategoryDetectionRules = .init()) {
        self.rules = rules
    }

    /// Detect the category of a message.
    public func detectCategory(
        fromAddresses: [EmailAddress],
        toAddresses: [EmailAddress],
        ccAddresses: [EmailAddress],
        bccAddresses: [EmailAddress],
        headers: [String: String]? = nil,
        isFromAgent: Bool = false,
        isToAgent: Bool = false
    ) -> MessageCategory {
        // Agent messages get special category
        if isFromAgent || isToAgent {
            return .agent
        }

        // Check total recipient count
        let totalRecipients = toAddresses.count + ccAddresses.count + bccAddresses.count
        if totalRecipients > rules.maxConversationRecipients {
            return .broadcast
        }

        // Check for mailing list headers
        if let headers = headers {
            for listHeader in rules.listHeaders {
                if listHeader.contains(":") {
                    // Check for header with value
                    let parts = listHeader.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        if let headerValue = headers[key],
                           headerValue.lowercased().contains(value.lowercased()) {
                            return .broadcast
                        }
                    }
                } else {
                    // Just check for header presence
                    if headers.keys.contains(where: { $0.lowercased() == listHeader.lowercased() }) {
                        return .broadcast
                    }
                }
            }
        }

        // Check from address patterns
        for address in fromAddresses {
            let email = address.email.lowercased()
            for pattern in rules.broadcastEmailPatterns {
                if email.contains(pattern) {
                    return .broadcast
                }
            }
        }

        // Default to conversation
        return .conversation
    }

    /// Categorize a CDMessage and update its category field.
    public func categorize(_ message: CDMessage) -> MessageCategory {
        let category = detectCategory(
            fromAddresses: message.fromAddresses,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            bccAddresses: message.bccAddresses,
            headers: nil,  // Could parse from raw message if available
            isFromAgent: message.isFromAgent,
            isToAgent: message.isToAgent
        )

        categoryLogger.debug("Categorized message '\(message.subject)' as \(category.rawValue)")
        return category
    }

    /// Batch categorize messages.
    public func categorizeMessages(_ messages: [CDMessage]) -> [UUID: MessageCategory] {
        var results: [UUID: MessageCategory] = [:]
        for message in messages {
            results[message.id] = categorize(message)
        }
        return results
    }
}

// MARK: - Category Statistics

/// Statistics for message categories.
public struct CategoryStatistics: Sendable {
    public let conversationCount: Int
    public let broadcastCount: Int
    public let agentCount: Int
    public let totalCount: Int

    public var conversationPercentage: Double {
        guard totalCount > 0 else { return 0 }
        return Double(conversationCount) / Double(totalCount) * 100
    }

    public var broadcastPercentage: Double {
        guard totalCount > 0 else { return 0 }
        return Double(broadcastCount) / Double(totalCount) * 100
    }

    public init(conversationCount: Int, broadcastCount: Int, agentCount: Int) {
        self.conversationCount = conversationCount
        self.broadcastCount = broadcastCount
        self.agentCount = agentCount
        self.totalCount = conversationCount + broadcastCount + agentCount
    }
}
