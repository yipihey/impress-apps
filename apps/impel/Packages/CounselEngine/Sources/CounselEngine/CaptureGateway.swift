//
//  CaptureGateway.swift
//  CounselEngine
//
//  Deterministic email-to-artifact capture pipeline.
//  Registers for capture@ prefix on the MessageStore and converts
//  incoming emails into research artifacts in imbib.
//

import Foundation
import ImpelMail
import ImpressKit
import OSLog

/// Deterministic email-to-artifact capture pipeline.
///
/// Registers for the `capture@` address prefix on the MessageStore.
/// When an email arrives addressed to `capture@impress.local`, the gateway:
/// 1. Parses the subject for artifact type prefix (e.g., `[note]`, `[dataset]`)
/// 2. Extracts sender as original author
/// 3. Creates the main artifact via SiblingBridge → imbib HTTP API
/// 4. Processes attachments: writes to SharedContainer, creates file artifacts
/// 5. Sends an IMAP confirmation reply
///
/// No AI agent is involved — this is a pure deterministic pipeline.
public actor CaptureGateway {

    private let logger = Logger(subsystem: "com.impress.impel", category: "capture")

    private let store: MessageStore
    private let configuration: CaptureConfiguration

    /// In-memory deduplication set (Message-IDs we've already processed).
    private var processedMessageIDs: Set<String> = []

    /// Maximum deduplication set size before eviction.
    private let maxDeduplicationEntries = 10_000

    public init(store: MessageStore, configuration: CaptureConfiguration = .default) {
        self.store = store
        self.configuration = configuration
    }

    /// Register the capture@ handler on the message store.
    public func start() async {
        await store.addIncomingHandler(forPrefix: "capture") { [weak self] message in
            guard let self else { return }
            await self.handleIncoming(message)
        }
        logger.info("Capture gateway started — capture@impress.local ready")
    }

    // MARK: - Message Handling

    private func handleIncoming(_ message: MailMessage) async {
        // Deduplicate by Message-ID
        guard !processedMessageIDs.contains(message.messageID) else {
            logger.info("Skipping duplicate message: \(message.messageID)")
            return
        }
        trackMessageID(message.messageID)

        logger.info("Capture request from \(message.from): \(message.subject)")

        // Parse subject for artifact type and clean title
        let (artifactType, cleanTitle) = parseSubject(message.subject)

        // Extract sender display name as original author
        let originalAuthor = extractDisplayName(from: message.from)

        // Build notes from message body
        let body = message.mimeParts?.bestTextBody ?? message.body
        let notes = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // Create the main email artifact
        let mainArtifactID = await createArtifact(
            type: artifactType,
            title: cleanTitle,
            notes: notes.isEmpty ? nil : notes,
            originalAuthor: originalAuthor,
            captureContext: "email-capture",
            tags: configuration.defaultTags
        )

        // Process attachments
        var attachmentCount = 0
        if let mimeParts = message.mimeParts {
            for attachment in mimeParts.attachments {
                guard attachment.body.count <= configuration.maxAttachmentSize else {
                    logger.warning("Skipping oversized attachment: \(attachment.filename ?? "unknown") (\(attachment.body.count) bytes)")
                    continue
                }

                let filename = attachment.filename ?? "attachment-\(UUID().uuidString.prefix(8))"
                let attachmentType = artifactTypeForMIME(attachment.mediaType)

                // Write file to SharedContainer for imbib to pick up
                let sharedFilename = "\(UUID().uuidString)-\(filename)"
                do {
                    try SharedContainer.writeArtifact(filename: sharedFilename, data: attachment.body)
                } catch {
                    logger.error("Failed to write attachment to SharedContainer: \(error.localizedDescription)")
                    continue
                }

                // Create artifact for this attachment
                _ = await createArtifact(
                    type: attachmentType,
                    title: filename,
                    notes: "Attachment from: \(cleanTitle)",
                    originalAuthor: originalAuthor,
                    captureContext: "email-attachment",
                    tags: configuration.defaultTags,
                    fileName: filename,
                    fileMimeType: attachment.mediaType,
                    sharedFileName: sharedFilename
                )
                attachmentCount += 1
            }
        }

        // Send confirmation reply via IMAP
        let confirmationBody = buildConfirmation(
            title: cleanTitle,
            type: artifactType,
            attachmentCount: attachmentCount,
            artifactID: mainArtifactID
        )
        let reply = MailMessage(
            from: "capture@impress.local",
            to: [message.from],
            subject: "Re: \(message.subject)",
            body: confirmationBody,
            inReplyTo: message.messageID,
            references: message.references + [message.messageID],
            headers: [
                "List-Id": "<capture.impress.local>",
                "X-Mailer": "capture/impress",
                "X-Capture-Type": artifactType,
            ]
        )
        await store.storeReply(reply)

        logger.info("Captured '\(cleanTitle)' as \(artifactType) with \(attachmentCount) attachment(s)")
    }

    // MARK: - Artifact Creation via SiblingBridge

    /// Create an artifact by POSTing to imbib's HTTP API.
    /// Returns the artifact ID on success, nil on failure.
    @discardableResult
    private func createArtifact(
        type: String,
        title: String,
        notes: String?,
        originalAuthor: String?,
        captureContext: String?,
        tags: [String],
        fileName: String? = nil,
        fileMimeType: String? = nil,
        sharedFileName: String? = nil
    ) async -> String? {
        var body: [String: Any] = [
            "type": type,
            "title": title,
            "tags": tags,
        ]
        if let notes { body["notes"] = notes }
        if let originalAuthor { body["originalAuthor"] = originalAuthor }
        if let captureContext { body["captureContext"] = captureContext }
        if let fileName { body["fileName"] = fileName }
        if let fileMimeType { body["fileMimeType"] = fileMimeType }
        if let sharedFileName { body["sharedFileName"] = sharedFileName }

        do {
            let data = try await SiblingBridge.shared.postRaw(
                "/api/artifacts",
                to: .imbib,
                body: body
            )

            // Parse response to get artifact ID
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let artifact = json["artifact"] as? [String: Any],
               let id = artifact["id"] as? String {
                return id
            }
            return nil
        } catch {
            logger.error("Failed to create artifact via imbib API: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Subject Parsing

    /// Subject prefix mapping to artifact types.
    private static let subjectPrefixes: [(prefixes: [String], type: String)] = [
        (["[note]"], "impress/artifact/note"),
        (["[webpage]", "[web]"], "impress/artifact/webpage"),
        (["[dataset]", "[data]"], "impress/artifact/dataset"),
        (["[slides]", "[presentation]"], "impress/artifact/presentation"),
        (["[poster]"], "impress/artifact/poster"),
        (["[media]"], "impress/artifact/media"),
        (["[code]"], "impress/artifact/code"),
    ]

    /// Parse the subject line for artifact type prefix and clean title.
    ///
    /// - Returns: Tuple of (artifactTypeRawValue, cleanedTitle)
    func parseSubject(_ subject: String) -> (String, String) {
        var title = subject

        // Strip common forwarding prefixes
        let fwdPrefixes = ["fwd:", "fw:", "fwd :", "fw :"]
        for prefix in fwdPrefixes {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Check for artifact type prefix
        let lowerTitle = title.lowercased()
        for entry in Self.subjectPrefixes {
            for prefix in entry.prefixes {
                if lowerTitle.hasPrefix(prefix) {
                    let stripped = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    return (entry.type, stripped.isEmpty ? title : stripped)
                }
            }
        }

        // No prefix — default to general
        return ("impress/artifact/general", title.isEmpty ? "(no subject)" : title)
    }

    // MARK: - Helpers

    /// Extract display name from an email From header.
    /// Handles formats like "John Doe <john@example.com>" and "john@example.com".
    private func extractDisplayName(from address: String) -> String {
        // "Display Name <email>" format
        if let angleBracket = address.firstIndex(of: "<") {
            let name = String(address[..<angleBracket]).trimmingCharacters(in: .whitespaces)
            // Strip quotes
            let unquoted = name.trimmingCharacters(in: .init(charactersIn: "\""))
            if !unquoted.isEmpty { return unquoted }
        }
        // Bare email — use local part
        return address.components(separatedBy: "@").first ?? address
    }

    /// Map MIME type to artifact type for file attachments.
    private func artifactTypeForMIME(_ mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") || lower.hasPrefix("video/") || lower.hasPrefix("audio/") {
            return "impress/artifact/media"
        }
        if lower == "application/pdf" || lower.hasPrefix("text/") {
            return "impress/artifact/general"
        }
        if lower.contains("spreadsheet") || lower.contains("csv") {
            return "impress/artifact/dataset"
        }
        if lower.contains("presentation") || lower.contains("powerpoint") || lower.contains("keynote") {
            return "impress/artifact/presentation"
        }
        return "impress/artifact/general"
    }

    /// Build a human-readable confirmation message.
    private func buildConfirmation(title: String, type: String, attachmentCount: Int, artifactID: String?) -> String {
        let typeName = type.components(separatedBy: "/").last ?? type
        var body = """
        Captured as \(typeName): "\(title)"
        """

        if attachmentCount > 0 {
            body += "\n\(attachmentCount) attachment(s) saved as separate artifacts."
        }

        if let id = artifactID {
            body += "\n\nView in imbib: imbib://open/artifact/\(id)"
        }

        body += "\n\n--- capture@impress.local"
        return body
    }

    /// Track a message ID for deduplication, evicting old entries if needed.
    private func trackMessageID(_ messageID: String) {
        if processedMessageIDs.count >= maxDeduplicationEntries {
            // Evict roughly half (FIFO approximation — Set has no ordering, but this
            // prevents unbounded growth)
            let removeCount = processedMessageIDs.count / 2
            for id in processedMessageIDs.prefix(removeCount) {
                processedMessageIDs.remove(id)
            }
        }
        processedMessageIDs.insert(messageID)
    }
}
