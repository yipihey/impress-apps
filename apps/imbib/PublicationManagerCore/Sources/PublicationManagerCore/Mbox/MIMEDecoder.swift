//
//  MIMEDecoder.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//  Stage 7 item 9: the bodies moved to Rust (`crates/imbib-core/src/mbox/mime.rs`).
//

import Foundation
import ImbibRustCore

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
///
/// **This is a shim.** Every decision — boundary splitting, header unfolding,
/// RFC 2047 encoded-words, quoted-printable, base64, filename extraction,
/// mboxrd unescaping — lives in `imbib-core`'s `mbox::mime` module and is pinned
/// by 114 golden cases in `crates/imbib-core/test_fixtures/golden/mime_*.json`,
/// captured from this file before its bodies were replaced.
///
/// One behaviour deliberately CHANGED, and it is the reason the port was worth
/// doing: `quotedPrintableDecode` used to build one Latin-1 scalar per `=XX`
/// octet, so a UTF-8 sequence decoded to mojibake — and since `MIMEEncoder`
/// writes bodies as quoted-printable over UTF-8, **imbib's own export → import
/// round trip corrupted every non-ASCII abstract** (`Müller` → `MÃ¼ller`). The
/// Rust decoder honours the declared charset. See
/// docs/parser-batch-swift-rust-split.md §1.
public struct MIMEDecoder: Sendable {

    // MARK: - Public API

    /// Decode a multipart message into parts.
    /// - Parameters:
    ///   - content: The raw message content (after headers)
    ///   - boundary: The MIME boundary string
    /// - Returns: Array of decoded MIME parts
    public static func decode(_ content: String, boundary: String) -> [MIMEPart] {
        ImbibRustCore.mimeDecodeMultipart(content: content, boundary: boundary).map { part in
            MIMEPart(
                contentType: part.contentType,
                transferEncoding: part.transferEncoding,
                filename: part.filename,
                headers: Dictionary(
                    uniqueKeysWithValues: zip(part.headerNames, part.headerValues)),
                content: part.content
            )
        }
    }

    /// Extract MIME boundary from Content-Type header.
    public static func extractBoundary(from contentType: String) -> String? {
        ImbibRustCore.mimeExtractBoundary(contentType: contentType)
    }

    // MARK: - Header Value Decoding

    /// Decode RFC 2047 encoded header value (`=?charset?encoding?text?=`).
    ///
    /// Honours the declared charset for `Q` words as well as `B` words; the old
    /// implementation ignored it for `Q`, which silently transliterated
    /// ISO-8859-2 surnames into punctuation.
    public static func decodeHeaderValue(_ value: String) -> String {
        ImbibRustCore.mimeDecodeHeaderValue(value: value)
    }

    // MARK: - Content Decoding

    /// Decode base64 encoded string. Foundation semantics: whitespace stripped,
    /// padding required, `nil` on any error.
    public static func base64Decode(_ encoded: String) -> Data? {
        ImbibRustCore.mimeBase64Decode(encoded: encoded)
    }

    /// Decode quoted-printable encoded string.
    ///
    /// - Parameters:
    ///   - encoded: the quoted-printable source
    ///   - charset: the `charset=` parameter from the part's `Content-Type`.
    ///     Defaults to UTF-8, which is what imbib's exporter writes.
    public static func quotedPrintableDecode(
        _ encoded: String,
        charset: String = "UTF-8"
    ) -> String {
        ImbibRustCore.mimeQuotedPrintableDecode(encoded: encoded, charset: charset)
    }

    // MARK: - mboxrd Unescaping

    /// Unescape "From " lines (mboxrd format).
    /// Removes one ">" from lines that match ">+From ".
    public static func unescapeFromLines(_ text: String) -> String {
        ImbibRustCore.mimeUnescapeFromLines(text: text)
    }
}
