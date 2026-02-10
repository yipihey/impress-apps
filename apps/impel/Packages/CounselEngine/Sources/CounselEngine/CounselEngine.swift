import Foundation
import ImpelMail
import ImpressAI
import ImpressKit
import OSLog

/// Public facade for the CounselEngine — wires everything together and provides
/// the task handler for the mail gateway.
///
/// Tool use is dispatched via HTTP to sibling apps using `NativeAgentLoop` +
/// `CounselToolRegistry`. Fully App Store compliant — no Process() calls.
public final class CounselEngine: Sendable {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-engine")
    public let database: CounselDatabase
    private let conversationManager: CounselConversationManager
    private let contextCompressor: ContextCompressor
    public let nativeLoop: NativeAgentLoop

    /// Task orchestrator for structured programmatic task submission.
    public let taskOrchestrator: TaskOrchestrator

    public init() throws {
        self.database = try CounselDatabase()
        self.conversationManager = CounselConversationManager(database: database)
        self.contextCompressor = ContextCompressor()
        self.nativeLoop = NativeAgentLoop()
        self.taskOrchestrator = TaskOrchestrator(
            database: database,
            conversationManager: conversationManager,
            contextCompressor: contextCompressor,
            nativeLoop: nativeLoop
        )

        logger.info("CounselEngine initialized (native API mode)")
    }

    /// Create a task handler suitable for `MailGatewayState.setTaskHandler()`.
    /// This is the main integration point with ImpelMail.
    public func makeTaskHandler(store: MessageStore) -> @Sendable (CounselRequest) async -> CounselTaskResult {
        let engine = self

        return { request in
            await engine.handleRequest(request, store: store)
        }
    }

    // MARK: - Request Handling (Email Gateway Adapter)

    /// Handle a request from the email gateway.
    ///
    /// This is a thin adapter that converts an email-based CounselRequest into a
    /// structured TaskRequest, submits it to the TaskOrchestrator, waits for the
    /// result, and formats it for email delivery. The email gateway is no longer
    /// the core execution path — the Task API is.
    private func handleRequest(_ request: CounselRequest, store: MessageStore) async -> CounselTaskResult {
        logger.info("Handling email request: '\(request.subject)' from \(request.from) [intent: \(request.intent.rawValue)]")

        // Strip quoted content from the email body
        let body = Self.stripQuotedContent(request.body)

        // Resolve conversation via email headers for thread continuity
        let conversationID: String?
        let persistenceEnabled = UserDefaults.standard.object(forKey: "counselPersistenceEnabled") as? Bool ?? true
        if persistenceEnabled {
            do {
                let conversation = try conversationManager.resolveConversation(for: request)
                conversationID = conversation.id

                // Persist the email-specific user message with messageID for threading
                _ = try conversationManager.persistUserMessage(
                    conversationID: conversation.id,
                    content: body,
                    emailMessageID: request.messageID,
                    inReplyTo: request.inReplyTo,
                    intent: request.intent.rawValue
                )
            } catch {
                logger.error("Failed to resolve conversation: \(error.localizedDescription)")
                return CounselTaskResult(body: "I encountered an error processing your request: \(error.localizedDescription)\n\n— counsel@impress.local")
            }
        } else {
            conversationID = nil
        }

        // Submit as a structured task via the orchestrator.
        // Skip user/assistant persistence since the email adapter handles it
        // with email-specific metadata (messageID, inReplyTo).
        let taskRequest = TaskRequest(
            intent: request.intent.rawValue,
            query: body,
            sourceApp: "email",
            conversationID: conversationID,
            skipUserPersistence: true,
            skipAssistantPersistence: true
        )

        do {
            let result = try await taskOrchestrator.submitAndWait(taskRequest)

            // Generate a stable reply messageID for email thread resolution
            let replyMessageID = "<\(UUID().uuidString)@impress.local>"

            // Persist email-specific assistant message with threading info
            if persistenceEnabled, let convID = conversationID {
                _ = try? conversationManager.persistAssistantMessage(
                    conversationID: convID,
                    content: result.responseText ?? "",
                    emailMessageID: replyMessageID,
                    inReplyTo: request.messageID
                )
            }

            var responseText = result.responseText ?? "I completed the task but couldn't generate a summary."
            if !result.toolExecutions.isEmpty {
                responseText += "\n\n---\n[Used \(result.toolExecutions.count) tool(s) across \(result.roundsUsed) turn(s)]"
            }

            logger.info("Email request completed via task \(result.taskID): \(result.roundsUsed) turns, \(result.totalTokensUsed) tokens")

            return CounselTaskResult(body: responseText, replyMessageID: replyMessageID)
        } catch {
            logger.error("Task submission failed for email request: \(error.localizedDescription)")
            return CounselTaskResult(body: "I encountered an error: \(error.localizedDescription)\n\n— counsel@impress.local")
        }
    }

    // MARK: - Public Data Access

    /// Get all conversations for UI display.
    public func allConversations() throws -> [CounselConversation] {
        try database.fetchAllConversations()
    }

    /// Get messages for a conversation.
    public func messages(for conversationID: String) throws -> [CounselMessage] {
        try database.fetchMessages(conversationID: conversationID)
    }

    /// Get tool executions for a conversation.
    public func toolExecutions(for conversationID: String) throws -> [CounselToolExecution] {
        try database.fetchToolExecutions(conversationID: conversationID)
    }

    /// Search across all conversation messages.
    public func searchMessages(query: String) throws -> [CounselMessage] {
        try database.searchMessages(query: query)
    }

    // MARK: - Mail Store Rehydration

    /// Rehydrate the IMAP MessageStore from persisted conversations so the
    /// email client sees previous messages after an app restart.
    public func rehydrateMailStore(store: MessageStore) async {
        do {
            let conversations = try database.fetchAllConversations(limit: 500)
            var rehydrated = 0

            for conversation in conversations.reversed() { // oldest first
                let messages = try database.fetchMessages(conversationID: conversation.id)

                // Build a references chain for threading
                var references: [String] = []

                for message in messages {
                    // Skip tool use/result messages — they're internal
                    guard message.role == .user || message.role == .assistant else {
                        continue
                    }

                    let emailMsgID = message.emailMessageID ?? "<\(message.id)@impress.local>"

                    let isReply = !references.isEmpty
                    let subject = isReply && !conversation.subject.hasPrefix("Re: ")
                        ? "Re: \(conversation.subject)"
                        : conversation.subject

                    let from: String
                    let to: [String]
                    if message.role == .user {
                        from = conversation.participantEmail
                        to = ["counsel@impress.local"]
                    } else {
                        from = "counsel@impress.local"
                        to = [conversation.participantEmail]
                    }

                    let mailMessage = MailMessage(
                        from: from,
                        to: to,
                        subject: subject,
                        body: message.content,
                        date: message.createdAt,
                        messageID: emailMsgID,
                        inReplyTo: message.inReplyTo,
                        references: references,
                        headers: [
                            "List-Id": "<counsel.impress.local>",
                            "X-Mailer": "counsel/impress",
                            "X-Counsel-Intent": message.intent ?? "general",
                            "X-Counsel-Status": message.role == .assistant ? "completed" : "received",
                        ],
                        flags: [.seen] // Mark rehydrated messages as already seen
                    )

                    await store.storeReply(mailMessage)
                    rehydrated += 1

                    // Add to references chain AFTER storing (so this message's ID
                    // is in the chain for subsequent messages)
                    references.append(emailMsgID)
                }
            }

            if rehydrated > 0 {
                logger.info("Rehydrated \(rehydrated) messages into IMAP store from \(conversations.count) conversations")
            }
        } catch {
            logger.error("Failed to rehydrate mail store: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Strips quoted lines (starting with ">") and common email signature markers from an email body.
    static func stripQuotedContent(_ body: String) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "--" { break }
            if line.hasPrefix(">") { continue }
            if line.hasPrefix("On ") && line.hasSuffix("wrote:") { continue }
            lines.append(line)
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
