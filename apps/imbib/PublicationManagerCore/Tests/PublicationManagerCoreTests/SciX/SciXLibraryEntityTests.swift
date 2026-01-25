//
//  SciXLibraryEntityTests.swift
//  PublicationManagerCoreTests
//
//  Created by Claude on 2026-01-09.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

final class SciXLibraryEntityTests: XCTestCase {

    var context: NSManagedObjectContext!

    override func setUpWithError() throws {
        // Create in-memory persistence controller for testing
        let controller = PersistenceController(inMemory: true)
        context = controller.viewContext
    }

    override func tearDownWithError() throws {
        context = nil
    }

    // MARK: - CDSciXLibrary Tests

    func testSciXLibrary_creation() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "test123"
        library.name = "Test Library"
        library.descriptionText = "A test library"
        library.isPublic = true
        library.dateCreated = Date()
        library.syncState = "synced"
        library.permissionLevel = "owner"
        library.ownerEmail = "test@example.com"
        library.documentCount = 10

        try context.save()

        XCTAssertNotNil(library.id)
        XCTAssertEqual(library.remoteID, "test123")
        XCTAssertEqual(library.name, "Test Library")
        XCTAssertTrue(library.isPublic)
        XCTAssertEqual(library.syncState, "synced")
        XCTAssertEqual(library.permissionLevel, "owner")
        XCTAssertEqual(library.documentCount, 10)
    }

    func testSciXLibrary_syncStateEnum() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "test"
        library.name = "Test"
        library.dateCreated = Date()
        library.permissionLevel = "read"

        library.syncState = "synced"
        XCTAssertEqual(library.syncStateEnum, .synced)

        library.syncState = "pending"
        XCTAssertEqual(library.syncStateEnum, .pending)

        library.syncState = "error"
        XCTAssertEqual(library.syncStateEnum, .error)

        library.syncState = "invalid"
        XCTAssertEqual(library.syncStateEnum, .synced)  // Default
    }

    func testSciXLibrary_permissionLevelEnum() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "test"
        library.name = "Test"
        library.dateCreated = Date()
        library.syncState = "synced"

        library.permissionLevel = "owner"
        XCTAssertEqual(library.permissionLevelEnum, .owner)
        XCTAssertTrue(library.canEdit)
        XCTAssertTrue(library.canManagePermissions)

        library.permissionLevel = "admin"
        XCTAssertEqual(library.permissionLevelEnum, .admin)
        XCTAssertTrue(library.canEdit)
        XCTAssertTrue(library.canManagePermissions)

        library.permissionLevel = "write"
        XCTAssertEqual(library.permissionLevelEnum, .write)
        XCTAssertTrue(library.canEdit)
        XCTAssertFalse(library.canManagePermissions)

        library.permissionLevel = "read"
        XCTAssertEqual(library.permissionLevelEnum, .read)
        XCTAssertFalse(library.canEdit)
        XCTAssertFalse(library.canManagePermissions)
    }

    func testSciXLibrary_displayName() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "test"
        library.dateCreated = Date()
        library.syncState = "synced"
        library.permissionLevel = "read"

        library.name = ""
        XCTAssertEqual(library.displayName, "Untitled Library")

        library.name = "My Papers"
        XCTAssertEqual(library.displayName, "My Papers")
    }

    func testSciXLibrary_hasPendingChanges() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "test"
        library.name = "Test"
        library.dateCreated = Date()
        library.syncState = "synced"
        library.permissionLevel = "owner"

        XCTAssertFalse(library.hasPendingChanges)
        XCTAssertEqual(library.pendingChangeCount, 0)

        // Add a pending change
        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = "add"
        change.dateCreated = Date()
        change.library = library

        try context.save()

        XCTAssertTrue(library.hasPendingChanges)
        XCTAssertEqual(library.pendingChangeCount, 1)
    }

    // MARK: - CDSciXPendingChange Tests

    func testSciXPendingChange_creation() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "lib123"
        library.name = "Library"
        library.dateCreated = Date()
        library.syncState = "pending"
        library.permissionLevel = "owner"

        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = "add"
        change.bibcodesJSON = "[\"2024ApJ...123A...1X\"]"
        change.dateCreated = Date()
        change.library = library

        try context.save()

        XCTAssertNotNil(change.id)
        XCTAssertEqual(change.action, "add")
        XCTAssertEqual(change.library?.remoteID, "lib123")
    }

    func testSciXPendingChange_actionEnum() throws {
        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.dateCreated = Date()

        change.action = "add"
        XCTAssertEqual(change.actionEnum, .add)

        change.action = "remove"
        XCTAssertEqual(change.actionEnum, .remove)

        change.action = "updateMeta"
        XCTAssertEqual(change.actionEnum, .updateMeta)

        change.action = "invalid"
        XCTAssertEqual(change.actionEnum, .add)  // Default
    }

    func testSciXPendingChange_bibcodes() throws {
        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = "add"
        change.dateCreated = Date()

        // Set bibcodes
        change.bibcodes = ["2024ApJ...123A...1X", "2024MNRAS.456..789Y"]

        // Retrieve and verify
        XCTAssertEqual(change.bibcodes.count, 2)
        XCTAssertTrue(change.bibcodes.contains("2024ApJ...123A...1X"))
        XCTAssertTrue(change.bibcodes.contains("2024MNRAS.456..789Y"))
    }

    func testSciXPendingChange_metadata() throws {
        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.action = "updateMeta"
        change.dateCreated = Date()

        // Set metadata
        change.metadata = CDSciXPendingChange.MetadataUpdate(
            name: "New Name",
            description: "New description",
            isPublic: true
        )

        // Retrieve and verify
        let metadata = change.metadata
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.name, "New Name")
        XCTAssertEqual(metadata?.description, "New description")
        XCTAssertEqual(metadata?.isPublic, true)
    }

    func testSciXPendingChange_changeDescription() throws {
        let change = CDSciXPendingChange(context: context)
        change.id = UUID()
        change.dateCreated = Date()

        change.action = "add"
        change.bibcodes = ["2024ApJ...123A...1X", "2024MNRAS.456..789Y"]
        XCTAssertEqual(change.changeDescription, "Add 2 papers")

        change.bibcodes = ["2024ApJ...123A...1X"]
        XCTAssertEqual(change.changeDescription, "Add 1 paper")

        change.action = "remove"
        XCTAssertEqual(change.changeDescription, "Remove 1 paper")

        change.action = "updateMeta"
        change.metadata = CDSciXPendingChange.MetadataUpdate(name: "New Name")
        XCTAssertEqual(change.changeDescription, "Update name")
    }

    // MARK: - Relationship Tests

    func testSciXLibrary_publication_relationship() throws {
        let library = CDSciXLibrary(context: context)
        library.id = UUID()
        library.remoteID = "lib"
        library.name = "Library"
        library.dateCreated = Date()
        library.syncState = "synced"
        library.permissionLevel = "read"

        let pub = CDPublication(context: context)
        pub.id = UUID()
        pub.citeKey = "Test2024"
        pub.entryType = "article"
        pub.title = "Test Paper"
        pub.dateAdded = Date()
        pub.dateModified = Date()

        // Add publication to library
        var scixLibs = pub.scixLibraries ?? []
        scixLibs.insert(library)
        pub.scixLibraries = scixLibs

        try context.save()

        XCTAssertTrue(library.publications?.contains(pub) ?? false)
        XCTAssertTrue(pub.scixLibraries?.contains(library) ?? false)
    }
}
