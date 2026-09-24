//
//  LibraryFilesLocation.swift
//  PublicationManagerCore
//
//  Where a library's files live — for every suite app, not just imbib.
//
//  Until 2026-09-24 the root was `<Application Support>/imbib`, and under the
//  App Sandbox Application Support is the APP's own container: imbib wrote
//  `~/Library/Containers/com.impress.imbib/…/imbib/Libraries/<id>/Papers/…`,
//  and impress, imprint's papers window and the tree's `pdf` pane — the same
//  PublicationManagerCore code running in another sandbox — looked under
//  their own containers, where nothing is. Every library PDF read "not found"
//  outside imbib. The store was already shared through the suite app group
//  (`SharedWorkspace.databasePath`); the files now sit beside it, in the one
//  directory every suite app is entitled to read.
//
//  The layout under the root is unchanged — `Libraries/<library id>/<relative
//  path>` — so a linked file's `relativePath` (and the rule that a paper's
//  files live under the paper's OWN library) means what it always meant; only
//  the root moved. The old per-app root is kept as the LEGACY root: resolvers
//  still look there, and `LibraryFilesMigration` copies its files across.
//

import Foundation
import ImpressKit

public enum LibraryFilesLocation {

    /// The shared root: `<suite group>/workspace/imbib`. Readable by every app
    /// in the suite app group (imbib, impress, imprint, impart, impel,
    /// implore on macOS; `group.com.impress.suite` on iOS).
    public static var sharedRoot: URL {
        SharedWorkspace.workspaceDirectory.appendingPathComponent("imbib", isDirectory: true)
    }

    /// The pre-2026-09-24 root: this app's own `<Application Support>/imbib`.
    /// Only imbib ever wrote here, so only imbib's copy of it has files; in any
    /// other app it is an empty directory in that app's container.
    /// Under unit tests (as `SharedWorkspace` does) it is a per-process temp
    /// directory: an unsandboxed xctest's Application Support is the user's
    /// real one, and a test must never read or delete a real library file.
    public static var legacyRoot: URL {
        if ImpressRuntime.isUnitTestProcess {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("impress-unit-tests-\(ProcessInfo.processInfo.processIdentifier)")
                .appendingPathComponent("legacy-imbib", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("imbib", isDirectory: true)
    }

    /// `<root>/Libraries/<library id>` — a library's container under a root.
    public static func libraryContainer(_ libraryID: UUID, under root: URL) -> URL {
        root.appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(libraryID.uuidString, isDirectory: true)
    }
}
