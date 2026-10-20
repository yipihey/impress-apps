//
//  ImpelAppShortcuts.swift
//  impel
//
//  impel's App Shortcuts (Siri phrases, Spotlight actions). The provider
//  lives in the app target because App Intents metadata extraction reads an
//  AppShortcutsProvider only from the app's own sources: kept in ImpelCore it
//  was exported by no app (`autoShortcuts: 0`, 2026-10-18). The intents it
//  names stay in ImpelCore.
//

import AppIntents
import Foundation
import ImpelCore

@available(macOS 14.0, *)
public struct ImpelShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskCounselIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Research with \(.applicationName)"
            ],
            shortTitle: "Ask Counsel",
            systemImageName: "brain"
        )

        AppShortcut(
            intent: ListThreadsIntent(),
            phrases: [
                "List \(.applicationName) threads",
                "Show agent threads in \(.applicationName)"
            ],
            shortTitle: "List Threads",
            systemImageName: "list.bullet"
        )

        AppShortcut(
            intent: CreateThreadIntent(),
            phrases: [
                "Create thread in \(.applicationName)",
                "Start agent in \(.applicationName)"
            ],
            shortTitle: "New Thread",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: GetSuiteStatusIntent(),
            phrases: [
                "Check \(.applicationName) suite status",
                "Get \(.applicationName) suite status"
            ],
            shortTitle: "Suite Status",
            systemImageName: "chart.bar"
        )
    }
}
