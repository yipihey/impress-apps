//
//  MIMEDecoder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import Foundation

// MARK: - MIME Part

/// Represents a decoded MIME part.
public struct MIMEPart: Sendable {
    public let contentType: String
    public let transferEncoding: String?
    public let filename: String?
    public let headers: [String: String]
    public let content: Data

    public init(
        contentType: String,
        transferEncoding: String? = nil,
        filename: String? = nil,
        headers: [String: String] = [:],
        content: Data
    ) {
        self.contentType = contentType
        self.transferEncoding = transferEncoding
        self.filename = filename
        self.headers = headers
        self.content = content
    }

    /// Get content as string (for text types).
    public var contentString: String? {
        String(data: content, encoding: .utf8)
    }
}

// MARK: - MIME Decoder

/// Decodes MIME multipart messages.
public struct MIMEDecoder: Sendable {

    // MARK: - Public API

    /// Decode a multipart message into parts.
    /// - Parameters:
    ///   - content: The raw message content (after headers)
    ///   - boundary: The MIME boundary string
    /// - Returns: Array of decoded MIME parts
    public static func decode(_ content: String, boundary: String) -> [MIMEPart] {
        var parts: [MIMEPart] = []

        // Split by boundary
        let delimiter = "--\(boundary)"
        _ = "--\(boundary)--"  // End delimiter (handled in parsing)

        // Normalize line endings
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")

        // Split into parts
        let sections = normalized.components(separatedBy: delimiter)

        for section in sections {
            // Skip preamble (before first boundary) and epilogue (after closing boundary)
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("--") {
                continue
            }

            // Parse part
            if let part = parsePart(trimmed) {
                parts.append(part)
            }
        }

        return parts
    }

    /// Parse a single MIME part (headers + content).
    private static func parsePart(_ raw: String) -> MIMEPart? {
        // Split headers from body at first empty line
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var headerLines: [String] = []
        var bodyStartIndex = 0

        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                bodyStartIndex = index + 1
                break
            }
            headerLines.append(String(line))
        }

        // Parse headers (handle folded headers)
        var headers: [String: String] = [:]
        var currentHeader: String?
        var currentValue: String = ""

        for line in headerLines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Continuation of previous header (folded)
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                // Save previous header
                if let header = currentHeader {
                    headers[header] = currentValue
                }

                // Parse new header
                if let colonIndex = line.firstIndex(of: ":") {
                    currentHeader = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    currentValue = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Save last header
        if let header = currentHeader {
            headers[header] = currentValue
        }

        // Extract body
        let bodyLines = Array(lines[bodyStartIndex...])
        let bodyContent = bodyLines.joined(separator: "\n")

        // Get content type
        let contentType = headers["Content-Type"] ?? "text/plain"
        let transferEncoding = headers["Content-Transfer-Encoding"]

        // Extract filename from Content-Type or Content-Disposition
        let filename = extractFilename(from: headers)

        // Decode content based on transfer encoding
        let decodedContent: Data
        if let encoding = transferEncoding?.lowercased() {
            switch encoding {
            case "base64":
                decodedContent = base64Decode(bodyContent) ?? Data()
            case "quoted-printable":
                decodedContent = quotedPrintableDecode(bodyContent).data(using: .utf8) ?? Data()
            default:
                decodedContent = bodyContent.data(using: .utf8) ?? Data()
            }
        } else {
            decodedContent = bodyContent.data(using: .utf8) ?? Data()
        }

        return MIMEPart(
            contentType: extractBaseContentType(contentType),
            transferEncoding: transferEncoding,
            filename: filename,
            headers: headers,
            content: decodedContent
        )
    }

    // MARK: - Header Parsing

    /// Extract filename from Content-Type or Content-Disposition headers.
    private static func extractFilename(from headers: [String: String]) -> String? {
        // Try Content-Disposition first
        if let disposition = headers["Content-Disposition"] {
            if let filename = extractParameter(from: disposition, name: "filename") {
                return decodeHeaderValue(filename)
            }
        }

        // Try Content-Type
        if let contentType = headers["Content-Type"] {
            if let name = extractParameter(from: contentType, name: "name") {
                return decodeHeaderValue(name)
            }
        }

        return nil
    }

    /// Extract a parameter from a header value (e.g., filename="test.pdf").
    private static func extractParameter(from headerValue: String, name: String) -> String? {
        // Pattern: name="value" or name=value
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]*))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(headerValue.startIndex..., in: headerValue)
        guard let match = regex.firstMatch(in: headerValue, options: [], range: range) else {
            return nil
        }

        // Check quoted value first (group 1), then unquoted (group 2)
        if let range1 = Range(match.range(at: 1), in: headerValue) {
            return String(headerValue[range1])
        }
        if let range2 = Range(match.range(at: 2), in: headerValue) {
            return String(headerValue[range2])
        }

        return nil
    }

    /// Extract base content type without parameters.
    private static func extractBaseContentType(_ contentType: String) -> String {
        if let semicolonIndex = contentType.firstIndex(of: ";") {
            return String(contentType[..<semicolonIndex]).trimmingCharacters(in: .whitespaces)
        }
        return contentType.trimmingCharacters(in: .whitespaces)
    }

    /// Extract MIME boundary from Content-Type header.
    public static func extractBoundary(from contentType: String) -> String? {
        extractParameter(from: contentType, name: "boundary")
    }

    // MARK: - Header Value Decoding

    /// Decode RFC 2047 encoded header value (=?charset?encoding?text?=).
    public static func decodeHeaderValue(_ value: String) -> String {
        // Pattern for encoded-word: =?charset?encoding?encoded_text?=
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }

        var result = value
        let matches = regex.matches(in: value, options: [], range: NSRange(value.startIndex..., in: value))

        // Process matches in reverse order to preserve indices
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let textRange = Range(match.range(at: 3), in: value) else {
                continue
            }

            let charset = String(value[charsetRange])
            let encoding = String(value[encodingRange]).uppercased()
            let encodedText = String(value[textRange])

            let decodedText: String?
            if encoding == "B" {
                // Base64
                if let data = Data(base64Encoded: encodedText) {
                    decodedText = String(data: data, encoding: encodingForCharset(charset))
                } else {
                    decodedText = nil
                }
            } else {
                // Q (quoted-printable variant)
                let qpDecoded = encodedText
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "=\n", with: "")
                decodedText = quotedPrintableDecode(qpDecoded)
            }

            if let decoded = decodedText {
                result.replaceSubrange(fullRange, with: decoded)
            }
        }

        return result
    }

    /// Get String.Encoding for charset name.
    private static func encodingForCharset(_ charset: String) -> String.Encoding {
        switch charset.uppercased() {
        case "UTF-8", "UTF8":
            return .utf8
        case "ISO-8859-1", "LATIN1":
            return .isoLatin1
        case "ISO-8859-2", "LATIN2":
            return .isoLatin2
        case "US-ASCII", "ASCII":
            return .ascii
        case "WINDOWS-1252":
            return .windowsCP1252
        default:
            return .utf8
        }
    }

    // MARK: - Content Decoding

    /// Decode base64 encoded string.
    public static func base64Decode(_ encoded: String) -> Data? {
        // Remove whitespace and newlines
        let cleaned = encoded
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")

        return Data(base64Encoded: cleaned)
    }

    /// Decode quoted-printable encoded string.
    public static func quotedPrintableDecode(_ encoded: String) -> String {
        var result = ""
        var index = encoded.startIndex

        while index < encoded.endIndex {
            let char = encoded[index]

            if char == "=" {
                // Check for soft line break
                let nextIndex = encoded.index(after: index)
                if nextIndex < encoded.endIndex {
                    let nextChar = encoded[nextIndex]
                    if nextChar == "\n" {
                        // Soft line break - skip both characters
                        index = encoded.index(after: nextIndex)
                        continue
                    } else if nextChar == "\r" {
                        // Handle CRLF soft line break
                        let afterCR = encoded.index(after: nextIndex)
                        if afterCR < encoded.endIndex && encoded[afterCR] == "\n" {
                            index = encoded.index(after: afterCR)
                            continue
                        }
                    }

                    // Try to decode hex value
                    let hexEndIndex = encoded.index(nextIndex, offsetBy: 2, limitedBy: encoded.endIndex)
                    if let hexEnd = hexEndIndex {
                        let hexString = String(encoded[nextIndex..<hexEnd])
                        if let byte = UInt8(hexString, radix: 16) {
                            result.append(Character(UnicodeScalar(byte)))
                            index = hexEnd
                            continue
                        }
                    }
                }
            }

            result.append(char)
            index = encoded.index(after: index)
        }

        return result
    }

    // MARK: - mboxrd Unescaping

    /// Unescape "From " lines (mboxrd format).
    /// Removes one ">" from lines that match ">+From ".
    public static func unescapeFromLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String] = []

        for line in lines {
            // Count leading ">" characters
            var gtCount = 0
            var idx = line.startIndex
            while idx < line.endIndex && line[idx] == ">" {
                gtCount += 1
                idx = line.index(after: idx)
            }

            // If we have ">+" followed by "From ", remove one ">"
            if gtCount > 0 && idx < line.endIndex {
                let remainder = line[idx...]
                if remainder.hasPrefix("From ") {
                    result.append(String(line.dropFirst()))
                    continue
                }
            }

            result.append(String(line))
        }

        return result.joined(separator: "\n")
    }
}
