//
//  MailMessage.swift
//  ImpelMail
//
//  Email message model and parser for the counsel@ gateway.
//

import Foundation

/// A parsed email message.
public struct MailMessage: Identifiable, Sendable {
    public let id: String
    public let from: String
    public let to: [String]
    public let subject: String
    public let body: String
    public let date: Date
    public let messageID: String
    public let inReplyTo: String?
    public let references: [String]
    public let headers: [String: String]

    /// IMAP flags
    public var flags: Set<IMAPFlag>

    /// Internal sequence number for IMAP
    public var sequenceNumber: Int

    public init(
        id: String = UUID().uuidString,
        from: String,
        to: [String],
        subject: String,
        body: String,
        date: Date = Date(),
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        headers: [String: String] = [:],
        flags: Set<IMAPFlag> = [],
        sequenceNumber: Int = 0
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.date = date
        self.messageID = messageID ?? "<\(id)@impress.local>"
        self.inReplyTo = inReplyTo
        self.references = references
        self.headers = headers
        self.flags = flags
        self.sequenceNumber = sequenceNumber
    }

    /// Format as RFC 2822 email for IMAP delivery.
    public func toRFC2822() -> String {
        var lines: [String] = []
        lines.append("From: \(from)")
        lines.append("To: \(to.joined(separator: ", "))")
        lines.append("Subject: \(subject)")
        lines.append("Date: \(Self.rfc2822DateFormatter.string(from: date))")
        lines.append("Message-ID: \(messageID)")
        if let inReplyTo = inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if !references.isEmpty {
            lines.append("References: \(references.joined(separator: " "))")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        // Emit custom headers
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            // Skip standard headers already emitted above
            let lower = key.lowercased()
            if ["from", "to", "subject", "date", "message-id", "in-reply-to",
                "references", "mime-version", "content-type", "content-transfer-encoding"].contains(lower) {
                continue
            }
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    /// Size of the RFC 2822 representation in bytes.
    public var rfc2822Size: Int {
        toRFC2822().utf8.count
    }

    private static let rfc2822DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// IMAP message flags.
public enum IMAPFlag: String, Sendable, Hashable {
    case seen = "\\Seen"
    case answered = "\\Answered"
    case flagged = "\\Flagged"
    case deleted = "\\Deleted"
    case draft = "\\Draft"
    case recent = "\\Recent"
}

// MARK: - Email Parser

/// Parses raw SMTP DATA into a MailMessage.
public enum EmailParser {

    /// Parse raw email data received via SMTP DATA command.
    public static func parse(rawData: String, from: String, to: [String]) -> MailMessage {
        let (headers, rawBody) = splitHeadersAndBody(rawData)

        // Decode body based on Content-Transfer-Encoding
        let encoding = headers["content-transfer-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "7bit"
        let body: String
        switch encoding {
        case "quoted-printable":
            body = decodeQuotedPrintable(rawBody)
        case "base64":
            body = decodeBase64(rawBody)
        default:
            body = rawBody
        }

        // Decode subject if it uses RFC 2047 encoded-words (=?UTF-8?Q?...?= or =?UTF-8?B?...?=)
        let subject = decodeRFC2047(headers["subject"] ?? "(no subject)")
        let messageID = headers["message-id"] ?? "<\(UUID().uuidString)@impress.local>"
        let inReplyTo = headers["in-reply-to"]
        let references = headers["references"]?.components(separatedBy: " ").filter { !$0.isEmpty } ?? []

        let date: Date
        if let dateStr = headers["date"] {
            date = parseDate(dateStr) ?? Date()
        } else {
            date = Date()
        }

        // Use header From if available, fall back to envelope From
        let headerFrom = headers["from"] ?? from

        return MailMessage(
            from: headerFrom,
            to: to,
            subject: subject,
            body: body,
            date: date,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            headers: headers,
            flags: [.recent]
        )
    }

    private static func splitHeadersAndBody(_ raw: String) -> ([String: String], String) {
        var headers: [String: String] = [:]
        var body = ""

        // Headers and body are separated by an empty line
        let parts = raw.components(separatedBy: "\r\n\r\n")
        if parts.count < 2 {
            // Try Unix-style line endings
            let unixParts = raw.components(separatedBy: "\n\n")
            if unixParts.count >= 2 {
                headers = parseHeaders(unixParts[0], separator: "\n")
                body = unixParts.dropFirst().joined(separator: "\n\n")
            } else {
                body = raw
            }
        } else {
            headers = parseHeaders(parts[0], separator: "\r\n")
            body = parts.dropFirst().joined(separator: "\r\n\r\n")
        }

        return (headers, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseHeaders(_ headerBlock: String, separator: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue: String?

        for line in headerBlock.components(separatedBy: separator) {
            if line.isEmpty { break }

            // Continuation line (starts with whitespace)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let key = currentKey {
                currentValue = (currentValue ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
                headers[key] = currentValue
                continue
            }

            // New header
            let colonIndex = line.firstIndex(of: ":")
            if let idx = colonIndex {
                let key = String(line[line.startIndex..<idx]).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
                currentValue = value
            }
        }

        return headers
    }

    // MARK: - Content-Transfer-Encoding Decoders

    /// Decode a quoted-printable encoded string (RFC 2045 §6.7).
    private static func decodeQuotedPrintable(_ input: String) -> String {
        var result = Data()
        let lines = input.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            // Strip trailing \r
            if line.hasSuffix("\r") { line = String(line.dropLast()) }

            // Soft line break: line ends with "=" → continuation, don't add newline
            let isSoftBreak = line.hasSuffix("=")
            if isSoftBreak {
                line = String(line.dropLast())
            }

            // Decode =XX hex sequences
            var i = line.startIndex
            while i < line.endIndex {
                if line[i] == "=", line.distance(from: i, to: line.endIndex) >= 3 {
                    let hexStart = line.index(after: i)
                    let hexEnd = line.index(hexStart, offsetBy: 2)
                    let hex = String(line[hexStart..<hexEnd])
                    if let byte = UInt8(hex, radix: 16) {
                        result.append(byte)
                        i = hexEnd
                        continue
                    }
                }
                // Regular character
                if let scalar = line[i].asciiValue {
                    result.append(scalar)
                } else {
                    // Non-ASCII: encode as UTF-8
                    result.append(contentsOf: String(line[i]).utf8)
                }
                i = line.index(after: i)
            }

            // Add newline unless this was a soft break or the last line
            if !isSoftBreak && index < lines.count - 1 {
                result.append(contentsOf: "\n".utf8)
            }
        }

        return String(data: result, encoding: .utf8)
            ?? String(data: result, encoding: .ascii)
            ?? input
    }

    /// Decode a base64-encoded body.
    private static func decodeBase64(_ input: String) -> String {
        let cleaned = input.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned) else { return input }
        return String(data: data, encoding: .utf8) ?? input
    }

    /// Decode RFC 2047 encoded-words in header values.
    /// Handles =?charset?Q?...?= (quoted-printable) and =?charset?B?...?= (base64).
    private static func decodeRFC2047(_ input: String) -> String {
        let pattern = "=\\?([^?]+)\\?([QqBb])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

        var result = input
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Process matches in reverse to preserve indices
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let payloadRange = Range(match.range(at: 3), in: result) else { continue }

            let encoding = String(result[encodingRange]).uppercased()
            let payload = String(result[payloadRange])

            let decoded: String?
            if encoding == "Q" {
                // QP in headers: underscores represent spaces
                let withSpaces = payload.replacingOccurrences(of: "_", with: " ")
                decoded = decodeQuotedPrintable(withSpaces)
            } else {
                decoded = decodeBase64(payload)
            }

            if let decoded = decoded {
                result.replaceSubrange(fullRange, with: decoded)
            }
        }

        return result
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Try common RFC 2822 formats
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return nil
    }
}
