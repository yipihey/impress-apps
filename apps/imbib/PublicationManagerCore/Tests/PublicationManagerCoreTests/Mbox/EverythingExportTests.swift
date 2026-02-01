//
//  EverythingExportTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-29.
//

import XCTest
@testable import PublicationManagerCore

final class EverythingExportTests: XCTestCase {

    // MARK: - Manifest Tests

    func testManifestCreation() {
        let manifest = EverythingManifest(
            manifestVersion: "2.0",
            exportDate: Date(),
            deviceName: "Test Device",
            libraries: [
                LibraryIndex(id: UUID(), name: "My Library", type: .user, publicationCount: 50),
                LibraryIndex(id: UUID(), name: "Inbox", type: .inbox, publicationCount: 10)
            ],
            mutedItems: [
                MutedItemInfo(type: "author", value: "John Doe"),
                MutedItemInfo(type: "venue", value: "Journal of Bad Science")
            ],
            dismissedPapers: [
                DismissedPaperInfo(doi: "10.1234/test", arxivID: nil, bibcode: nil)
            ],
            totalPublications: 60
        )

        XCTAssertEqual(manifest.manifestVersion, "2.0")
        XCTAssertEqual(manifest.libraries.count, 2)
        XCTAssertEqual(manifest.mutedItems.count, 2)
        XCTAssertEqual(manifest.dismissedPapers.count, 1)
        XCTAssertEqual(manifest.totalPublications, 60)
    }

    func testManifestEncoding() throws {
        let manifest = EverythingManifest(
            manifestVersion: "2.0",
            exportDate: Date(),
            deviceName: "Test Device",
            libraries: [
                LibraryIndex(id: UUID(), name: "Test Library", type: .user, publicationCount: 25)
            ],
            totalPublications: 25
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let jsonString = String(data: data, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("\"manifestVersion\":\"2.0\""))
        XCTAssertTrue(jsonString!.contains("Test Library"))
    }

    func testManifestDecoding() throws {
        let json = """
        {
            "manifestVersion": "2.0",
            "exportDate": "2026-01-29T12:00:00Z",
            "libraries": [
                {
                    "id": "550E8400-E29B-41D4-A716-446655440000",
                    "name": "Research Papers",
                    "type": "user",
                    "publicationCount": 100,
                    "collectionCount": 5,
                    "smartSearchCount": 3
                }
            ],
            "mutedItems": [],
            "dismissedPapers": [],
            "totalPublications": 100
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(EverythingManifest.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(manifest.manifestVersion, "2.0")
        XCTAssertEqual(manifest.libraries.count, 1)
        XCTAssertEqual(manifest.libraries.first?.name, "Research Papers")
        XCTAssertEqual(manifest.libraries.first?.type, .user)
        XCTAssertEqual(manifest.totalPublications, 100)
    }

    // MARK: - Library Type Tests

    func testLibraryTypeRawValues() {
        XCTAssertEqual(LibraryType.user.rawValue, "user")
        XCTAssertEqual(LibraryType.inbox.rawValue, "inbox")
        XCTAssertEqual(LibraryType.save.rawValue, "save")
        XCTAssertEqual(LibraryType.dismissed.rawValue, "dismissed")
        XCTAssertEqual(LibraryType.exploration.rawValue, "exploration")
    }

    func testLibraryTypeDecoding() throws {
        let json = """
        {
            "id": "550E8400-E29B-41D4-A716-446655440000",
            "name": "Inbox",
            "type": "inbox",
            "publicationCount": 10,
            "collectionCount": 0,
            "smartSearchCount": 0
        }
        """

        let index = try JSONDecoder().decode(LibraryIndex.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(index.type, .inbox)
    }

    // MARK: - Header Constants Tests

    func testEverythingExportHeaders() {
        XCTAssertEqual(MboxHeader.exportType, "X-Imbib-Export-Type")
        XCTAssertEqual(MboxHeader.manifestVersion, "X-Imbib-Manifest-Version")
        XCTAssertEqual(MboxHeader.libraryType, "X-Imbib-Library-Type")
        XCTAssertEqual(MboxHeader.sourceLibraryID, "X-Imbib-Source-Library-ID")
        XCTAssertEqual(MboxHeader.additionalLibraryIDs, "X-Imbib-Additional-Library-IDs")
        XCTAssertEqual(MboxHeader.feedIDs, "X-Imbib-Feed-IDs")
        XCTAssertEqual(MboxHeader.triageState, "X-Imbib-Triage-State")
        XCTAssertEqual(MboxHeader.isRead, "X-Imbib-IsRead")
        XCTAssertEqual(MboxHeader.isStarred, "X-Imbib-IsStarred")
    }

    // MARK: - Extended Metadata Tests

    func testLibraryMetadataWithType() throws {
        let metadata = LibraryMetadata(
            libraryID: UUID(),
            name: "Inbox",
            exportVersion: "2.0",
            exportDate: Date(),
            libraryType: .inbox,
            isDefault: false,
            sortOrder: 0
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LibraryMetadata.self, from: data)

        XCTAssertEqual(decoded.name, "Inbox")
        XCTAssertEqual(decoded.libraryType, .inbox)
        XCTAssertEqual(decoded.isDefault, false)
        XCTAssertEqual(decoded.sortOrder, 0)
    }

    func testSmartSearchInfoWithFeedConfig() throws {
        let searchInfo = SmartSearchInfo(
            id: UUID(),
            name: "arXiv Feed",
            query: "cat:astro-ph.GA",
            sourceIDs: ["arxiv"],
            maxResults: 50,
            feedsToInbox: true,
            autoRefreshEnabled: true,
            refreshIntervalSeconds: 3600,
            resultCollectionID: UUID()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(searchInfo)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SmartSearchInfo.self, from: data)

        XCTAssertEqual(decoded.name, "arXiv Feed")
        XCTAssertEqual(decoded.feedsToInbox, true)
        XCTAssertEqual(decoded.autoRefreshEnabled, true)
        XCTAssertEqual(decoded.refreshIntervalSeconds, 3600)
    }

    // MARK: - Muted Item Tests

    func testMutedItemInfo() {
        let mutedItem = MutedItemInfo(
            type: "author",
            value: "John Doe",
            dateAdded: Date()
        )

        XCTAssertEqual(mutedItem.type, "author")
        XCTAssertEqual(mutedItem.value, "John Doe")
        XCTAssertEqual(mutedItem.id, "author:John Doe")
    }

    func testMutedItemEncoding() throws {
        let mutedItem = MutedItemInfo(
            type: "venue",
            value: "Journal of Questionable Science",
            dateAdded: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mutedItem)
        let jsonString = String(data: data, encoding: .utf8)

        XCTAssertNotNil(jsonString)
        XCTAssertTrue(jsonString!.contains("venue"))
        XCTAssertTrue(jsonString!.contains("Journal of Questionable Science"))
    }

    // MARK: - Dismissed Paper Tests

    func testDismissedPaperInfo() {
        let dismissed = DismissedPaperInfo(
            doi: "10.1234/test.paper",
            arxivID: "2301.12345",
            bibcode: nil,
            dateDismissed: Date()
        )

        XCTAssertTrue(dismissed.hasIdentifier)
        XCTAssertEqual(dismissed.doi, "10.1234/test.paper")
        XCTAssertEqual(dismissed.arxivID, "2301.12345")
    }

    func testDismissedPaperWithoutIdentifier() {
        let dismissed = DismissedPaperInfo(
            doi: nil,
            arxivID: nil,
            bibcode: nil,
            dateDismissed: nil
        )

        XCTAssertFalse(dismissed.hasIdentifier)
    }

    // MARK: - Export Options Tests

    func testDefaultExportOptions() {
        let options = EverythingExportOptions.default

        XCTAssertTrue(options.includeFiles)
        XCTAssertTrue(options.includeBibTeX)
        XCTAssertNil(options.maxFileSize)
        XCTAssertFalse(options.includeExploration)
        XCTAssertTrue(options.includeTriageHistory)
        XCTAssertTrue(options.includeMutedItems)
    }

    func testCustomExportOptions() {
        let options = EverythingExportOptions(
            includeFiles: false,
            includeBibTeX: true,
            maxFileSize: 10_000_000,
            includeExploration: true,
            includeTriageHistory: false,
            includeMutedItems: false
        )

        XCTAssertFalse(options.includeFiles)
        XCTAssertTrue(options.includeBibTeX)
        XCTAssertEqual(options.maxFileSize, 10_000_000)
        XCTAssertTrue(options.includeExploration)
        XCTAssertFalse(options.includeTriageHistory)
        XCTAssertFalse(options.includeMutedItems)
    }

    // MARK: - Export Result Tests

    func testExportResultSummary() {
        let result = EverythingExportResult(
            libraryCount: 3,
            publicationCount: 150,
            collectionCount: 10,
            smartSearchCount: 5,
            mutedItemCount: 3,
            dismissedPaperCount: 20,
            fileSize: 52_428_800
        )

        XCTAssertEqual(result.libraryCount, 3)
        XCTAssertEqual(result.publicationCount, 150)
        XCTAssertTrue(result.summary.contains("3 libraries"))
        XCTAssertTrue(result.summary.contains("150 publications"))
        // ByteCountFormatter may round differently, so just check it contains MB
        XCTAssertTrue(result.formattedFileSize.contains("MB"))
    }
}
