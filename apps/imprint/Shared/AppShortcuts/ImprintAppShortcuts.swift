//
//  ImprintAppShortcuts.swift
//  imprint
//
//  imprint's App Shortcuts (Siri phrases, Spotlight actions). The provider
//  lives in the app target because App Intents metadata extraction reads an
//  AppShortcutsProvider only from the app's own sources: kept in ImprintCore it
//  was exported by no app (`autoShortcuts: 0`, 2026-10-18). The intents it
//  names live in ImprintAppIntents.
//

import AppIntents
import Foundation
import ImprintAppIntents
import ImprintCore

@available(macOS 14.0, iOS 17.0, *)
public struct ImprintShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListDocumentsIntent(),
            phrases: [
                "List my \(.applicationName) documents",
                "Show \(.applicationName) documents"
            ],
            shortTitle: "List Documents",
            systemImageName: "doc.text"
        )

        AppShortcut(
            intent: CreateDocumentIntent(),
            phrases: [
                "Create a new \(.applicationName) document",
                "New document in \(.applicationName)"
            ],
            shortTitle: "New Document",
            systemImageName: "doc.badge.plus"
        )

        AppShortcut(
            intent: CompileDocumentIntent(),
            phrases: [
                "Compile \(.applicationName) document",
                "Build PDF in \(.applicationName)"
            ],
            shortTitle: "Compile to PDF",
            systemImageName: "doc.richtext"
        )

        AppShortcut(
            intent: InsertCitationIntent(),
            phrases: [
                "Insert citation in \(.applicationName)",
                "Add citation to \(.applicationName) document"
            ],
            shortTitle: "Insert Citation",
            systemImageName: "quote.opening"
        )

        AppShortcut(
            intent: ListVeuszPlotsIntent(),
            phrases: [
                "List \(.applicationName) plots",
                "Show Veusz plots in \(.applicationName)"
            ],
            shortTitle: "List Plots",
            systemImageName: "chart.xyaxis.line"
        )

        AppShortcut(
            intent: OpenVeuszPlotIntent(),
            phrases: [
                "Open Veusz plot in \(.applicationName)",
                "Edit Veusz plot in \(.applicationName)"
            ],
            shortTitle: "Edit Plot in Veusz",
            systemImageName: "chart.line.uptrend.xyaxis"
        )

        AppShortcut(
            intent: CreateVeuszPlotIntent(),
            phrases: [
                "Create a Veusz plot in \(.applicationName)",
                "New plot in \(.applicationName)"
            ],
            shortTitle: "New Veusz Plot",
            systemImageName: "chart.bar.doc.horizontal"
        )
    }
}
