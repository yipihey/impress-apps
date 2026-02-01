//
//  MboxConversationStore.swift
//  MessageManagerCore
//
//  Manages research conversations stored in mbox files.
//  Each conversation is a separate mbox file in the conversations directory.
//

import Foundation
import OSLog

private let mboxLogger = Logger(subsystem: "com.impress.impart", category: "mbox")

// MARK: - Mbox Message

/// A message in mbox format for research conversations.
public struct MboxMessage: Identifiable, Sendable, Codable {
    public let id: UUID
    public let messageId: String
    public let inReplyTo: String?
    public let references: [String]
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let subject: String
    public let date: Date
    public let body: String
    public let role: ConversationRole
    public let model: String?
    public let artifactURI: String?
    public let artifactType: String?

    public init(
        id: UUID = UUID(),
        messageId: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        from: EmailAddress,
        to: [EmailAddress],
        subject: String,
        date: Date = Date(),
        body: String,
        role: ConversationRole,
        model: String? = nil,
        artifactURI: String? = nil,
        artifactType: String? = nil
    ) {
        self.id = id
        self.messageId = messageId ?? "<\(id.uuidString)@impart.local>"
        self.inReplyTo = inReplyTo
        self.references = references
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.body = body
        self.role = role
        self.model = model
        self.artifactURI = artifactURI
        self.artifactType = artifactType
    }

    /// Create a user message.
    public static func userMessage(
        from email: String,
        subject: String,
        body: String,
        replyTo: MboxMessage? = nil
    ) -> MboxMessage {
        MboxMessage(
            inReplyTo: replyTo?.messageId,
            references: buildReferences(replyTo: replyTo),
            from: EmailAddress(email: email),
            to: [EmailAddress(name: "AI Counsel", email: "counsel@impart.local")],
            subject: replyTo != nil ? "Re: \(subject.replacingOccurrences(of: "Re: ", with: ""))" : subject,
            body: body,
            role: .human
        )
    }

    /// Create an AI counsel message.
    public static func counselMessage(
        model: String,
        body: String,
        replyTo: MboxMessage
    ) -> MboxMessage {
        MboxMessage(
            inReplyTo: replyTo.messageId,
            references: buildReferences(replyTo: replyTo),
            from: EmailAddress(name: "AI Counsel (\(model))", email: "counsel@impart.local"),
            to: [replyTo.from],
            subject: "Re: \(replyTo.subject.replacingOccurrences(of: "Re: ", with: ""))",
            body: body,
            role: .counsel,
            model: model
        )
    }

    /// Create an artifact reference message.
    public static func artifactMessage(
        from email: String,
        artifactURI: String,
        artifactType: String,
        description: String,
        replyTo: MboxMessage? = nil
    ) -> MboxMessage {
        MboxMessage(
            inReplyTo: replyTo?.messageId,
            references: buildReferences(replyTo: replyTo),
            from: EmailAddress(email: email),
            to: [EmailAddress(name: "Artifacts", email: "artifacts@impart.local")],
            subject: "Artifact: \(artifactType)",
            body: "Artifact: \(artifactURI)\nType: \(artifactType)\n\n\(description)",
            role: .artifact,
            artifactURI: artifactURI,
            artifactType: artifactType
        )
    }

    private static func buildReferences(replyTo: MboxMessage?) -> [String] {
        guard let replyTo else { return [] }
        var refs = replyTo.references
        refs.append(replyTo.messageId)
        return refs
    }

    /// Format as mbox entry string.
    public func toMboxString(conversationId: UUID, conversationTitle: String) -> String {
        var lines: [String] = []

        // From_ line (envelope)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        lines.append("From \(from.email) \(dateFormatter.string(from: date))")

        // Standard headers
        lines.append("From: \(from.rfc5322)")
        lines.append("To: \(to.map(\.rfc5322).joined(separator: ", "))")
        lines.append("Subject: \(subject)")

        let rfc2822Formatter = DateFormatter()
        rfc2822Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        rfc2822Formatter.locale = Locale(identifier: "en_US_POSIX")
        lines.append("Date: \(rfc2822Formatter.string(from: date))")

        lines.append("Message-ID: \(messageId)")

        if let inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
        }

        if !references.isEmpty {
            lines.append("References: \(references.joined(separator: " "))")
        }

        // Custom headers
        lines.append("X-Impart-Conversation-ID: \(conversationId.uuidString)")
        lines.append("X-Impart-Conversation-Title: \(conversationTitle)")
        lines.append("X-Impart-Role: \(role.rawValue)")

        if let model {
            lines.append("X-Impart-Model: \(model)")
        }

        if let artifactURI {
            lines.append("X-Impart-Artifact-URI: \(artifactURI)")
        }

        if let artifactType {
            lines.append("X-Impart-Artifact-Type: \(artifactType)")
        }

        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("MIME-Version: 1.0")

        // Blank line before body
        lines.append("")

        // Body with From_ escaping
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("From ") || line.hasPrefix(">From ") {
                lines.append(">" + line)
            } else {
                lines.append(line)
            }
        }

        // Trailing newline
        lines.append("")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Conversation Role

/// Role of a participant in a research conversation.
public enum ConversationRole: String, Codable, Sendable {
    case human
    case counsel
    case system
    case artifact
}

// MARK: - Mbox Conversation

/// A research conversation backed by an mbox file.
public struct MboxConversation: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var lastActivityAt: Date
    public var messages: [MboxMessage]
    public let filePath: URL

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        filePath: URL
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActivityAt = createdAt
        self.messages = []
        self.filePath = filePath
    }

    /// Message count.
    public var messageCount: Int { messages.count }

    /// Latest message preview.
    public var latestSnippet: String {
        messages.last?.body.prefix(100).description ?? ""
    }

    /// Participants in the conversation.
    public var participants: [String] {
        var emails = Set<String>()
        for msg in messages {
            emails.insert(msg.from.email)
            for to in msg.to {
                emails.insert(to.email)
            }
        }
        return Array(emails).sorted()
    }
}

// MARK: - Mbox Conversation Store

/// Manages research conversations stored as mbox files.
public actor MboxConversationStore {
    private let baseDirectory: URL
    private var conversations: [UUID: MboxConversation] = [:]

    public init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            // Default to Application Support/impart/conversations
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("impart/conversations", isDirectory: true)
        }
    }

    /// Ensure the base directory exists.
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Load all conversations from disk.
    public func loadConversations() async throws -> [MboxConversation] {
        try ensureDirectory()

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.creationDateKey])

        var loaded: [MboxConversation] = []

        for url in contents where url.pathExtension == "mbox" {
            if let conv = try? loadConversation(from: url) {
                conversations[conv.id] = conv
                loaded.append(conv)
            }
        }

        mboxLogger.info("Loaded \(loaded.count) conversations from \(self.baseDirectory.path)")
        return loaded.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Load a single conversation from an mbox file.
    private func loadConversation(from url: URL) throws -> MboxConversation {
        let content = try String(contentsOf: url, encoding: .utf8)
        let messages = parseMbox(content: content)

        // Extract metadata from first message
        let firstMessage = messages.first
        let id = firstMessage.flatMap { msg in
            msg.body.components(separatedBy: "\n")
                .first { $0.hasPrefix("X-Impart-Conversation-ID:") }
                .flatMap { UUID(uuidString: $0.replacingOccurrences(of: "X-Impart-Conversation-ID: ", with: "").trimmingCharacters(in: .whitespaces)) }
        } ?? UUID()

        let title = firstMessage?.subject.replacingOccurrences(of: "Re: ", with: "") ?? "Untitled"
        let createdAt = messages.first?.date ?? Date()
        let lastActivityAt = messages.last?.date ?? createdAt

        var conversation = MboxConversation(
            id: id,
            title: title,
            createdAt: createdAt,
            filePath: url
        )
        conversation.messages = messages
        conversation.lastActivityAt = lastActivityAt

        return conversation
    }

    /// Parse mbox content into messages.
    private func parseMbox(content: String) -> [MboxMessage] {
        var messages: [MboxMessage] = []
        var currentMessageLines: [String] = []

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("From ") && !line.hasPrefix("From:") && !currentMessageLines.isEmpty {
                // Start of new message
                if let msg = parseMessage(lines: currentMessageLines) {
                    messages.append(msg)
                }
                currentMessageLines = []
            }
            currentMessageLines.append(line)
        }

        // Parse last message
        if !currentMessageLines.isEmpty, let msg = parseMessage(lines: currentMessageLines) {
            messages.append(msg)
        }

        return messages
    }

    /// Parse a single message from lines.
    private func parseMessage(lines: [String]) -> MboxMessage? {
        var headers: [String: String] = [:]
        var bodyLines: [String] = []
        var inBody = false

        for line in lines.dropFirst() { // Skip From_ line
            if inBody {
                // Unescape From_ lines
                if line.hasPrefix(">From ") {
                    bodyLines.append(String(line.dropFirst()))
                } else {
                    bodyLines.append(line)
                }
            } else if line.isEmpty {
                inBody = true
            } else if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        guard let fromHeader = headers["From"] else { return nil }

        let from = parseEmailAddress(fromHeader)
        let to = (headers["To"] ?? "").components(separatedBy: ",").map { parseEmailAddress($0.trimmingCharacters(in: .whitespaces)) }
        let subject = headers["Subject"] ?? ""
        let messageId = headers["Message-ID"] ?? "<\(UUID().uuidString)@parsed>"
        let inReplyTo = headers["In-Reply-To"]
        let references = (headers["References"] ?? "").components(separatedBy: " ").filter { !$0.isEmpty }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let date = headers["Date"].flatMap { dateFormatter.date(from: $0) } ?? Date()

        let role = ConversationRole(rawValue: headers["X-Impart-Role"] ?? "human") ?? .human
        let model = headers["X-Impart-Model"]
        let artifactURI = headers["X-Impart-Artifact-URI"]
        let artifactType = headers["X-Impart-Artifact-Type"]

        return MboxMessage(
            id: UUID(),
            messageId: messageId,
            inReplyTo: inReplyTo,
            references: references,
            from: from,
            to: to,
            subject: subject,
            date: date,
            body: bodyLines.joined(separator: "\n"),
            role: role,
            model: model,
            artifactURI: artifactURI,
            artifactType: artifactType
        )
    }

    /// Parse an email address from RFC 5322 format.
    private func parseEmailAddress(_ string: String) -> EmailAddress {
        // Handle "Name <email>" format
        if let start = string.firstIndex(of: "<"), let end = string.firstIndex(of: ">") {
            let email = String(string[string.index(after: start)..<end])
            let name = String(string[..<start]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return EmailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        return EmailAddress(email: string.trimmingCharacters(in: .whitespaces))
    }

    /// Create a new conversation.
    public func createConversation(title: String) throws -> MboxConversation {
        try ensureDirectory()

        let id = UUID()
        let filename = "\(id.uuidString).mbox"
        let filePath = baseDirectory.appendingPathComponent(filename)

        let conversation = MboxConversation(id: id, title: title, filePath: filePath)
        conversations[id] = conversation

        mboxLogger.info("Created conversation: \(title) at \(filePath.path)")
        return conversation
    }

    /// Get a conversation by ID.
    public func getConversation(id: UUID) -> MboxConversation? {
        conversations[id]
    }

    /// Add a message to a conversation.
    public func addMessage(_ message: MboxMessage, to conversationId: UUID) throws {
        guard var conversation = conversations[conversationId] else {
            throw MboxError.conversationNotFound
        }

        // Append to mbox file
        let mboxString = message.toMboxString(conversationId: conversationId, conversationTitle: conversation.title)

        if FileManager.default.fileExists(atPath: conversation.filePath.path) {
            let handle = try FileHandle(forWritingTo: conversation.filePath)
            handle.seekToEndOfFile()
            handle.write(mboxString.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try mboxString.write(to: conversation.filePath, atomically: true, encoding: .utf8)
        }

        // Update in-memory state
        conversation.messages.append(message)
        conversation.lastActivityAt = message.date
        conversations[conversationId] = conversation

        mboxLogger.debug("Added message to conversation \(conversationId)")
    }

    /// Delete a conversation.
    public func deleteConversation(id: UUID) throws {
        guard let conversation = conversations[id] else {
            throw MboxError.conversationNotFound
        }

        try FileManager.default.removeItem(at: conversation.filePath)
        conversations.removeValue(forKey: id)

        mboxLogger.info("Deleted conversation: \(id)")
    }
}

// MARK: - Errors

public enum MboxError: LocalizedError {
    case conversationNotFound
    case parseError(String)
    case writeError(String)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            return "Conversation not found"
        case .parseError(let reason):
            return "Failed to parse mbox: \(reason)"
        case .writeError(let reason):
            return "Failed to write mbox: \(reason)"
        }
    }
}

// MARK: - EmailAddress Extension

extension EmailAddress {
    /// Format as RFC 5322 address.
    var rfc5322: String {
        if let name = name, !name.isEmpty {
            return "\(name) <\(email)>"
        }
        return email
    }
}
