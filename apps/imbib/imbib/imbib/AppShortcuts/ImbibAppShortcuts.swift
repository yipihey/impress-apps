//
//  ImbibAppShortcuts.swift
//  imbib
//
//  imbib's App Shortcuts (Siri phrases, Spotlight actions). The provider
//  lives in the app target because App Intents metadata extraction reads an
//  AppShortcutsProvider only from the app's own sources: kept in ImbibAppIntents it
//  was exported by no app (`autoShortcuts: 0`, 2026-10-18). The intents it
//  names stay in ImbibAppIntents.
//

import AppIntents
import Foundation
import ImbibAppIntents

@available(iOS 16.0, macOS 13.0, *)
public struct ImbibShortcuts: AppShortcutsProvider {

    public static var appShortcuts: [AppShortcut] {
        // Search Papers - phrases can't use String parameter interpolation
        // User will be prompted for query after invoking the shortcut
        AppShortcut(
            intent: SearchPapersIntent(),
            phrases: [
                "Search \(.applicationName) for papers",
                "Find papers in \(.applicationName)",
                "Search papers with \(.applicationName)"
            ],
            shortTitle: "Search Papers",
            systemImageName: "magnifyingglass"
        )

        // Search Library
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: [
                "Search my \(.applicationName) library",
                "Find papers in my \(.applicationName) library"
            ],
            shortTitle: "Search Library",
            systemImageName: "book.closed"
        )

        // Add papers by identifier: the generated intent for
        // imbib-library-service_import-identifiers (VerbIntents/).
        AppShortcut(
            intent: ImbibLibraryImportIdentifiersIntent(),
            phrases: [
                "Add papers to \(.applicationName)",
                "Import papers to \(.applicationName)"
            ],
            shortTitle: "Add Papers",
            systemImageName: "plus.circle"
        )

        // Show Inbox
        AppShortcut(
            intent: ShowInboxIntent(),
            phrases: [
                "Show my \(.applicationName) inbox",
                "Open \(.applicationName) inbox",
                "Check \(.applicationName) inbox"
            ],
            shortTitle: "Show Inbox",
            systemImageName: "tray"
        )

        // Show Library
        AppShortcut(
            intent: ShowLibraryIntent(),
            phrases: [
                "Show my \(.applicationName) library",
                "Open \(.applicationName) library",
                "Show my papers in \(.applicationName)"
            ],
            shortTitle: "Show Library",
            systemImageName: "books.vertical"
        )

        // Mark All Read
        AppShortcut(
            intent: MarkAllReadIntent(),
            phrases: [
                "Mark all papers as read in \(.applicationName)",
                "Mark everything read in \(.applicationName)"
            ],
            shortTitle: "Mark All Read",
            systemImageName: "checkmark.circle"
        )

        // Refresh Data
        AppShortcut(
            intent: RefreshDataIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Sync \(.applicationName)",
                "Update \(.applicationName) data"
            ],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )

        // Create Artifact
        AppShortcut(
            intent: CreateArtifactIntent(),
            phrases: [
                "Create artifact in \(.applicationName)",
                "Save research artifact in \(.applicationName)",
                "Capture artifact with \(.applicationName)"
            ],
            shortTitle: "Create Artifact",
            systemImageName: "archivebox.fill"
        )

        // Search Artifacts
        AppShortcut(
            intent: SearchArtifactsIntent(),
            phrases: [
                "Search artifacts in \(.applicationName)",
                "Find research artifacts in \(.applicationName)"
            ],
            shortTitle: "Search Artifacts",
            systemImageName: "magnifyingglass"
        )

    }
}
