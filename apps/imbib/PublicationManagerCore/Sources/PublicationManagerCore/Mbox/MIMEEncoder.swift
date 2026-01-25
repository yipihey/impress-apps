//
//  MIMEEncoder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation

// MARK: - MIME Encoder

/// Encodes mbox messages to RFC 5322 compliant format with MIME multipart support.
public struct MIMEEncoder: Sendable {

    // MARK: - Public API

    /// Encode an mbox message to RFC 5322 format with MIME attachments.
    /// - Parameter message: The message to encode
    /// - Returns: Encoded message string ready for mbox file
    public static func encode(_ message: MboxMessage) -> String {
        var lines: [String] = []

        // Build headers
        lines.append(buildFromLine(message))
        lines.append("From: \(encodeHeaderValue(message.from))")
        lines.append("Subject: \(encodeHeaderValue(message.subject))")
        lines.append("Date: \(formatRFC2822Date(message.date))")
        lines.append("Message-ID: <\(message.messageID)@imbib.local>")
        lines.append("MIME-Version: 1.0")

        // Add custom headers
        for (key, value) in message.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(encodeHeaderValue(value))")
        }

        // Determine content type based on attachments
        if message.attachments.isEmpty {
            // Simple plain text message
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(escapeFromLines(quotedPrintableEncode(message.body)))
        } else {
            // Multipart message with attachments
            let boundary = generateBoundary()
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("This is a multi-part message in MIME format.")
            lines.append("")

            // Add body part
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: quoted-printable")
            lines.append("")
            lines.append(escapeFromLines(quotedPrintableEncode(message.body)))
            lines.append("")

            // Add attachment parts
            for attachment in message.attachments {
                lines.append("--\(boundary)")
                lines.append(encodeAttachment(attachment))
                lines.append("")
            }

            // Close multipart
            lines.append("--\(boundary)--")
        }

        return lines.joined(separator: "\n")
    }

    /// Encode a single attachment to MIME part format.
    /// - Parameter attachment: The attachment to encode
    /// - Returns: Encoded attachment string
    public static func encodeAttachment(_ attachment: MboxAttachment) -> String {
        var lines: [String] = []

        // Content-Type with filename
        let safeFilename = encodeHeaderValue(attachment.filename)
        lines.append("Content-Type: \(attachment.contentType); name=\"\(safeFilename)\"")

        // Transfer encoding
        if isBinaryContentType(attachment.contentType) {
            lines.append("Content-Transfer-Encoding: base64")
        } else {
            lines.append("Content-Transfer-Encoding: quoted-printable")
        }

        // Content-Disposition
        lines.append("Content-Disposition: attachment; filename=\"\(safeFilename)\"")

        // Custom headers (X-Imbib-LinkedFile-*)
        for (key, value) in attachment.customHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(encodeHeaderValue(value))")
        }

        lines.append("")

        // Encode content
        if isBinaryContentType(attachment.contentType) {
            lines.append(base64Encode(attachment.data))
        } else if let text = String(data: attachment.data, encoding: .utf8) {
            lines.append(quotedPrintableEncode(text))
        } else {
            // Fall back to base64 for non-UTF8 text
            lines.append(base64Encode(attachment.data))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Header Encoding

    /// Build the mbox "From " envelope line.
    private static func buildFromLine(_ message: MboxMessage) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        return "From imbib@imbib.local \(dateFormatter.string(from: message.date))"
    }

    /// Format date according to RFC 2822.
    private static func formatRFC2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Encode header value with RFC 2047 encoding if needed (for non-ASCII).
    public static func encodeHeaderValue(_ value: String) -> String {
        // Check if encoding is needed
        let needsEncoding = value.contains { char in
            guard let scalar = char.unicodeScalars.first else { return false }
            return scalar.value > 127 || char == "\r" || char == "\n"
        }

        if needsEncoding {
            // Use RFC 2047 encoded-word format: =?charset?encoding?encoded_text?=
            guard let data = value.data(using: .utf8) else { return value }
            let base64 = data.base64EncodedString()

            // Split long encoded words (max 75 chars per line)
            var encoded = ""
            var remaining = base64
            while !remaining.isEmpty {
                let chunk = String(remaining.prefix(45)) // Leave room for =?UTF-8?B?...?=
                remaining = String(remaining.dropFirst(45))
                if !encoded.isEmpty {
                    encoded += "\n "
                }
                encoded += "=?UTF-8?B?\(chunk)?="
            }
            return encoded
        }

        return value
    }

    // MARK: - Content Encoding

    /// Base64 encode binary data with line wrapping at 76 characters.
    public static func base64Encode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()

        // Wrap at 76 characters per line (RFC 2045)
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }

        return lines.joined(separator: "\n")
    }

    /// Quoted-printable encode text (RFC 2045).
    public static func quotedPrintableEncode(_ text: String) -> String {
        var result = ""
        var lineLength = 0

        for char in text {
            if char == "\r" {
                continue // Skip CR, we'll use LF only
            }

            if char == "\n" {
                result += "\r\n"
                lineLength = 0
                continue
            }

            let encoded: String
            if let scalar = char.unicodeScalars.first {
                let value = scalar.value
                // Printable ASCII except = and control characters
                if value >= 33 && value <= 126 && value != 61 {
                    encoded = String(char)
                } else if char == " " || char == "\t" {
                    // Space/tab at end of line needs encoding
                    encoded = String(char)
                } else {
                    // Encode as =XX
                    if let data = String(char).data(using: .utf8) {
                        encoded = data.map { String(format: "=%02X", $0) }.joined()
                    } else {
                        encoded = String(char)
                    }
                }
            } else {
                encoded = String(char)
            }

            // Soft line break if line too long (max 76 chars)
            if lineLength + encoded.count > 75 {
                result += "=\r\n"
                lineLength = 0
            }

            result += encoded
            lineLength += encoded.count
        }

        return result
    }

    // MARK: - mboxrd Escaping

    /// Escape "From " at the start of lines (mboxrd format).
    /// Adds ">" prefix to lines starting with "From " or ">" followed by "From ".
    public static func escapeFromLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String] = []

        for line in lines {
            // mboxrd: escape "From " and ">From ", ">>From ", etc.
            if line.hasPrefix("From ") || line.hasPrefix(">") && line.dropFirst().hasPrefix("From ") {
                result.append(">" + line)
            } else {
                var escapedLine = String(line)
                // Also check for lines that are just multiple ">" followed by "From "
                var gtCount = 0
                var idx = line.startIndex
                while idx < line.endIndex && line[idx] == ">" {
                    gtCount += 1
                    idx = line.index(after: idx)
                }
                if gtCount > 0 && line[idx...].hasPrefix("From ") {
                    escapedLine = ">" + line
                }
                result.append(escapedLine)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Generate a unique MIME boundary string.
    public static func generateBoundary() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "----=_Part_\(uuid)"
    }

    /// Check if content type is binary (needs base64).
    private static func isBinaryContentType(_ contentType: String) -> Bool {
        let textTypes = ["text/", "application/json", "application/xml"]
        let lowered = contentType.lowercased()
        return !textTypes.contains { lowered.hasPrefix($0) }
    }
}
