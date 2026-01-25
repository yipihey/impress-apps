//
//  MboxTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-22.
//

import XCTest
@testable import PublicationManagerCore

final class MboxTests: XCTestCase {

    // MARK: - MIME Encoder Tests

    func testBase64Encoding() {
        let data = "Hello, World!".data(using: .utf8)!
        let encoded = MIMEEncoder.base64Encode(data)

        // Should encode and not exceed 76 chars per line
        XCTAssertFalse(encoded.isEmpty)
        let lines = encoded.components(separatedBy: "\n")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    func testQuotedPrintableEncoding() {
        let text = "Hello = World"
        let encoded = MIMEEncoder.quotedPrintableEncode(text)

        // The "=" should be encoded as "=3D"
        XCTAssertTrue(encoded.contains("=3D"))
    }

    func testFromLineEscaping() {
        let text = "First line\nFrom someone@example.com test\nLast line"
        let escaped = MIMEEncoder.escapeFromLines(text)

        // "From " at start of line should be escaped
        XCTAssertTrue(escaped.contains(">From"))
    }

    func testHeaderValueEncoding() {
        // ASCII header should pass through unchanged
        let ascii = "Simple Title"
        XCTAssertEqual(MIMEEncoder.encodeHeaderValue(ascii), ascii)

        // Non-ASCII should be encoded
        let unicode = "Über Résumé"
        let encoded = MIMEEncoder.encodeHeaderValue(unicode)
        XCTAssertTrue(encoded.contains("=?UTF-8?B?"))
    }

    // MARK: - MIME Decoder Tests

    func testBase64Decoding() {
        let original = "Hello, World!"
        let encoded = Data(original.utf8).base64EncodedString()
        let decoded = MIMEDecoder.base64Decode(encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .utf8), original)
    }

    func testQuotedPrintableDecode() {
        let encoded = "Hello=3DWorld"
        let decoded = MIMEDecoder.quotedPrintableDecode(encoded)

        XCTAssertEqual(decoded, "Hello=World")
    }

    func testSoftLineBreakDecoding() {
        let encoded = "This is a very long line that has been soft=\nwrapped"
        let decoded = MIMEDecoder.quotedPrintableDecode(encoded)

        XCTAssertEqual(decoded, "This is a very long line that has been softwrapped")
    }

    func testFromLineUnescaping() {
        let escaped = "First line\n>From someone@example.com test\nLast line"
        let unescaped = MIMEDecoder.unescapeFromLines(escaped)

        // ">From " should be unescaped to "From "
        XCTAssertTrue(unescaped.contains("From someone@example.com"))
        XCTAssertFalse(unescaped.contains(">From"))
    }

    func testBoundaryExtraction() {
        let contentType = "multipart/mixed; boundary=\"----=_Part_ABC123\""
        let boundary = MIMEDecoder.extractBoundary(from: contentType)

        XCTAssertEqual(boundary, "----=_Part_ABC123")
    }

    func testHeaderValueDecoding() {
        // RFC 2047 encoded-word
        let encoded = "=?UTF-8?B?w5xiZXIgUsOpc3Vtw6k=?="
        let decoded = MIMEDecoder.decodeHeaderValue(encoded)

        XCTAssertEqual(decoded, "Über Résumé")
    }

    // MARK: - Mbox Message Tests

    func testMboxMessageCreation() {
        let message = MboxMessage(
            from: "Albert Einstein",
            subject: "On the Electrodynamics of Moving Bodies",
            date: Date(),
            messageID: "test-123"
        )

        XCTAssertEqual(message.from, "Albert Einstein")
        XCTAssertEqual(message.subject, "On the Electrodynamics of Moving Bodies")
        XCTAssertEqual(message.messageID, "test-123")
    }

    func testMboxAttachmentCreation() {
        let data = "PDF content".data(using: .utf8)!
        let attachment = MboxAttachment(
            filename: "paper.pdf",
            contentType: "application/pdf",
            data: data,
            customHeaders: ["X-Imbib-LinkedFile-Path": "Papers/paper.pdf"]
        )

        XCTAssertEqual(attachment.filename, "paper.pdf")
        XCTAssertEqual(attachment.contentType, "application/pdf")
        XCTAssertEqual(attachment.customHeaders["X-Imbib-LinkedFile-Path"], "Papers/paper.pdf")
    }

    // MARK: - Round-Trip Tests

    func testMessageEncodeDecode() async throws {
        // Create a message
        let originalMessage = MboxMessage(
            from: "Einstein, Albert",
            subject: "Special Relativity",
            date: Date(timeIntervalSince1970: 1000000),
            messageID: "einstein-1905-relativity",
            headers: [
                "X-Imbib-ID": "550e8400-e29b-41d4-a716-446655440000",
                "X-Imbib-CiteKey": "Einstein1905a",
                "X-Imbib-EntryType": "article",
            ],
            body: "In this paper we discuss the principle of relativity.",
            attachments: []
        )

        // Encode to mbox format
        let encoded = MIMEEncoder.encode(originalMessage)

        // Verify structure
        XCTAssertTrue(encoded.hasPrefix("From imbib@imbib.local"))
        XCTAssertTrue(encoded.contains("Subject: Special Relativity"))
        XCTAssertTrue(encoded.contains("X-Imbib-CiteKey: Einstein1905a"))
    }

    func testMultipartMessageEncode() {
        let bibtexData = """
        @article{Einstein1905a,
          author = {Einstein, Albert},
          title = {Special Relativity}
        }
        """.data(using: .utf8)!

        let message = MboxMessage(
            from: "Einstein, Albert",
            subject: "Special Relativity",
            date: Date(),
            messageID: "test-multipart",
            headers: [:],
            body: "Abstract text here.",
            attachments: [
                MboxAttachment(
                    filename: "publication.bib",
                    contentType: "text/x-bibtex",
                    data: bibtexData,
                    customHeaders: [:]
                ),
            ]
        )

        let encoded = MIMEEncoder.encode(message)

        // Should be multipart
        XCTAssertTrue(encoded.contains("multipart/mixed"))
        XCTAssertTrue(encoded.contains("boundary="))
        XCTAssertTrue(encoded.contains("publication.bib"))
    }

    // MARK: - Import Preview Tests

    func testImportPreviewStructure() {
        let dummyMessage = MboxMessage(
            from: "Test",
            subject: "Test",
            date: Date(),
            messageID: "test"
        )

        let preview = MboxImportPreview(
            libraryMetadata: LibraryMetadata(
                name: "Test Library"
            ),
            publications: [
                PublicationPreview(
                    id: UUID(),
                    citeKey: "Test2024",
                    title: "Test Paper",
                    authors: "Test Author",
                    year: 2024,
                    message: dummyMessage
                ),
            ],
            duplicates: [],
            parseErrors: []
        )

        XCTAssertEqual(preview.libraryMetadata?.name, "Test Library")
        XCTAssertEqual(preview.publications.count, 1)
        XCTAssertEqual(preview.publications.first?.citeKey, "Test2024")
    }

    // MARK: - Library Metadata Tests

    func testLibraryMetadataEncoding() throws {
        let collections = [
            CollectionInfo(id: UUID(), name: "Physics"),
            CollectionInfo(id: UUID(), name: "Chemistry", parentID: nil),
        ]

        let metadata = LibraryMetadata(
            libraryID: UUID(),
            name: "Research Papers",
            exportVersion: "1.0",
            exportDate: Date(),
            collections: collections
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)
        let jsonString = String(data: data, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("Research Papers"))
        XCTAssertTrue(jsonString!.contains("Physics"))
    }

    func testLibraryMetadataDecoding() throws {
        let json = """
        {
            "name": "My Library",
            "exportVersion": "1.0",
            "exportDate": "2024-01-22T10:30:00Z",
            "collections": [],
            "smartSearches": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(LibraryMetadata.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(metadata.name, "My Library")
        XCTAssertEqual(metadata.exportVersion, "1.0")
    }

    // MARK: - Mbox Parser Tests

    func testMboxParserSingleMessage() async throws {
        let mboxContent = """
        From imbib@imbib.local Thu Jan 01 00:00:00 2024
        From: Test Author
        Subject: Test Subject
        Date: Thu, 01 Jan 2024 00:00:00 +0000
        Message-ID: <test@imbib.local>
        Content-Type: text/plain; charset=utf-8

        This is the body.
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(mboxContent)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.subject, "Test Subject")
        XCTAssertTrue(messages.first?.body.contains("This is the body") ?? false)
    }

    func testMboxParserMultipleMessages() async throws {
        let mboxContent = """
        From imbib@imbib.local Thu Jan 01 00:00:00 2024
        From: Author One
        Subject: First Paper
        Date: Thu, 01 Jan 2024 00:00:00 +0000
        Message-ID: <first@imbib.local>
        Content-Type: text/plain; charset=utf-8

        First body.

        From imbib@imbib.local Fri Jan 02 00:00:00 2024
        From: Author Two
        Subject: Second Paper
        Date: Fri, 02 Jan 2024 00:00:00 +0000
        Message-ID: <second@imbib.local>
        Content-Type: text/plain; charset=utf-8

        Second body.
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(mboxContent)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].subject, "First Paper")
        XCTAssertEqual(messages[1].subject, "Second Paper")
    }
}
