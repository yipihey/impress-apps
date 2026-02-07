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

    public init() throws {
        self.database = try CounselDatabase()
        self.conversationManager = CounselConversationManager(database: database)
        self.contextCompressor = ContextCompressor()
        self.nativeLoop = NativeAgentLoop()

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

    // MARK: - Request Handling

    private func handleRequest(_ request: CounselRequest, store: MessageStore) async -> CounselTaskResult {
        logger.info("Handling request: '\(request.subject)' from \(request.from) [intent: \(request.intent.rawValue)]")

        // Check if persistence is enabled
        let persistenceEnabled = UserDefaults.standard.object(forKey: "counselPersistenceEnabled") as? Bool ?? true

        // Strip quoted content from the email body
        let body = Self.stripQuotedContent(request.body)

        // Resolve or create conversation (needed for context even if not persisting)
        let conversation: CounselConversation
        do {
            if persistenceEnabled {
                conversation = try conversationManager.resolveConversation(for: request)
            } else {
                // Create an ephemeral conversation object without persisting
                conversation = CounselConversation(
                    subject: request.subject,
                    participantEmail: request.from
                )
            }
        } catch {
            logger.error("Failed to resolve conversation: \(error.localizedDescription)")
            return CounselTaskResult(body: "I encountered an error processing your request: \(error.localizedDescription)\n\n— counsel@impress.local")
        }

        // Persist the user message (only if persistence enabled)
        if persistenceEnabled {
            do {
                _ = try conversationManager.persistUserMessage(
                    conversationID: conversation.id,
                    content: body,
                    emailMessageID: request.messageID,
                    inReplyTo: request.inReplyTo,
                    intent: request.intent.rawValue
                )
            } catch {
                logger.error("Failed to persist user message: \(error.localizedDescription)")
            }
        }

        // Load conversation history
        var history: [AIMessage]
        if persistenceEnabled {
            do {
                history = try conversationManager.loadHistory(conversationID: conversation.id)
            } catch {
                logger.error("Failed to load history: \(error.localizedDescription)")
                history = [AIMessage(role: .user, text: body)]
            }
        } else {
            // No history available without persistence
            history = [AIMessage(role: .user, text: body)]
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

        // Set up progress reporter
        let progressReporter = CounselProgressReporter(
            store: store,
            recipientEmail: request.from,
            subject: request.subject,
            originalMessageID: request.messageID,
            references: request.references
        )

        // Read config from UserDefaults
        let modelId = UserDefaults.standard.string(forKey: "counselModel")
            .flatMap { $0.isEmpty ? nil : $0 }
        let maxTurns = UserDefaults.standard.integer(forKey: "counselMaxTurns")
        let effectiveMaxTurns = maxTurns > 0 ? maxTurns : 40

        logger.info("Agent config: maxTurns=\(effectiveMaxTurns) (from UserDefaults: \(maxTurns)), model=\(modelId ?? "default")")

        let config = AgentLoopConfig(
            maxTurns: effectiveMaxTurns,
            modelId: modelId
        )

        // Run the agentic loop via NativeAgentLoop
        let agentLoop = CounselAgentLoop(
            database: database,
            config: config,
            nativeLoop: nativeLoop
        )
        await agentLoop.setProgressReporter(progressReporter)

        let result = await agentLoop.run(
            conversationID: conversation.id,
            systemPrompt: systemPrompt,
            messages: history
        )

        // Generate a stable reply messageID for thread resolution
        let replyMessageID = "<\(UUID().uuidString)@impress.local>"

        // Persist the assistant response (only if persistence enabled)
        if persistenceEnabled {
            do {
                _ = try conversationManager.persistAssistantMessage(
                    conversationID: conversation.id,
                    content: result.responseText,
                    emailMessageID: replyMessageID,
                    inReplyTo: request.messageID
                )
            } catch {
                logger.error("Failed to persist assistant message: \(error.localizedDescription)")
            }

            // Update conversation status
            do {
                var updated = conversation
                updated.updatedAt = Date()
                updated.totalTokensUsed = conversation.totalTokensUsed + result.totalTokensUsed
                try database.updateConversation(updated)
            } catch {
                logger.error("Failed to update conversation: \(error.localizedDescription)")
            }
        }

        logger.info("Request completed: \(result.roundsUsed) turns, \(result.totalTokensUsed) tokens, \(result.toolExecutions.count) tool calls, finish: \(result.finishReason.rawValue)")

        // Notify sibling apps that a counsel thread completed
        ImpressNotification.post(ImpressNotification.threadCompleted, from: .impel, resourceIDs: [conversation.id])

        // Append status footer for multi-tool responses
        var responseText = result.responseText
        if result.toolExecutions.count > 0 {
            responseText += "\n\n---\n[Used \(result.toolExecutions.count) tool(s) across \(result.roundsUsed) turn(s)]"
        }

        return CounselTaskResult(body: responseText, replyMessageID: replyMessageID)
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
