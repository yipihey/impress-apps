import Foundation
import ImpelMail
import OSLog

/// Sends intermediate status emails during long-running tool chains.
public actor CounselProgressReporter {
    private let logger = Logger(subsystem: "com.impress.impel", category: "counsel-progress")
    private let store: MessageStore
    private let recipientEmail: String
    private let subject: String
    private let originalMessageID: String
    private let references: [String]
    private var lastProgressAt: Date?
    private let minInterval: TimeInterval = 30

    public init(
        store: MessageStore,
        recipientEmail: String,
        subject: String,
        originalMessageID: String,
        references: [String]
    ) {
        self.store = store
        self.recipientEmail = recipientEmail
        self.subject = subject
        self.originalMessageID = originalMessageID
        self.references = references
    }

    /// Send a progress update email if enough time has passed.
    public func sendProgress(round: Int, toolsUsed: String, totalTools: Int) async {
        let now = Date()
        if let last = lastProgressAt, now.timeIntervalSince(last) < minInterval {
            return
        }
        lastProgressAt = now

        let body = """
            [Progress Update - Round \(round)]

            I'm still working on your request. Here's what I've done so far:
            - Executed \(totalTools) tool calls
            - Latest tools: \(toolsUsed)

            I'll send the final response when I'm done.

            — counsel@impress.local
            """

        let message = MailMessage(
            from: "counsel@impress.local",
            to: [recipientEmail],
            subject: "Re: \(subject)",
            body: body,
            inReplyTo: originalMessageID,
            references: references + [originalMessageID],
            headers: [
                "List-Id": "<counsel.impress.local>",
                "X-Mailer": "counsel/impress",
                "X-Counsel-Status": "working",
            ]
        )

        await store.storeReply(message)
        logger.info("Sent progress email for round \(round)")
    }
}
