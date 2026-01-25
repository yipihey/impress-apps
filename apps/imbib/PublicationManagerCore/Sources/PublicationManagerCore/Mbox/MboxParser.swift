//
//  MboxParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation
import OSLog

// MARK: - Mbox Parser

/// Parses mbox files into individual messages.
/// Supports streaming for large files.
public actor MboxParser {

    private let logger = Logger(subsystem: "PublicationManagerCore", category: "MboxParser")

    public init() {}

    // MARK: - Public API

    /// Parse an mbox file into messages.
    /// - Parameter url: URL of the mbox file
    /// - Returns: Array of parsed messages
    public func parse(url: URL) async throws -> [MboxMessage] {
        logger.info("Parsing mbox file: \(url.path)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MboxParseError.fileNotFound(url.path)
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseContent(content)
    }

    /// Parse mbox content string into messages.
    /// - Parameter content: Raw mbox file content
    /// - Returns: Array of parsed messages
    public func parseContent(_ content: String) throws -> [MboxMessage] {
        var messages: [MboxMessage] = []

        // Normalize line endings
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")

        // Split by "From " at start of line (mbox format)
        // Pattern: newline followed by "From " (or start of file)
        let pattern = "(?:^|\\n)(?=>?From )"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            throw MboxParseError.invalidFormat("Failed to create regex")
        }

        let range = NSRange(normalized.startIndex..., in: normalized)
        var lastEnd = normalized.startIndex

        let matches = regex.matches(in: normalized, options: [], range: range)

        // If no matches, check if file starts with "From "
        if matches.isEmpty {
            if normalized.hasPrefix("From ") || normalized.hasPrefix(">From ") {
                if let message = try? parseMessage(String(normalized)) {
                    messages.append(message)
                }
            }
            return messages
        }

        // Process each match
        for (index, match) in matches.enumerated() {
            guard let matchRange = Range(match.range, in: normalized) else { continue }

            // Get the message from lastEnd to this match
            if lastEnd < matchRange.lowerBound {
                let messageContent = String(normalized[lastEnd..<matchRange.lowerBound])
                if !messageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let message = try? parseMessage(messageContent) {
                        messages.append(message)
                    }
                }
            }

            // Find the end of this message (next match or end of file)
            let messageStart = matchRange.upperBound
            let messageEnd: String.Index
            if index + 1 < matches.count {
                if let nextRange = Range(matches[index + 1].range, in: normalized) {
                    messageEnd = nextRange.lowerBound
                } else {
                    messageEnd = normalized.endIndex
                }
            } else {
                messageEnd = normalized.endIndex
            }

            let messageContent = String(normalized[messageStart..<messageEnd])
            if !messageContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let message = try? parseMessage(messageContent) {
                    messages.append(message)
                }
            }

            lastEnd = messageEnd
        }

        // Handle content after last match if needed
        if lastEnd < normalized.endIndex {
            let remaining = String(normalized[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let message = try? parseMessage(remaining) {
                    messages.append(message)
                }
            }
        }

        logger.info("Parsed \(messages.count) messages from mbox")
        return messages
    }

    /// Parse a streaming mbox file for large files.
    /// - Parameter url: URL of the mbox file
    /// - Returns: AsyncStream of parsed messages
    public func parseStreaming(url: URL) -> AsyncStream<MboxMessage> {
        AsyncStream { continuation in
            Task {
                do {
                    let messages = try await parse(url: url)
                    for message in messages {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    logger.error("Streaming parse error: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Message Parsing

    /// Parse a single message from content.
    private func parseMessage(_ content: String) throws -> MboxMessage {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        // Handle "From " line if present
        var fromLineDate: Date?
        if let firstLine = lines.first, firstLine.hasPrefix("From ") {
            fromLineDate = parseFromLineDate(String(firstLine))
            lines.removeFirst()
        }

        // Parse headers
        var headers: [String: String] = [:]
        var headerEndIndex = 0
        var currentHeaderName: String?
        var currentHeaderValue: String = ""

        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                headerEndIndex = index + 1
                break
            }

            let lineStr = String(line)

            // Check for header continuation (starts with whitespace)
            if lineStr.hasPrefix(" ") || lineStr.hasPrefix("\t") {
                currentHeaderValue += " " + lineStr.trimmingCharacters(in: .whitespaces)
            } else if let colonIndex = lineStr.firstIndex(of: ":") {
                // Save previous header
                if let name = currentHeaderName {
                    headers[name] = currentHeaderValue
                }

                // Parse new header
                currentHeaderName = String(lineStr[..<colonIndex])
                currentHeaderValue = String(lineStr[lineStr.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Save last header
        if let name = currentHeaderName {
            headers[name] = currentHeaderValue
        }

        // Extract standard headers
        let from = headers["From"] ?? "unknown@imbib.local"
        let subject = MIMEDecoder.decodeHeaderValue(headers["Subject"] ?? "")
        let messageID = extractMessageID(headers["Message-ID"])
        let date = parseRFC2822Date(headers["Date"]) ?? fromLineDate ?? Date()

        // Parse body content
        let bodyLines = Array(lines[headerEndIndex...])
        let bodyContent = bodyLines.joined(separator: "\n")

        // Check for multipart content
        let contentType = headers["Content-Type"] ?? "text/plain"
        var body = ""
        var attachments: [MboxAttachment] = []

        if contentType.lowercased().contains("multipart/") {
            if let boundary = MIMEDecoder.extractBoundary(from: contentType) {
                let parts = MIMEDecoder.decode(bodyContent, boundary: boundary)

                for part in parts {
                    if part.contentType.lowercased().hasPrefix("text/plain") && part.filename == nil {
                        // This is the body
                        if let text = part.contentString {
                            body = MIMEDecoder.unescapeFromLines(text)
                        }
                    } else if let filename = part.filename {
                        // This is an attachment
                        attachments.append(MboxAttachment(
                            filename: filename,
                            contentType: part.contentType,
                            data: part.content,
                            customHeaders: extractCustomHeaders(part.headers)
                        ))
                    }
                }
            }
        } else {
            // Single-part message
            let transferEncoding = headers["Content-Transfer-Encoding"]?.lowercased()
            if transferEncoding == "quoted-printable" {
                body = MIMEDecoder.quotedPrintableDecode(bodyContent)
            } else if transferEncoding == "base64" {
                if let data = MIMEDecoder.base64Decode(bodyContent),
                   let text = String(data: data, encoding: .utf8) {
                    body = text
                }
            } else {
                body = bodyContent
            }
            body = MIMEDecoder.unescapeFromLines(body)
        }

        // Extract custom imbib headers
        var customHeaders: [String: String] = [:]
        for (key, value) in headers {
            if key.hasPrefix("X-Imbib-") {
                customHeaders[key] = value
            }
        }

        return MboxMessage(
            from: MIMEDecoder.decodeHeaderValue(from),
            subject: subject,
            date: date,
            messageID: messageID,
            headers: customHeaders,
            body: body,
            attachments: attachments
        )
    }

    // MARK: - Date Parsing

    /// Parse date from "From " envelope line.
    private func parseFromLineDate(_ line: String) -> Date? {
        // Format: "From sender@example.com Thu Jan 01 00:00:00 2024"
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3 else { return nil }

        let dateString = String(parts[2])
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        return formatter.date(from: dateString)
    }

    /// Parse RFC 2822 date.
    private func parseRFC2822Date(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }

        let formatters: [DateFormatter] = [
            {
                let f = DateFormatter()
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }(),
            {
                let f = DateFormatter()
                f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }(),
            {
                let f = DateFormatter()
                f.dateFormat = "dd MMM yyyy HH:mm:ss Z"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }(),
        ]

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }

    // MARK: - Header Parsing Helpers

    /// Extract Message-ID without angle brackets.
    private func extractMessageID(_ headerValue: String?) -> String {
        guard let value = headerValue else { return UUID().uuidString }

        var id = value.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }

        // Remove @domain part if present
        if let atIndex = id.firstIndex(of: "@") {
            return String(id[..<atIndex])
        }

        return id
    }

    /// Extract X-Imbib-* headers from a part's headers.
    private func extractCustomHeaders(_ headers: [String: String]) -> [String: String] {
        var custom: [String: String] = [:]
        for (key, value) in headers {
            if key.hasPrefix("X-Imbib-") {
                custom[key] = value
            }
        }
        return custom
    }
}

// MARK: - Parse Errors

/// Errors that can occur during mbox parsing.
public enum MboxParseError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidFormat(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidFormat(let reason):
            return "Invalid mbox format: \(reason)"
        case .decodingError(let reason):
            return "Decoding error: \(reason)"
        }
    }
}
