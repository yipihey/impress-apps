//
//  ImploreAppShortcuts.swift
//  implore
//
//  implore's App Shortcuts (Siri phrases, Spotlight actions). The provider
//  lives in the app target because App Intents metadata extraction reads an
//  AppShortcutsProvider only from the app's own sources: kept in ImploreCore it
//  was exported by no app (`autoShortcuts: 0`, 2026-10-18). The intents it
//  names stay in ImploreCore.
//

import AppIntents
import Foundation
import ImploreCore

@available(macOS 14.0, *)
public struct ImploreShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListFiguresIntent(),
            phrases: [
                "List my \(.applicationName) figures",
                "Show \(.applicationName) figures"
            ],
            shortTitle: "List Figures",
            systemImageName: "chart.xyaxis.line"
        )

        AppShortcut(
            intent: ExportFigureIntent(),
            phrases: [
                "Export \(.applicationName) figure",
                "Save figure from \(.applicationName)"
            ],
            shortTitle: "Export Figure",
            systemImageName: "square.and.arrow.up"
        )

        AppShortcut(
            intent: CreateFigureIntent(),
            phrases: [
                "Create figure in \(.applicationName)",
                "New visualization in \(.applicationName)"
            ],
            shortTitle: "New Figure",
            systemImageName: "plus.circle"
        )
    }
}
