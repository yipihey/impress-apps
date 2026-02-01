//
//  BackwardCompatibilityTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-29.
//

import XCTest
@testable import PublicationManagerCore

final class BackwardCompatibilityTests: XCTestCase {

    // MARK: - V1.0 Format Compatibility

    func testV1FormatLibraryMetadataDecoding() throws {
        // V1.0 format doesn't have libraryType, isDefault, sortOrder
        let json = """
        {
            "libraryID": "550E8400-E29B-41D4-A716-446655440000",
            "name": "Old Library",
            "bibtexPath": "/path/to/library.bib",
            "exportVersion": "1.0",
            "exportDate": "2024-01-01T00:00:00Z",
            "collections": [],
            "smartSearches": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(LibraryMetadata.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(metadata.name, "Old Library")
        XCTAssertEqual(metadata.exportVersion, "1.0")
        XCTAssertNil(metadata.libraryType)  // Should be nil for v1.0
        XCTAssertNil(metadata.isDefault)
        XCTAssertNil(metadata.sortOrder)
    }

    func testV1FormatSmartSearchDecoding() throws {
        // V1.0 format doesn't have feed configuration
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "name": "Old Search",
            "query": "machine learning",
            "sourceIDs": ["arxiv", "crossref"],
            "maxResults": 50
        }
        """

        let decoder = JSONDecoder()
        let searchInfo = try decoder.decode(SmartSearchInfo.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(searchInfo.name, "Old Search")
        XCTAssertEqual(searchInfo.maxResults, 50)
        XCTAssertNil(searchInfo.feedsToInbox)  // Should be nil for v1.0
        XCTAssertNil(searchInfo.autoRefreshEnabled)
        XCTAssertNil(searchInfo.refreshIntervalSeconds)
        XCTAssertNil(searchInfo.resultCollectionID)
    }

    // MARK: - V2.0 Format with New Fields

    func testV2FormatLibraryMetadataDecoding() throws {
        let json = """
        {
            "libraryID": "550E8400-E29B-41D4-A716-446655440000",
            "name": "New Library",
            "bibtexPath": null,
            "exportVersion": "2.0",
            "exportDate": "2026-01-29T00:00:00Z",
            "collections": [],
            "smartSearches": [],
            "libraryType": "inbox",
            "isDefault": false,
            "sortOrder": 1
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(LibraryMetadata.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(metadata.name, "New Library")
        XCTAssertEqual(metadata.exportVersion, "2.0")
        XCTAssertEqual(metadata.libraryType, .inbox)
        XCTAssertEqual(metadata.isDefault, false)
        XCTAssertEqual(metadata.sortOrder, 1)
    }

    func testV2FormatSmartSearchDecoding() throws {
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "name": "Feed Search",
            "query": "cat:astro-ph.GA",
            "sourceIDs": ["arxiv"],
            "maxResults": 100,
            "feedsToInbox": true,
            "autoRefreshEnabled": true,
            "refreshIntervalSeconds": 86400,
            "resultCollectionID": "660E8400-E29B-41D4-A716-446655440000"
        }
        """

        let decoder = JSONDecoder()
        let searchInfo = try decoder.decode(SmartSearchInfo.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(searchInfo.name, "Feed Search")
        XCTAssertEqual(searchInfo.feedsToInbox, true)
        XCTAssertEqual(searchInfo.autoRefreshEnabled, true)
        XCTAssertEqual(searchInfo.refreshIntervalSeconds, 86400)
        XCTAssertNotNil(searchInfo.resultCollectionID)
    }

    // MARK: - Mixed Version Round-Trip

    func testV1ToV2Migration() throws {
        // Decode v1.0 format
        let v1Json = """
        {
            "libraryID": "550E8400-E29B-41D4-A716-446655440000",
            "name": "Legacy Library",
            "exportVersion": "1.0",
            "exportDate": "2024-01-01T00:00:00Z",
            "collections": [],
            "smartSearches": []
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let v1Metadata = try decoder.decode(LibraryMetadata.self, from: v1Json.data(using: .utf8)!)

        // Create v2.0 metadata from v1.0
        let v2Metadata = LibraryMetadata(
            libraryID: v1Metadata.libraryID,
            name: v1Metadata.name,
            bibtexPath: v1Metadata.bibtexPath,
            exportVersion: "2.0",
            exportDate: Date(),
            collections: v1Metadata.collections,
            smartSearches: v1Metadata.smartSearches,
            libraryType: .user,  // Default for v1.0 imports
            isDefault: false,
            sortOrder: 0
        )

        XCTAssertEqual(v2Metadata.exportVersion, "2.0")
        XCTAssertEqual(v2Metadata.libraryType, .user)
    }

    // MARK: - Header Backward Compatibility

    func testOldHeadersStillWork() {
        // Original v1.0 headers should still be present
        XCTAssertEqual(MboxHeader.libraryID, "X-Imbib-Library-ID")
        XCTAssertEqual(MboxHeader.libraryName, "X-Imbib-Library-Name")
        XCTAssertEqual(MboxHeader.exportVersion, "X-Imbib-Export-Version")
        XCTAssertEqual(MboxHeader.exportDate, "X-Imbib-Export-Date")
        XCTAssertEqual(MboxHeader.imbibID, "X-Imbib-ID")
        XCTAssertEqual(MboxHeader.imbibCiteKey, "X-Imbib-CiteKey")
        XCTAssertEqual(MboxHeader.imbibCollections, "X-Imbib-Collections")
    }

    func testNewHeadersAddedInV2() {
        // New v2.0 headers should be present
        XCTAssertEqual(MboxHeader.exportType, "X-Imbib-Export-Type")
        XCTAssertEqual(MboxHeader.manifestVersion, "X-Imbib-Manifest-Version")
        XCTAssertEqual(MboxHeader.libraryType, "X-Imbib-Library-Type")
        XCTAssertEqual(MboxHeader.sourceLibraryID, "X-Imbib-Source-Library-ID")
        XCTAssertEqual(MboxHeader.additionalLibraryIDs, "X-Imbib-Additional-Library-IDs")
    }

    // MARK: - Message Parsing Compatibility

    func testV1MessageParsing() async throws {
        let v1Mbox = """
        From imbib@imbib.local Thu Jan 01 00:00:00 2024
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 2024 00:00:00 +0000
        Message-ID: <library@imbib.local>
        X-Imbib-Library-ID: 550E8400-E29B-41D4-A716-446655440000
        X-Imbib-Library-Name: Test Library
        X-Imbib-Export-Version: 1.0
        Content-Type: text/plain; charset=utf-8

        {"name":"Test Library","exportVersion":"1.0","collections":[],"smartSearches":[]}

        From imbib@imbib.local Thu Jan 01 00:00:00 2024
        From: Einstein, Albert
        Subject: Special Relativity
        Date: Thu, 01 Jan 1905 00:00:00 +0000
        Message-ID: <einstein1905@imbib.local>
        X-Imbib-ID: 660E8400-E29B-41D4-A716-446655440000
        X-Imbib-CiteKey: Einstein1905a
        X-Imbib-EntryType: article
        Content-Type: text/plain; charset=utf-8

        Abstract text here.
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(v1Mbox)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].subject, "[imbib Library Export]")
        XCTAssertEqual(messages[1].headers[MboxHeader.imbibCiteKey], "Einstein1905a")

        // Should not have v2.0 headers
        XCTAssertNil(messages[0].headers[MboxHeader.exportType])
        XCTAssertNil(messages[0].headers[MboxHeader.libraryType])
    }

    func testV2MessageParsing() async throws {
        let v2Mbox = """
        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Everything Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <manifest@imbib.local>
        X-Imbib-Export-Type: everything
        X-Imbib-Manifest-Version: 2.0
        Content-Type: text/plain; charset=utf-8

        {"manifestVersion":"2.0","libraries":[],"mutedItems":[],"dismissedPapers":[],"totalPublications":0}

        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <library@imbib.local>
        X-Imbib-Library-ID: 550E8400-E29B-41D4-A716-446655440000
        X-Imbib-Library-Type: inbox
        X-Imbib-Export-Version: 2.0
        Content-Type: text/plain; charset=utf-8

        {}
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(v2Mbox)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].subject, "[imbib Everything Export]")
        XCTAssertEqual(messages[0].headers[MboxHeader.exportType], "everything")
        XCTAssertEqual(messages[1].headers[MboxHeader.libraryType], "inbox")
    }

    // MARK: - Graceful Degradation

    func testV2ExportWithOldImporter() async throws {
        // V2 format should still be parseable, just with reduced functionality
        let v2Mbox = """
        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Everything Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <manifest@imbib.local>
        X-Imbib-Export-Type: everything
        Content-Type: text/plain; charset=utf-8

        {}

        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <library@imbib.local>
        X-Imbib-Library-ID: 550E8400-E29B-41D4-A716-446655440000
        X-Imbib-Library-Name: First Library
        X-Imbib-Library-Type: user
        Content-Type: text/plain; charset=utf-8

        {"name":"First Library"}

        From imbib@imbib.local Thu Jan 01 00:00:00 1970
        From: imbib@imbib.local
        Subject: [imbib Library Export]
        Date: Thu, 01 Jan 1970 00:00:00 +0000
        Message-ID: <library2@imbib.local>
        X-Imbib-Library-ID: 660E8400-E29B-41D4-A716-446655440000
        X-Imbib-Library-Name: Second Library
        X-Imbib-Library-Type: inbox
        Content-Type: text/plain; charset=utf-8

        {"name":"Second Library"}
        """

        let parser = MboxParser()
        let messages = try await parser.parseContent(v2Mbox)

        // Old importer logic: just find the first library header
        var firstLibraryName: String?
        for message in messages {
            if message.subject == "[imbib Library Export]" {
                firstLibraryName = message.headers[MboxHeader.libraryName]
                break
            }
        }

        // Should get first library only (backward compat)
        XCTAssertEqual(firstLibraryName, "First Library")
    }
}
