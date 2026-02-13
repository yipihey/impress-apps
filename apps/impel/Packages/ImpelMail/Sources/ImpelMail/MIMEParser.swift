//
//  MIMEParser.swift
//  ImpelMail
//
//  Multipart MIME parser for extracting email bodies and attachments.
//

import Foundation

/// A single MIME part extracted from a multipart message.
public struct MIMEPart: Sendable {
    /// Raw headers for this part (lowercase keys).
    public let headers: [String: String]

    /// Full Content-Type header value (e.g., "text/plain; charset=utf-8").
    public let contentType: String

    /// Media type only (e.g., "text/plain").
    public let mediaType: String

    /// Character set from Content-Type, if present.
    public let charset: String?

    /// Filename from Content-Disposition or Content-Type name parameter.
    public let filename: String?

    /// Content-Transfer-Encoding value.
    public let transferEncoding: String

    /// Decoded body data.
    public let body: Data

    /// Whether this part is an attachment (has Content-Disposition: attachment, or a filename).
    public let isAttachment: Bool

    /// Whether this part is inline (Content-Disposition: inline with a filename).
    public let isInline: Bool
}

/// Result of parsing a complete MIME message.
public struct ParsedMIMEMessage: Sendable {
    /// Plain text body (from text/plain parts), or HTML stripped to text as fallback.
    public let textBody: String?

    /// HTML body (from text/html parts).
    public let htmlBody: String?

    /// File attachments (Content-Disposition: attachment or named non-text parts).
    public let attachments: [MIMEPart]

    /// Inline parts (Content-Disposition: inline with filenames, e.g., inline images).
    public let inlineParts: [MIMEPart]

    /// All parsed parts in order.
    public let allParts: [MIMEPart]

    /// Best available text body: prefers plain text, falls back to stripped HTML.
    public var bestTextBody: String? {
        if let text = textBody, !text.isEmpty { return text }
        if let html = htmlBody { return MIMEParser.stripHTML(html) }
        return nil
    }
}

/// Parses multipart MIME messages into structured parts.
public enum MIMEParser {

    /// Parse a MIME message from its headers and raw body.
    ///
    /// - Parameters:
    ///   - headers: Parsed headers (lowercase keys).
    ///   - body: Raw message body (after header/body split).
    /// - Returns: A parsed MIME message with extracted text, HTML, and attachments.
    public static func parse(headers: [String: String], body: String) -> ParsedMIMEMessage {
        let contentType = headers["content-type"] ?? "text/plain"

        // Check if this is a multipart message
        if contentType.lowercased().contains("multipart/") {
            guard let boundary = extractBoundary(from: contentType) else {
                // Malformed multipart — treat as single text part
                return singlePartMessage(body: body, contentType: contentType, headers: headers)
            }
            let parts = splitParts(body: body, boundary: boundary)
            let mimeParts = parts.compactMap { parsePart($0, parentHeaders: headers) }
            return buildMessage(from: mimeParts)
        } else {
            return singlePartMessage(body: body, contentType: contentType, headers: headers)
        }
    }

    // MARK: - Boundary Extraction

    /// Extract the boundary string from a Content-Type header.
    static func extractBoundary(from contentType: String) -> String? {
        // Match boundary="value" or boundary=value
        let lower = contentType.lowercased()
        guard let range = lower.range(of: "boundary=") else { return nil }

        let afterBoundary = contentType[range.upperBound...]
        if afterBoundary.hasPrefix("\"") {
            // Quoted boundary
            let unquoted = afterBoundary.dropFirst()
            if let endQuote = unquoted.firstIndex(of: "\"") {
                return String(unquoted[..<endQuote])
            }
            return String(unquoted)
        } else {
            // Unquoted boundary — ends at semicolon, whitespace, or end
            let boundary = afterBoundary.prefix(while: { $0 != ";" && !$0.isWhitespace })
            return boundary.isEmpty ? nil : String(boundary)
        }
    }

    // MARK: - Part Splitting

    /// Split the body into individual MIME parts using the boundary.
    static func splitParts(body: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        let terminator = "--\(boundary)--"

        var parts: [String] = []
        let lines = body.components(separatedBy: "\n")
        var currentPart: [String]?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r"))

            if trimmed == terminator || trimmed.hasPrefix(terminator) {
                // End of multipart — save current part if any
                if let part = currentPart {
                    parts.append(part.joined(separator: "\n"))
                }
                break
            }

            if trimmed == delimiter || trimmed.hasPrefix(delimiter) {
                // New boundary — save previous part and start new one
                if let part = currentPart {
                    parts.append(part.joined(separator: "\n"))
                }
                currentPart = []
                continue
            }

            // Accumulate lines into current part
            currentPart?.append(line)
        }

        return parts
    }

    // MARK: - Part Parsing

    /// Parse a single MIME part (may recurse for nested multipart).
    static func parsePart(_ rawPart: String, parentHeaders: [String: String]? = nil) -> MIMEPart? {
        let (headers, body) = splitPartHeadersAndBody(rawPart)

        let contentType = headers["content-type"] ?? "text/plain"
        let lowerCT = contentType.lowercased()

        // Recurse into nested multipart (e.g., multipart/alternative inside multipart/mixed)
        if lowerCT.contains("multipart/") {
            guard let boundary = extractBoundary(from: contentType) else { return nil }
            let subParts = splitParts(body: body, boundary: boundary)
            // For multipart/alternative, prefer text/plain over text/html
            let parsed = subParts.compactMap { parsePart($0) }

            if lowerCT.contains("multipart/alternative") {
                // Return text/plain if available, otherwise text/html
                return parsed.first(where: { $0.mediaType.lowercased() == "text/plain" })
                    ?? parsed.first(where: { $0.mediaType.lowercased() == "text/html" })
                    ?? parsed.first
            }
            // For other nested multipart, return first part (flatten)
            return parsed.first
        }

        let encoding = headers["content-transfer-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "7bit"
        let disposition = headers["content-disposition"]?.lowercased() ?? ""
        let mediaType = extractMediaType(from: contentType)
        let charset = extractParameter(named: "charset", from: contentType)
        let filename = extractFilename(from: headers)
        let decodedBody = decodeBody(body, encoding: encoding)

        let isAttachment = disposition.contains("attachment") || (filename != nil && !mediaType.hasPrefix("text/"))
        let isInline = disposition.contains("inline") && filename != nil

        return MIMEPart(
            headers: headers,
            contentType: contentType,
            mediaType: mediaType,
            charset: charset,
            filename: filename,
            transferEncoding: encoding,
            body: decodedBody,
            isAttachment: isAttachment,
            isInline: isInline
        )
    }

    // MARK: - Body Decoding

    /// Decode a MIME part body based on its Content-Transfer-Encoding.
    static func decodeBody(_ body: String, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: cleaned) ?? Data(body.utf8)
        case "quoted-printable":
            return decodeQuotedPrintableToData(body)
        default:
            // 7bit, 8bit, binary — pass through
            return Data(body.utf8)
        }
    }

    /// Decode quoted-printable content to Data.
    private static func decodeQuotedPrintableToData(_ input: String) -> Data {
        var result = Data()
        let lines = input.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            if line.hasSuffix("\r") { line = String(line.dropLast()) }

            let isSoftBreak = line.hasSuffix("=")
            if isSoftBreak { line = String(line.dropLast()) }

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
                result.append(contentsOf: String(line[i]).utf8)
                i = line.index(after: i)
            }

            if !isSoftBreak && index < lines.count - 1 {
                result.append(contentsOf: "\n".utf8)
            }
        }

        return result
    }

    // MARK: - HTML Stripping

    /// Strip HTML tags to extract plain text. Basic but sufficient for email bodies.
    public static func stripHTML(_ html: String) -> String {
        var text = html

        // Replace common block elements with newlines
        let blockTags = ["<br>", "<br/>", "<br />", "</p>", "</div>", "</tr>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Remove all remaining HTML tags
        while let tagStart = text.range(of: "<"),
              let tagEnd = text.range(of: ">", range: tagStart.upperBound..<text.endIndex) {
            text.replaceSubrange(tagStart.lowerBound...tagEnd.lowerBound, with: "")
        }

        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse excessive whitespace
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Remove runs of 3+ blank lines
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Split a MIME part's raw text into headers and body.
    private static func splitPartHeadersAndBody(_ raw: String) -> ([String: String], String) {
        // Headers and body separated by blank line
        let separators = ["\r\n\r\n", "\n\n"]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let headerBlock = String(raw[..<range.lowerBound])
                let body = String(raw[range.upperBound...])
                let lineSep = sep == "\r\n\r\n" ? "\r\n" : "\n"
                return (parsePartHeaders(headerBlock, separator: lineSep), body)
            }
        }
        // No blank line found — entire content is body
        return ([:], raw)
    }

    /// Parse part headers with continuation line support.
    private static func parsePartHeaders(_ block: String, separator: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue: String?

        for line in block.components(separatedBy: separator) {
            if line.isEmpty { break }

            // Continuation line
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let key = currentKey {
                currentValue = (currentValue ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
                headers[key] = currentValue
                continue
            }

            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx]).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
                currentValue = value
            }
        }
        return headers
    }

    /// Extract the media type from a Content-Type value (before semicolon).
    private static func extractMediaType(from contentType: String) -> String {
        let mediaType = contentType.components(separatedBy: ";").first ?? contentType
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Extract a named parameter from a header value (e.g., charset from Content-Type).
    private static func extractParameter(named name: String, from headerValue: String) -> String? {
        let lower = headerValue.lowercased()
        guard let range = lower.range(of: "\(name)=") else { return nil }
        let afterParam = headerValue[range.upperBound...]
        if afterParam.hasPrefix("\"") {
            let unquoted = afterParam.dropFirst()
            if let endQuote = unquoted.firstIndex(of: "\"") {
                return String(unquoted[..<endQuote])
            }
            return String(unquoted)
        }
        return String(afterParam.prefix(while: { $0 != ";" && !$0.isWhitespace }))
    }

    /// Extract filename from Content-Disposition or Content-Type name parameter.
    private static func extractFilename(from headers: [String: String]) -> String? {
        // Try Content-Disposition filename first
        if let disposition = headers["content-disposition"] {
            if let filename = extractParameter(named: "filename", from: disposition) {
                return filename
            }
        }
        // Fall back to Content-Type name parameter
        if let contentType = headers["content-type"] {
            if let name = extractParameter(named: "name", from: contentType) {
                return name
            }
        }
        return nil
    }

    /// Build a ParsedMIMEMessage from a flat list of parts.
    private static func buildMessage(from parts: [MIMEPart]) -> ParsedMIMEMessage {
        var textBody: String?
        var htmlBody: String?
        var attachments: [MIMEPart] = []
        var inlineParts: [MIMEPart] = []

        for part in parts {
            if part.isAttachment {
                attachments.append(part)
            } else if part.isInline {
                inlineParts.append(part)
            } else if part.mediaType == "text/plain" && textBody == nil {
                textBody = String(data: part.body, encoding: .utf8)
                    ?? String(data: part.body, encoding: .ascii)
            } else if part.mediaType == "text/html" && htmlBody == nil {
                htmlBody = String(data: part.body, encoding: .utf8)
                    ?? String(data: part.body, encoding: .ascii)
            } else if part.filename != nil {
                // Named parts that aren't text bodies are attachments
                attachments.append(part)
            }
        }

        return ParsedMIMEMessage(
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: attachments,
            inlineParts: inlineParts,
            allParts: parts
        )
    }

    /// Create a ParsedMIMEMessage from a single non-multipart body.
    private static func singlePartMessage(body: String, contentType: String, headers: [String: String]) -> ParsedMIMEMessage {
        let mediaType = extractMediaType(from: contentType)
        let encoding = headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? "7bit"
        let decodedData = decodeBody(body, encoding: encoding)
        let decodedText = String(data: decodedData, encoding: .utf8)
            ?? String(data: decodedData, encoding: .ascii)
            ?? body

        if mediaType == "text/html" {
            return ParsedMIMEMessage(
                textBody: nil,
                htmlBody: decodedText,
                attachments: [],
                inlineParts: [],
                allParts: []
            )
        } else {
            return ParsedMIMEMessage(
                textBody: decodedText,
                htmlBody: nil,
                attachments: [],
                inlineParts: [],
                allParts: []
            )
        }
    }
}
