//
//  UITestingEnvironment.swift
//  PublicationManagerCore
//
//  Centralized environment configuration for UI tests.
//  Provides sandboxed Core Data store, isolated UserDefaults, and test data seeding.
//

import Foundation
import OSLog

// MARK: - UI Testing Environment

/// Centralized detection and configuration for UI testing mode.
///
/// When the app is launched with `--uitesting`, this environment provides:
/// - **Isolated Core Data store**: Temporary directory, cleaned up between test runs
/// - **CloudKit disabled**: No iCloud sync during tests
/// - **Separate UserDefaults suite**: Isolated preferences
/// - **Optional test data seeding**: Via `--uitesting-seed` argument
///
/// ## Usage
/// In UI tests:
/// ```swift
/// let app = XCUIApplication()
/// app.launchArguments = ["--uitesting"]
/// app.launch()
/// ```
///
/// In app code:
/// ```swift
/// if UITestingEnvironment.isUITesting {
///     // Use test configuration
/// }
/// ```
public enum UITestingEnvironment {

    // MARK: - Detection

    /// Whether the app was launched in UI testing mode.
    public static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// Whether test data should be seeded on launch.
    public static var shouldSeedTestData: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-seed")
    }

    /// Get custom fixture name from launch arguments (e.g., `--uitesting-fixture=large`).
    public static var fixtureArgument: String? {
        for argument in ProcessInfo.processInfo.arguments {
            if argument.hasPrefix("--uitesting-fixture=") {
                return String(argument.dropFirst("--uitesting-fixture=".count))
            }
        }
        return nil
    }

    // MARK: - Paths

    /// Directory for UI test data (Core Data store, caches, etc.).
    public static var testDataDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("imbib-uitests", isDirectory: true)
    }

    /// URL for the Core Data SQLite store during UI tests.
    public static var testStoreURL: URL {
        testDataDirectory.appendingPathComponent("store.sqlite")
    }

    /// UserDefaults suite name for UI tests.
    /// Returns nil when not in UI testing mode (use standard defaults).
    public static var userDefaultsSuiteName: String? {
        isUITesting ? "com.imbib.app.uitesting" : nil
    }

    // MARK: - Cleanup

    /// Remove the test data directory to start with a clean slate.
    /// Call this at the start of each test run.
    public static func cleanupTestStore() {
        let fileManager = FileManager.default
        let directory = testDataDirectory

        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
                Logger.testing.info("Cleaned up UI test data directory: \(directory.path)")
            } catch {
                Logger.testing.error("Failed to clean up UI test data: \(error.localizedDescription)")
            }
        }
    }

    /// Ensure the test data directory exists.
    public static func ensureTestDirectoryExists() {
        let fileManager = FileManager.default
        let directory = testDataDirectory

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                Logger.testing.info("Created UI test data directory: \(directory.path)")
            } catch {
                Logger.testing.error("Failed to create UI test data directory: \(error.localizedDescription)")
            }
        }
    }

    /// Clean up test UserDefaults suite.
    public static func cleanupTestUserDefaults() {
        guard let suiteName = userDefaultsSuiteName,
              let testDefaults = UserDefaults(suiteName: suiteName) else {
            return
        }

        // Remove all keys from the test suite
        for key in testDefaults.dictionaryRepresentation().keys {
            testDefaults.removeObject(forKey: key)
        }
        testDefaults.synchronize()

        Logger.testing.info("Cleaned up UI test UserDefaults suite: \(suiteName)")
    }

    /// Perform full cleanup for a fresh test run.
    public static func performFullCleanup() {
        cleanupTestStore()
        cleanupTestUserDefaults()
        Logger.testing.info("Full UI test cleanup complete")
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    /// Get the appropriate UserDefaults instance for the current environment.
    /// Returns a sandboxed suite when in UI testing mode, standard defaults otherwise.
    public static var forCurrentEnvironment: UserDefaults {
        if let suiteName = UITestingEnvironment.userDefaultsSuiteName,
           let testDefaults = UserDefaults(suiteName: suiteName) {
            return testDefaults
        }
        return .standard
    }
}

// MARK: - Logger Extension

extension Logger {
    static let testing = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "testing")
}
