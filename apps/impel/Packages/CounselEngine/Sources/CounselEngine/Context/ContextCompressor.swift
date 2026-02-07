import Foundation
import ImpressAI
import OSLog

/// Summarizes old messages when conversation context exceeds token budget.
public actor ContextCompressor {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-compress")
    private let maxContextTokens: Int

    public init(maxContextTokens: Int = 50_000) {
        self.maxContextTokens = maxContextTokens
    }

    /// Compress conversation history if it exceeds the token budget.
    /// Keeps the most recent messages intact and summarizes older ones.
    public func compressIfNeeded(
        messages: [AIMessage],
        database: CounselDatabase,
        conversationID: String
    ) async -> [AIMessage] {
        let totalTokens = estimateTotalTokens(messages)

        guard totalTokens > maxContextTokens else {
            return messages
        }

        logger.info("Compressing context: \(totalTokens) tokens > \(self.maxContextTokens) budget")

        // Keep the last N messages (roughly half the budget)
        let keepCount = max(4, messages.count / 3)
        let recentMessages = Array(messages.suffix(keepCount))
        let oldMessages = Array(messages.prefix(messages.count - keepCount))

        // Build a summary of old messages
        let summary = buildSummary(from: oldMessages)

        // Create a system-like summary message
        let summaryMessage = AIMessage(
            role: .user,
            text: "[Previous conversation summary]\n\(summary)\n[End of summary — conversation continues below]"
        )

        logger.info("Compressed \(oldMessages.count) messages into summary, keeping \(recentMessages.count) recent")

        return [summaryMessage] + recentMessages
    }

    private func buildSummary(from messages: [AIMessage]) -> String {
        var parts: [String] = []

        for message in messages {
            switch message.role {
            case .user:
                let text = message.text
                if !text.isEmpty {
                    parts.append("User asked: \(text.prefix(200))")
                }
            case .assistant:
                let text = message.text
                if !text.isEmpty {
                    parts.append("Assistant responded: \(text.prefix(200))")
                }
                // Note tool uses
                let toolUses = message.content.compactMap { c -> String? in
                    if case .toolUse(let tu) = c { return tu.name }
                    return nil
                }
                if !toolUses.isEmpty {
                    parts.append("Tools used: \(toolUses.joined(separator: ", "))")
                }
            default:
                break
            }
        }

        return parts.joined(separator: "\n")
    }

    private func estimateTotalTokens(_ messages: [AIMessage]) -> Int {
        messages.reduce(0) { total, msg in
            total + msg.content.reduce(0) { subtotal, content in
                switch content {
                case .text(let text): return subtotal + text.count / 4
                case .toolUse(let tu): return subtotal + 50 + tu.name.count
                case .toolResult(let tr): return subtotal + tr.content.count / 4
                default: return subtotal + 10
                }
            }
        }
    }
}
