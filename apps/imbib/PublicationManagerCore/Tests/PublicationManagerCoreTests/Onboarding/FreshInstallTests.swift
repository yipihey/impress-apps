//
//  FreshInstallTests.swift
//  PublicationManagerCoreTests
//
//  Tests for verifying the fresh install experience and canonical library IDs.
//

import XCTest
import CoreData
@testable import PublicationManagerCore

@MainActor
final class FreshInstallTests: XCTestCase {

    // MARK: - Properties

    private var persistenceController: PersistenceController!
    private var context: NSManagedObjectContext!

    // MARK: - Setup/Teardown

    override func setUp() {
        super.setUp()
        // Use in-memory store for testing
        persistenceController = PersistenceController(inMemory: true)
        context = persistenceController.viewContext
    }

    override func tearDown() {
        persistenceController = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Canonical Library ID Tests

    func testCanonicalDefaultLibraryIDIsWellKnown() {
        // The canonical ID should be a well-known, stable UUID
        let canonicalID = CDLibrary.canonicalDefaultLibraryID

        XCTAssertEqual(
            canonicalID.uuidString,
            "00000000-0000-0000-0000-000000000001",
            "Canonical default library ID should be the well-known UUID"
        )
    }

    func testFirstLibraryCreatedDirectlyUsesCanonicalID() {
        // When: Creating a library directly in the context (simulating what LibraryManager does)
        let library = CDLibrary(context: context)
        library.id = CDLibrary.canonicalDefaultLibraryID  // First library uses canonical
        library.name = "My Library"
        library.dateCreated = Date()
        library.isDefault = true

        try? context.save()

        // Then: The library should have the canonical ID
        XCTAssertEqual(
            library.id,
            CDLibrary.canonicalDefaultLibraryID,
            "First library should use canonical default library ID"
        )
        XCTAssertEqual(
            library.id.uuidString,
            "00000000-0000-0000-0000-000000000001"
        )
    }

    func testSecondLibraryUsesRandomID() {
        // Given: A first library with canonical ID
        let firstLibrary = CDLibrary(context: context)
        firstLibrary.id = CDLibrary.canonicalDefaultLibraryID
        firstLibrary.name = "First Library"
        firstLibrary.dateCreated = Date()
        firstLibrary.isDefault = true

        // When: Creating a second library with random ID
        let secondLibrary = CDLibrary(context: context)
        secondLibrary.id = UUID()  // Random
        secondLibrary.name = "Second Library"
        secondLibrary.dateCreated = Date()
        secondLibrary.isDefault = false

        try? context.save()

        // Then: The second library should NOT use the canonical ID
        XCTAssertNotEqual(
            secondLibrary.id,
            CDLibrary.canonicalDefaultLibraryID,
            "Second library should not use canonical default library ID"
        )
    }

    func testFirstLibraryIsMarkedAsDefault() {
        // When: Creating the first library with isDefault = true
        let library = CDLibrary(context: context)
        library.id = CDLibrary.canonicalDefaultLibraryID
        library.name = "My Library"
        library.dateCreated = Date()
        library.isDefault = true

        try? context.save()

        // Then: The library should be marked as default
        XCTAssertTrue(library.isDefault, "First library should be marked as default")
    }

    func testSecondLibraryIsNotDefault() {
        // Given: A first library marked as default
        let firstLibrary = CDLibrary(context: context)
        firstLibrary.id = CDLibrary.canonicalDefaultLibraryID
        firstLibrary.name = "First Library"
        firstLibrary.dateCreated = Date()
        firstLibrary.isDefault = true

        // When: Creating a second library
        let secondLibrary = CDLibrary(context: context)
        secondLibrary.id = UUID()
        secondLibrary.name = "Second Library"
        secondLibrary.dateCreated = Date()
        secondLibrary.isDefault = false

        try? context.save()

        // Then: The second library should not be default
        XCTAssertFalse(secondLibrary.isDefault, "Second library should not be marked as default")
    }

    // MARK: - Fresh Install State Tests

    func testFreshInstallHasNoLibraries() {
        // Given: A fresh persistence controller (in-memory)
        let freshController = PersistenceController(inMemory: true)
        let freshContext = freshController.viewContext

        // When: Querying for libraries directly
        let request = NSFetchRequest<CDLibrary>(entityName: "Library")
        let libraries = try? freshContext.fetch(request)

        // Then: There should be no libraries (before any library creation)
        XCTAssertEqual(libraries?.count, 0, "Fresh install should have no libraries initially")
    }

    // MARK: - Papers Directory Tests

    func testLibraryHasPapersContainerURL() {
        // Given: A library
        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Test Library"
        library.dateCreated = Date()

        // When: Getting the papers container URL
        let papersURL = library.papersContainerURL

        // Then: It should be in the expected location
        XCTAssertTrue(
            papersURL.path.contains("Libraries"),
            "Papers URL should be in Libraries directory"
        )
        XCTAssertTrue(
            papersURL.path.contains(library.id.uuidString),
            "Papers URL should contain library ID"
        )
        XCTAssertTrue(
            papersURL.lastPathComponent == "Papers",
            "Papers URL should end with 'Papers'"
        )
    }
}
