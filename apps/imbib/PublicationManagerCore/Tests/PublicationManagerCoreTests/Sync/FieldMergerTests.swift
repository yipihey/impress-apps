//
//  FieldMergerTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-16.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class FieldMergerTests: XCTestCase {

    var persistenceController: PersistenceController!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        persistenceController = PersistenceController(configuration: .preview)
        context = persistenceController.viewContext
    }

    override func tearDown() {
        context = nil
        persistenceController = nil
        super.tearDown()
    }

    // MARK: - Field Timestamps Tests

    func testFieldTimestamps_encode_decode() {
        var timestamps = FieldTimestamps()
        let now = Date()

        timestamps["title"] = now
        timestamps["year"] = now.addingTimeInterval(-100)

        XCTAssertEqual(timestamps["title"], now)
        XCTAssertEqual(timestamps["year"], now.addingTimeInterval(-100))
        XCTAssertNil(timestamps["abstract"])
    }

    func testFieldTimestamps_touch() {
        var timestamps = FieldTimestamps()

        let beforeTouch = Date()
        timestamps.touch("title")
        let afterTouch = Date()

        XCTAssertNotNil(timestamps["title"])
        XCTAssertTrue(timestamps["title"]! >= beforeTouch)
        XCTAssertTrue(timestamps["title"]! <= afterTouch)
    }

    func testFieldTimestamps_touchAll() {
        var timestamps = FieldTimestamps()

        timestamps.touchAll(["title", "year", "abstract"])

        XCTAssertNotNil(timestamps["title"])
        XCTAssertNotNil(timestamps["year"])
        XCTAssertNotNil(timestamps["abstract"])
    }

    // MARK: - Publication Timestamps Tests

    func testPublication_decodedFieldTimestamps_empty() {
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = "test"
        publication.entryType = "article"
        publication.dateAdded = Date()
        publication.dateModified = Date()

        let timestamps = publication.decodedFieldTimestamps
        XCTAssertTrue(timestamps.timestamps.isEmpty)
    }

    func testPublication_setFieldTimestamps() {
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = "test"
        publication.entryType = "article"
        publication.dateAdded = Date()
        publication.dateModified = Date()

        var timestamps = FieldTimestamps()
        timestamps["title"] = Date()
        publication.setFieldTimestamps(timestamps)

        let decoded = publication.decodedFieldTimestamps
        XCTAssertNotNil(decoded["title"])
    }

    func testPublication_touchFieldTimestamp() {
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = "test"
        publication.entryType = "article"
        publication.dateAdded = Date()
        publication.dateModified = Date()

        publication.touchFieldTimestamp("title")

        let timestamps = publication.decodedFieldTimestamps
        XCTAssertNotNil(timestamps["title"])
    }

    // MARK: - Scalar Fields Tests

    func testPublication_scalarFields_containsExpectedFields() {
        let fields = CDPublication.scalarFields

        XCTAssertTrue(fields.contains("title"))
        XCTAssertTrue(fields.contains("year"))
        XCTAssertTrue(fields.contains("abstract"))
        XCTAssertTrue(fields.contains("doi"))
        XCTAssertTrue(fields.contains("url"))
        XCTAssertTrue(fields.contains("isRead"))
        XCTAssertTrue(fields.contains("citationCount"))
    }

    // MARK: - Field Merger Tests

    func testFieldMerger_mergeScalarFields_remoteWinsWithNewerTimestamp() async {
        // Create local publication
        let local = CDPublication(context: context)
        local.id = UUID()
        local.citeKey = "test"
        local.entryType = "article"
        local.title = "Local Title"
        local.dateAdded = Date()
        local.dateModified = Date()

        var localTimestamps = FieldTimestamps()
        localTimestamps["title"] = Date().addingTimeInterval(-100)
        local.setFieldTimestamps(localTimestamps)

        // Create remote publication
        let remote = CDPublication(context: context)
        remote.id = UUID()
        remote.citeKey = "test"
        remote.entryType = "article"
        remote.title = "Remote Title"
        remote.dateAdded = Date()
        remote.dateModified = Date()

        var remoteTimestamps = FieldTimestamps()
        remoteTimestamps["title"] = Date() // Newer
        remote.setFieldTimestamps(remoteTimestamps)

        // Merge
        let merged = await FieldMerger.shared.mergeScalarFields(local: local, remote: remote)

        XCTAssertEqual(merged["title"] as? String, "Remote Title")
    }

    func testFieldMerger_mergeScalarFields_localWinsWithNewerTimestamp() async {
        // Create local publication
        let local = CDPublication(context: context)
        local.id = UUID()
        local.citeKey = "test"
        local.entryType = "article"
        local.title = "Local Title"
        local.dateAdded = Date()
        local.dateModified = Date()

        var localTimestamps = FieldTimestamps()
        localTimestamps["title"] = Date() // Newer
        local.setFieldTimestamps(localTimestamps)

        // Create remote publication
        let remote = CDPublication(context: context)
        remote.id = UUID()
        remote.citeKey = "test"
        remote.entryType = "article"
        remote.title = "Remote Title"
        remote.dateAdded = Date()
        remote.dateModified = Date()

        var remoteTimestamps = FieldTimestamps()
        remoteTimestamps["title"] = Date().addingTimeInterval(-100)
        remote.setFieldTimestamps(remoteTimestamps)

        // Merge
        let merged = await FieldMerger.shared.mergeScalarFields(local: local, remote: remote)

        XCTAssertEqual(merged["title"] as? String, "Local Title")
    }

    func testFieldMerger_mergeTags_unionMerge() async {
        // Create tags
        let tag1 = CDTag(context: context)
        tag1.id = UUID()
        tag1.name = "Tag1"

        let tag2 = CDTag(context: context)
        tag2.id = UUID()
        tag2.name = "Tag2"

        let tag3 = CDTag(context: context)
        tag3.id = UUID()
        tag3.name = "Tag3"

        let localTags: Set<CDTag> = [tag1, tag2]
        let remoteTags: Set<CDTag> = [tag2, tag3]

        // Merge
        let merged = await FieldMerger.shared.mergeTags(local: localTags, remote: remoteTags)

        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains(tag1))
        XCTAssertTrue(merged.contains(tag2))
        XCTAssertTrue(merged.contains(tag3))
    }

    func testFieldMerger_mergeCollections_unionMerge() async {
        // Create collections
        let col1 = CDCollection(context: context)
        col1.id = UUID()
        col1.name = "Collection1"

        let col2 = CDCollection(context: context)
        col2.id = UUID()
        col2.name = "Collection2"

        let localCollections: Set<CDCollection> = [col1]
        let remoteCollections: Set<CDCollection> = [col2]

        // Merge
        let merged = await FieldMerger.shared.mergeCollections(local: localCollections, remote: remoteCollections)

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(col1))
        XCTAssertTrue(merged.contains(col2))
    }
}
