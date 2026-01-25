//
//  UITestingConfiguration.swift
//  PublicationManagerCore
//
//  Configuration for UI testing mode.
//

import Foundation
import OSLog

// MARK: - UI Testing Configuration

/// Configuration for UI testing mode.
///
/// Provides detection of UI testing launch arguments and configuration
/// for running the app in test mode with mocked services and in-memory storage.
public struct UITestingConfiguration {

    // MARK: - Launch Arguments

    /// Argument to enable UI testing mode
    public static let uiTestingArg = "--ui-testing"

    /// Argument to reset app state before test
    public static let resetStateArg = "--reset-state"

    /// Argument to use mock services instead of real network calls
    public static let mockServicesArg = "--mock-services"

    /// Argument to enable accessibility testing mode
    public static let accessibilityTestingArg = "--accessibility-testing"

    /// Argument prefix for test data set selection
    public static let testDataSetArgPrefix = "--test-data-set="

    // MARK: - Detection

    /// Whether the app is running in UI testing mode
    public static var isUITesting: Bool {
        CommandLine.arguments.contains(uiTestingArg)
    }

    /// Whether to reset state on launch
    public static var shouldResetState: Bool {
        CommandLine.arguments.contains(resetStateArg)
    }

    /// Whether to use mock services
    public static var shouldUseMockServices: Bool {
        CommandLine.arguments.contains(mockServicesArg)
    }

    /// Whether accessibility testing is enabled
    public static var isAccessibilityTesting: Bool {
        CommandLine.arguments.contains(accessibilityTestingArg)
    }

    /// The test data set to load, if specified
    public static var testDataSet: String? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix(testDataSetArgPrefix) {
                return String(arg.dropFirst(testDataSetArgPrefix.count))
            }
        }
        return nil
    }

    // MARK: - Logging

    /// Log the current UI testing configuration
    public static func logConfiguration() {
        guard isUITesting else { return }

        Logger.app.info("UI Testing Mode: enabled")
        Logger.app.info("  Reset State: \(shouldResetState)")
        Logger.app.info("  Mock Services: \(shouldUseMockServices)")
        Logger.app.info("  Accessibility Testing: \(isAccessibilityTesting)")
        if let dataSet = testDataSet {
            Logger.app.info("  Test Data Set: \(dataSet)")
        }
    }
}

// MARK: - Test Data Seeding

extension UITestingConfiguration {

    /// Seed the database with test data based on the configured data set.
    ///
    /// - Parameter context: The Core Data context to seed
    @MainActor
    public static func seedTestDataIfNeeded() async {
        guard isUITesting, let dataSet = testDataSet else { return }

        Logger.app.info("Seeding test data for set: \(dataSet)")

        do {
            switch dataSet {
            case "empty":
                // No data to seed
                break

            case "basic":
                try await seedBasicData()

            case "large":
                try await seedLargeData()

            case "with-pdfs":
                try await seedDataWithPDFs()

            case "multi-library":
                try await seedMultiLibraryData()

            case "inbox-triage":
                try await seedInboxTriageData()

            default:
                Logger.app.warning("Unknown test data set: \(dataSet)")
            }

            Logger.app.info("Test data seeding complete")
        } catch {
            Logger.app.error("Failed to seed test data: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Seeding Implementations

    @MainActor
    private static func seedBasicData() async throws {
        let context = PersistenceController.shared.viewContext

        // Create a test library
        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Test Library"
        library.dateCreated = Date()
        library.isDefault = true

        // Create sample publications
        let publications = [
            ("Einstein1905", "On the Electrodynamics of Moving Bodies", 1905),
            ("Hawking1974", "Black hole explosions?", 1974),
            ("Turing1950", "Computing Machinery and Intelligence", 1950),
            ("Shannon1948", "A Mathematical Theory of Communication", 1948),
        ]

        for (citeKey, title, year) in publications {
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = citeKey
            pub.title = title
            pub.year = Int16(year)
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.addToLibrary(library)
        }

        try context.save()
    }

    @MainActor
    private static func seedLargeData() async throws {
        let context = PersistenceController.shared.viewContext

        // Create a test library
        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "Large Test Library"
        library.dateCreated = Date()
        library.isDefault = true

        // Create many publications
        for i in 1...500 {
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "Author\(i)_\(2000 + (i % 25))"
            pub.title = "Test Publication \(i): A Study in Testing"
            pub.year = Int16(2000 + (i % 25))
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.addToLibrary(library)
        }

        try context.save()
    }

    @MainActor
    private static func seedDataWithPDFs() async throws {
        // Basic data seeding - PDFs would need actual file handling
        try await seedBasicData()
        // Note: Actual PDF files cannot be created in UI tests easily
        // This just sets up the metadata structure
    }

    @MainActor
    private static func seedMultiLibraryData() async throws {
        let context = PersistenceController.shared.viewContext

        // Create multiple libraries
        let libraryNames = ["Physics", "Computer Science", "Mathematics"]

        for (index, name) in libraryNames.enumerated() {
            let library = CDLibrary(context: context)
            library.id = UUID()
            library.name = name
            library.dateCreated = Date()
            library.isDefault = index == 0
            library.sortOrder = Int16(index)

            // Create publications for each library
            for i in 1...10 {
                let pub = CDPublication(context: context)
                pub.id = UUID()
                pub.citeKey = "\(name.prefix(3))_\(i)_2024"
                pub.title = "\(name) Paper \(i)"
                pub.year = 2024
                pub.entryType = "article"
                pub.dateAdded = Date()
                pub.dateModified = Date()
                pub.addToLibrary(library)
            }

            // Create a collection
            let collection = CDCollection(context: context)
            collection.id = UUID()
            collection.name = "Important \(name)"
            collection.library = library
        }

        try context.save()
    }

    @MainActor
    private static func seedInboxTriageData() async throws {
        let context = PersistenceController.shared.viewContext

        // Create a default library
        let library = CDLibrary(context: context)
        library.id = UUID()
        library.name = "My Library"
        library.dateCreated = Date()
        library.isDefault = true

        // Create publications in inbox (with dateAddedToInbox set)
        for i in 1...20 {
            let pub = CDPublication(context: context)
            pub.id = UUID()
            pub.citeKey = "InboxPaper\(i)_2024"
            pub.title = "Inbox Paper \(i): Pending Triage"
            pub.year = 2024
            pub.entryType = "article"
            pub.dateAdded = Date()
            pub.dateModified = Date()
            pub.dateAddedToInbox = Date()
            pub.isRead = false
            pub.addToLibrary(library)
        }

        try context.save()
    }
}

// MARK: - Logger Extension

extension Logger {
    static let app = Logger(subsystem: "com.imbib.app", category: "app")
}
