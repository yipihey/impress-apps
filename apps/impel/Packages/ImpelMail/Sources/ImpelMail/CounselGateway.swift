//
//  CounselGateway.swift
//  ImpelMail
//
//  Bridges incoming email to agent orchestration and composes replies.
//

import Foundation
import OSLog

/// A structured task request parsed from an incoming email.
public struct CounselRequest: Sendable {
    public let from: String
    public let subject: String
    public let body: String
    public let messageID: String
    public let inReplyTo: String?
    public let references: [String]
    public let date: Date

    /// Classified intent of the request.
    public let intent: CounselIntent

    public init(from message: MailMessage) {
        self.from = message.from
        self.subject = message.subject
        self.body = message.body
        self.messageID = message.messageID
        self.inReplyTo = message.inReplyTo
        self.references = message.references
        self.date = message.date
        self.intent = CounselIntent.classify(subject: message.subject, body: message.body)
    }

    /// Convenience initializer for programmatic request creation (App Intents, URL schemes).
    public init(subject: String, body: String, from: String, intent: CounselIntent = .general) {
        self.from = from
        self.subject = subject
        self.body = body
        self.messageID = "<\(UUID().uuidString)@impress.local>"
        self.inReplyTo = nil
        self.references = []
        self.date = Date()
        self.intent = intent
    }
}

/// Classified intent of a counsel request.
public enum CounselIntent: String, Sendable {
    case findPapers = "find_papers"
    case summarize = "summarize"
    case draft = "draft"
    case analyze = "analyze"
    case review = "review"
    case general = "general"

    /// Simple keyword-based intent classification.
    public static func classify(subject: String, body: String) -> CounselIntent {
        let text = (subject + " " + body).lowercased()

        if text.contains("find") && (text.contains("paper") || text.contains("article") || text.contains("publication")) {
            return .findPapers
        }
        if text.contains("search") && (text.contains("paper") || text.contains("literature") || text.contains("research")) {
            return .findPapers
        }
        if text.contains("summarize") || text.contains("summary") || text.contains("tldr") || text.contains("tl;dr") {
            return .summarize
        }
        if text.contains("draft") || text.contains("write") || text.contains("compose") {
            return .draft
        }
        if text.contains("analyze") || text.contains("analysis") || text.contains("plot") || text.contains("visualize") {
            return .analyze
        }
        if text.contains("review") || text.contains("check") || text.contains("proofread") || text.contains("critique") {
            return .review
        }

        return .general
    }

    /// Suggested agent type for this intent.
    public var suggestedAgentType: String {
        switch self {
        case .findPapers: return "research"
        case .summarize: return "research"
        case .draft: return "code"
        case .analyze: return "code"
        case .review: return "review"
        case .general: return "research"
        }
    }
}

/// A response to be sent back via email.
public struct CounselResponse: Sendable {
    public let to: String
    public let subject: String
    public let body: String
    public let inReplyTo: String
    public let references: [String]
    public let headers: [String: String]

    public init(to: String, subject: String, body: String, inReplyTo: String, references: [String] = [], headers: [String: String] = [:]) {
        self.to = to
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.headers = headers
    }

    /// Convert to a MailMessage for storage.
    public func toMailMessage() -> MailMessage {
        MailMessage(
            from: "counsel@impress.local",
            to: [to],
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references,
            headers: headers
        )
    }
}

/// Status of a counsel thread.
public enum CounselThreadStatus: String, Sendable {
    case received
    case acknowledged
    case working
    case completed
    case failed
}

/// Tracks a counsel@ conversation thread.
public struct CounselThread: Identifiable, Sendable {
    public let id: String
    public let request: CounselRequest
    public var status: CounselThreadStatus
    public var response: CounselResponse?
    public let createdAt: Date
    public var updatedAt: Date

    public init(request: CounselRequest) {
        self.id = UUID().uuidString
        self.request = request
        self.status = .received
        self.response = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Counsel Gateway

/// Result from a counsel task handler, carrying both the response text and
/// the messageID to use for the reply email (for thread resolution on follow-ups).
public struct CounselTaskResult: Sendable {
    public let body: String
    public let replyMessageID: String?

    public init(body: String, replyMessageID: String? = nil) {
        self.body = body
        self.replyMessageID = replyMessageID
    }
}

/// Bridges email to agent task execution.
///
/// Receives parsed email from SMTPServer, creates research tasks,
/// and stores replies for IMAP retrieval by mail clients.
public actor CounselGateway {

    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel")

    private let store: MessageStore
    private var threads: [String: CounselThread] = [:]

    /// Callback for when a new task should be created.
    /// The caller provides the task execution logic.
    private var onTaskReceived: (@Sendable (CounselRequest) async -> CounselTaskResult)?

    public init(store: MessageStore) {
        self.store = store
    }

    /// Set the handler that executes tasks and returns a response body.
    public func setTaskHandler(_ handler: @escaping @Sendable (CounselRequest) async -> CounselTaskResult) {
        self.onTaskReceived = handler
    }

    /// Start listening for incoming messages from the store.
    public func start() async {
        await store.setIncomingHandler { [weak self] message in
            guard let self = self else { return }
            await self.handleIncoming(message)
        }
        logger.info("Counsel gateway started")
    }

    /// All active threads.
    public var activeThreads: [CounselThread] {
        threads.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Thread count by status.
    public var threadCounts: [CounselThreadStatus: Int] {
        Dictionary(grouping: threads.values, by: \.status).mapValues(\.count)
    }

    // MARK: - Message Handling

    private func handleIncoming(_ message: MailMessage) async {
        let request = CounselRequest(from: message)

        logger.info("Counsel request from \(request.from): \(request.subject) [intent: \(request.intent.rawValue)]")

        var thread = CounselThread(request: request)

        // Build counsel headers for email client auto-filing
        let counselHeaders: [String: String] = [
            "List-Id": "<counsel.impress.local>",
            "X-Mailer": "counsel/impress",
            "X-Counsel-Intent": request.intent.rawValue,
            "X-Counsel-Status": "acknowledged",
        ]

        // Send acknowledgment immediately, quoting the original request
        let quotedBody = request.body.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        let ack = CounselResponse(
            to: request.from,
            subject: "Re: \(request.subject)",
            body: "Received your request. Working on it now.\n\n— counsel@impress.local\n\n\(quotedBody)",
            inReplyTo: request.messageID,
            references: request.references + [request.messageID],
            headers: counselHeaders
        )
        await store.storeReply(ack.toMailMessage())
        thread.status = .acknowledged
        thread.updatedAt = Date()
        threads[thread.id] = thread

        // Execute task
        thread.status = .working
        thread.updatedAt = Date()
        threads[thread.id] = thread

        let taskResult: CounselTaskResult
        if let handler = onTaskReceived {
            taskResult = await handler(request)
        } else {
            taskResult = CounselTaskResult(body: defaultResponse(for: request))
        }

        // Compose and store the reply with counsel headers
        // Use the replyMessageID from CounselEngine if provided (enables thread resolution)
        var replyHeaders = counselHeaders
        replyHeaders["X-Counsel-Status"] = "completed"
        let replyMsg = MailMessage(
            from: "counsel@impress.local",
            to: [request.from],
            subject: "Re: \(request.subject)",
            body: taskResult.body,
            messageID: taskResult.replyMessageID,
            inReplyTo: request.messageID,
            references: request.references + [request.messageID],
            headers: replyHeaders
        )

        let reply = CounselResponse(
            to: request.from,
            subject: "Re: \(request.subject)",
            body: taskResult.body,
            inReplyTo: request.messageID,
            references: request.references + [request.messageID],
            headers: replyHeaders
        )
        thread.response = reply
        thread.status = .completed
        thread.updatedAt = Date()
        threads[thread.id] = thread

        await store.storeReply(replyMsg)
        logger.info("Counsel response sent for: \(request.subject)")
    }

    private func defaultResponse(for request: CounselRequest) -> String {
        """
        Hello,

        I received your request: "\(request.subject)"

        Intent classified as: \(request.intent.rawValue)

        This is the counsel@ gateway running in standalone mode. To enable \
        full agent execution, configure an AI provider in impel settings.

        Your request:
        ---
        \(request.body)
        ---

        Once an AI provider is configured, I'll be able to:
        - Search papers and add them to your imbib library
        - Draft text for your imprint manuscripts
        - Analyze data and create visualizations
        - Review and critique your writing
        - Handle general research tasks

        — counsel@impress.local
        """
    }
}
