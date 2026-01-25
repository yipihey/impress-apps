//
//  TestDataSeeder.swift
//  PublicationManagerCore
//
//  Seeds test data for UI tests when --uitesting-seed argument is present.
//

import Foundation
import CoreData
import OSLog

// MARK: - Test Data Seeder

/// Seeds the Core Data store with test data for UI testing.
///
/// When the app is launched with `--uitesting-seed`, this seeder populates
/// the database with sample libraries, publications, and other entities
/// to enable comprehensive UI testing.
///
/// ## Usage
///
/// In UI tests:
/// ```swift
/// let app = XCUIApplication()
/// app.launchArguments = ["--uitesting", "--uitesting-seed"]
/// app.launch()
/// ```
///
/// In app code (called during initialization):
/// ```swift
/// if UITestingEnvironment.shouldSeedTestData {
///     TestDataSeeder.seedIfNeeded(context: PersistenceController.shared.viewContext)
/// }
/// ```
public struct TestDataSeeder {

    // MARK: - Public Interface

    /// Seed test data if the `--uitesting-seed` argument is present.
    ///
    /// - Parameter context: The managed object context to seed data into
    public static func seedIfNeeded(context: NSManagedObjectContext) {
        guard UITestingEnvironment.shouldSeedTestData else {
            Logger.testing.debug("Test data seeding not requested")
            return
        }

        Logger.testing.info("Seeding test data for UI tests...")

        // Check for custom fixture name
        if let fixtureName = UITestingEnvironment.fixtureArgument {
            seedFixture(named: fixtureName, context: context)
        } else {
            seedDefaultTestData(context: context)
        }

        Logger.testing.info("Test data seeding complete")
    }

    // MARK: - Default Test Data

    /// Seed the default test data set
    private static func seedDefaultTestData(context: NSManagedObjectContext) {
        context.performAndWait {
            do {
                // Create a test library
                let library = CDLibrary(context: context)
                library.id = UUID()
                library.name = "Test Library"
                library.dateCreated = Date()
                library.isDefault = true

                // Create sample publications
                let publications = createSamplePublications(context: context, library: library)
                Logger.testing.debug("Created \(publications.count) sample publications")

                // Create a collection
                let collection = CDCollection(context: context)
                collection.id = UUID()
                collection.name = "Test Collection"
                collection.library = library
                collection.isSmartCollection = false

                // Add first few publications to collection
                var collectionPubs = collection.publications ?? []
                for pub in publications.prefix(3) {
                    collectionPubs.insert(pub)
                }
                collection.publications = collectionPubs

                // Save the context
                try context.save()
                Logger.testing.info("Saved default test data: 1 library, \(publications.count) publications, 1 collection")
            } catch {
                Logger.testing.error("Failed to seed default test data: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Custom Fixtures

    /// Seed data from a named fixture
    private static func seedFixture(named name: String, context: NSManagedObjectContext) {
        Logger.testing.info("Seeding fixture: \(name)")

        switch name {
        case "empty":
            // Empty database for testing first-run experience
            Logger.testing.debug("Empty fixture requested - no data seeded")

        case "large":
            // Large dataset for performance testing
            seedLargeDataset(context: context)

        case "minimal":
            // Minimal data for quick tests
            seedMinimalDataset(context: context)

        default:
            // Try to load from JSON fixture file
            if !loadJSONFixture(named: name, context: context) {
                Logger.testing.warning("Unknown fixture '\(name)', falling back to default")
                seedDefaultTestData(context: context)
            }
        }
    }

    /// Seed a large dataset for performance testing
    private static func seedLargeDataset(context: NSManagedObjectContext) {
        context.performAndWait {
            do {
                let library = CDLibrary(context: context)
                library.id = UUID()
                library.name = "Large Test Library"
                library.dateCreated = Date()
                library.isDefault = true

                // Create many publications
                for i in 1...500 {
                    let pub = CDPublication(context: context)
                    pub.id = UUID()
                    pub.citeKey = "LargeTest\(i)"
                    pub.entryType = "article"
                    pub.title = "Test Publication \(i): A Study of Performance Testing"
                    pub.year = Int16(2000 + (i % 25))
                    pub.abstract = "This is a test abstract for publication \(i). It contains sample text to test UI rendering performance with longer content."
                    pub.dateAdded = Date()
                    pub.dateModified = Date()
                    pub.addToLibrary(library)
                }

                try context.save()
                Logger.testing.info("Seeded large dataset: 500 publications")
            } catch {
                Logger.testing.error("Failed to seed large dataset: \(error.localizedDescription)")
            }
        }
    }

    /// Seed a minimal dataset for quick tests
    private static func seedMinimalDataset(context: NSManagedObjectContext) {
        context.performAndWait {
            do {
                let library = CDLibrary(context: context)
                library.id = UUID()
                library.name = "Minimal Test"
                library.dateCreated = Date()
                library.isDefault = true

                let pub = CDPublication(context: context)
                pub.id = UUID()
                pub.citeKey = "MinimalTest2024"
                pub.entryType = "article"
                pub.title = "Minimal Test Publication"
                pub.year = 2024
                pub.dateAdded = Date()
                pub.dateModified = Date()
                pub.addToLibrary(library)

                try context.save()
                Logger.testing.info("Seeded minimal dataset: 1 publication")
            } catch {
                Logger.testing.error("Failed to seed minimal dataset: \(error.localizedDescription)")
            }
        }
    }

    /// Try to load a JSON fixture file from the bundle
    private static func loadJSONFixture(named name: String, context: NSManagedObjectContext) -> Bool {
        // Look for fixture file in main bundle
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "TestFixtures") else {
            Logger.testing.debug("No JSON fixture file found: \(name).json")
            return false
        }

        do {
            let data = try Data(contentsOf: url)
            let fixture = try JSONDecoder().decode(TestFixture.self, from: data)
            applyFixture(fixture, context: context)
            return true
        } catch {
            Logger.testing.error("Failed to load JSON fixture '\(name)': \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sample Data Creation

    /// Create sample publications for testing
    private static func createSamplePublications(context: NSManagedObjectContext, library: CDLibrary) -> [CDPublication] {
        let sampleData: [(citeKey: String, title: String, year: Int16, authors: String)] = [
            ("Einstein1905", "On the Electrodynamics of Moving Bodies", 1905, "Albert Einstein"),
            ("Hawking1974", "Black hole explosions?", 1974, "Stephen Hawking"),
            ("Newton1687", "Philosophiae Naturalis Principia Mathematica", 1687, "Isaac Newton"),
            ("Darwin1859", "On the Origin of Species", 1859, "Charles Darwin"),
            ("Curie1898", "Sur une substance nouvelle radio-active", 1898, "Marie Curie"),
        ]

        var publications: [CDPublication] = []

        for (citeKey, title, year, authors) in sampleData {
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = citeKey
            pub.entryType = "article"
            pub.title = title
            pub.year = year
            pub.fields["author"] = authors
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.addToLibrary(library)
            publications.append(pub)
        }

        return publications
    }
}

// MARK: - Test Fixture Model

/// JSON-decodable test fixture structure
private struct TestFixture: Decodable {
    let libraries: [LibraryData]?
    let publications: [PublicationData]?

    struct LibraryData: Decodable {
        let name: String
        let isDefault: Bool?
    }

    struct PublicationData: Decodable {
        let citeKey: String
        let title: String
        let year: Int?
        let authors: String?
        let abstract: String?
        let doi: String?
        let entryType: String?
    }
}

/// Apply a decoded fixture to the context
private func applyFixture(_ fixture: TestFixture, context: NSManagedObjectContext) {
    context.performAndWait {
        do {
            // Create libraries
            var libraryMap: [String: CDLibrary] = [:]
            for (index, libraryData) in (fixture.libraries ?? []).enumerated() {
                let library = CDLibrary(context: context)
                library.id = UUID()
                library.name = libraryData.name
                library.dateCreated = Date()
                library.isDefault = libraryData.isDefault ?? (index == 0)
                libraryMap[libraryData.name] = library
            }

            // Create default library if none specified
            if libraryMap.isEmpty {
                let library = CDLibrary(context: context)
                library.id = UUID()
                library.name = "Test Library"
                library.dateCreated = Date()
                library.isDefault = true
                libraryMap["Test Library"] = library
            }

            let defaultLibrary = libraryMap.values.first { ($0.isDefault) } ?? libraryMap.values.first!

            // Create publications
            for pubData in fixture.publications ?? [] {
                let pub = CDPublication(context: context)
                pub.id = UUID()
                pub.citeKey = pubData.citeKey
                pub.entryType = pubData.entryType ?? "article"
                pub.title = pubData.title
                pub.year = Int16(pubData.year ?? 0)
                if let authors = pubData.authors {
                    pub.fields["author"] = authors
                }
                if let abstract = pubData.abstract {
                    pub.abstract = abstract
                }
                if let doi = pubData.doi {
                    pub.doi = doi
                }
                pub.dateAdded = Date()
                pub.dateModified = Date()
                pub.addToLibrary(defaultLibrary)
            }

            try context.save()
            Logger.testing.info("Applied JSON fixture: \(libraryMap.count) libraries, \(fixture.publications?.count ?? 0) publications")
        } catch {
            Logger.testing.error("Failed to apply fixture: \(error.localizedDescription)")
        }
    }
}
