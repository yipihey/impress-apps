//
//  MboxParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//  Stage 7 item 9: the parsing moved to Rust
//  (`crates/imbib-core/src/mbox/parser.rs`).
//

import Foundation
import ImbibRustCore
import OSLog

// MARK: - Mbox Parser

/// Parses mbox files into individual messages.
///
/// **This is a shim.** The actor exists for the file read and for the call
/// sites' `await`; every parsing decision — `From ` line splitting, header
/// unfolding, standard-header extraction, multipart vs single-part body
/// decoding, `X-Imbib-*` capture and RFC 2822 date parsing — lives in
/// `imbib-core`'s `mbox::parser` module, pinned by 23 whole-archive golden cases
/// in `crates/imbib-core/test_fixtures/golden/mbox_parse.json`.
///
/// Two things the Rust side reports as ABSENT which this shim still fills in, so
/// callers see exactly what they always did: a missing `Message-ID` becomes a
/// fresh UUID, and a message with neither a parseable `Date:` nor a `From `
/// envelope date becomes `Date()`. Inventing identity belongs at the edge, not
/// in a parser — a parser that does it cannot be tested and makes a message's
/// id depend on when it was imported.
///
/// See docs/parser-batch-swift-rust-split.md for the preserved quirks (a
/// preamble before the first `From ` line still becomes its own message) and the
/// quoted-printable corruption that was fixed.
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
        return parseContent(content)
    }

    /// Parse mbox content string into messages.
    /// - Parameter content: Raw mbox file content
    /// - Returns: Array of parsed messages
    public func parseContent(_ content: String) -> [MboxMessage] {
        let messages = ImbibRustCore.mboxParse(content: content).map { message in
            MboxMessage(
                from: message.from,
                subject: message.subject,
                date: message.dateUnixSeconds.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                } ?? Date(),
                messageID: message.messageId ?? UUID().uuidString,
                headers: Dictionary(
                    uniqueKeysWithValues: zip(message.headerNames, message.headerValues)),
                body: message.body,
                attachments: message.attachments.map { attachment in
                    MboxAttachment(
                        filename: attachment.filename,
                        contentType: attachment.contentType,
                        data: attachment.data,
                        customHeaders: Dictionary(
                            uniqueKeysWithValues: zip(
                                attachment.customHeaderNames, attachment.customHeaderValues))
                    )
                }
            )
        }
        logger.info("Parsed \(messages.count) messages from mbox")
        return messages
    }
}

// MARK: - Parse Errors

/// Errors that can occur during mbox parsing.
///
/// Only `fileNotFound` is ever thrown. `invalidFormat` and `decodingError` are
/// kept because they are `public` API, but the parser rejects no input: a
/// malformed archive yields whatever messages could be recovered, which is what
/// an importer wants.
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
