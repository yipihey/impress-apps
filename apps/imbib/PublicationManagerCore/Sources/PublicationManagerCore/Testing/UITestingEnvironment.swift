//
//  UITestingEnvironment.swift
//  PublicationManagerCore
//
//  Centralized environment configuration for UI tests.
//  Provides sandboxed Core Data store, isolated UserDefaults, and test data seeding.
//

import Foundation
import ImpressKit
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
    ///
    /// Accepts both spellings: `RustStoreAdapter`, `LibraryManager`, and
    /// `TestApp` gate the in-memory store on `--ui-testing`, while earlier
    /// helpers here used `--uitesting`. Honoring both keeps the in-memory
    /// store switch and this environment on the same flag (they were
    /// silently divergent before).
    public static var isUITesting: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--uitesting") || args.contains("--ui-testing")
    }

    /// Whether test data should be seeded on launch.
    public static var shouldSeedTestData: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--uitesting-seed") || args.contains("--ui-testing-seed")
    }

    /// The ONE database a UI-test launch uses.
    ///
    /// **Why a file and not `openInMemory()`.** Two in-memory opens are two
    /// DATABASES, not two handles on one — the lesson `RustStoreAdapter`'s own
    /// init comment records as "the imprint seed lesson". Production has one
    /// database with several handles on it (`ImbibStore` and `SharedStore` both
    /// open `SharedWorkspace.databasePath`), and a UI-test topology that
    /// differs there does not test production: ADR-0023's provenance write
    /// failed under UI testing for exactly this reason, with the publications
    /// in one store and the `watched-file` rows in another, and the kernel
    /// correctly refusing to attribute rows it could not see.
    ///
    /// Per PROCESS, so each launch is still a fresh, empty store — the property
    /// the in-memory choice was actually buying — and never the app-group
    /// container, which is what it was avoiding.
    public static var scratchDatabasePath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-ui-tests-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("impress.sqlite")
            .path
    }

    /// Create the scratch database's directory. Safe to call repeatedly.
    public static func prepareScratchDatabaseDirectory() {
        let directory = URL(fileURLWithPath: scratchDatabasePath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Whether to seed a WATCHED FOLDER (ADR-0023 W2) on launch.
    ///
    /// The folder and its `.bib` are created inside the app's own container,
    /// because an XCUITest runs in a different process with a different sandbox
    /// and cannot write into the app's. Everything after the directory exists
    /// is the real path: the same `WatchedFolderIngestCoordinator.addFolder`
    /// the `fileImporter` calls, the same bookmark, the same ingest loop.
    public static var shouldSeedWatchedFolder: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-watched-folder")
    }

    /// Whether to APPEND an entry to the seeded `.bib` before watching starts.
    ///
    /// The second half of the live-drop proof: relaunch with this flag, the
    /// file on disk has one more entry than imbib last saw, and the re-scan has
    /// to notice by content hash — the same code path an editor's save takes.
    public static var shouldAppendToWatchedFolder: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting-watched-folder-append")
    }

    /// The seeded watched folder, inside the app container. Stable across
    /// launches of one UI-test session, which is what makes the append work.
    public static var watchedFolderSeedDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uitest-watched", isDirectory: true)
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
        // Unit tests: hand each xctest worker PROCESS its own suite. Falling
        // through to `.standard` (a real, cross-process store) makes parallel
        // workers clobber each other's settings via CFPreferences' incoherent
        // cross-process cache — flaky persistence tests. A per-process suite
        // isolates workers while still letting multiple store instances in the
        // SAME process share state (so persistence-across-instances holds).
        if ImpressRuntime.isUnitTestProcess {
            let pid = ProcessInfo.processInfo.processIdentifier
            if let perProcess = UserDefaults(suiteName: "com.imbib.unittest.\(pid)") {
                return perProcess
            }
        }
        return .standard
    }
}

// MARK: - Logger Extension

extension Logger {
    static let testing = Logger(subsystem: "com.imbib.PublicationManagerCore", category: "testing")
}
