//
//  LibraryFilesMigrationRunner.swift
//  PublicationManagerCore
//
//  Runs `LibraryFilesMigration` once per imbib launch, off the main thread.
//  It is a no-op after the first run (every file already present, checked by
//  size), and it picks up anything an older build wrote to the private root
//  since. File copies post no store event, so this does not need the 90-s
//  startup gate the store-mutating services wait on.
//
//  Switches, for a cautious first run on a real library:
//    IMBIB_LIBRARY_FILES_MIGRATION=dry-run   (or =off)       environment
//    defaults write <imbib bundle id> libraryFilesMigration dry-run   (or off)
//

import Foundation
import OSLog

@MainActor
public enum LibraryFilesMigrationRunner {

    public enum Mode: String, Sendable {
        case run, dryRun = "dry-run", off
    }

    private static var task: Task<LibraryFilesMigration.Summary?, Never>?

    public static var configuredMode: Mode {
        let raw = ProcessInfo.processInfo.environment["IMBIB_LIBRARY_FILES_MIGRATION"]
            ?? UserDefaults.standard.string(forKey: "libraryFilesMigration")
        return raw.flatMap(Mode.init(rawValue:)) ?? .run
    }

    /// Start the migration (once per process). Call from imbib's launch only:
    /// imbib is the one app whose private container holds library files.
    public static func start(mode: Mode = configuredMode) {
        guard task == nil else { return }
        guard mode != .off else {
            Logger.files.infoCapture("library files migration is off (libraryFilesMigration=off)", category: "files-migration")
            return
        }
        let migration = LibraryFilesMigration(dryRun: mode == .dryRun)
        Logger.files.infoCapture(
            "library files migration \(mode.rawValue): \(migration.source.path) → \(migration.destination.path)",
            category: "files-migration")
        task = Task.detached(priority: .utility) {
            migration.run()
        }
    }

    /// Wait for a started migration; returns at once if none was started.
    @discardableResult
    public static func waitUntilDone() async -> LibraryFilesMigration.Summary? {
        guard let task else { return nil }
        return await task.value
    }
}
