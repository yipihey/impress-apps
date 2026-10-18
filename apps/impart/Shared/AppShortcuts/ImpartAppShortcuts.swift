//
//  ImpartAppShortcuts.swift
//  impart
//
//  impart's App Shortcuts (Siri phrases, Spotlight actions). The provider
//  lives in the app target because App Intents metadata extraction reads an
//  AppShortcutsProvider only from the app's own sources: kept in MessageManagerCore it
//  was exported by no app (`autoShortcuts: 0`, 2026-10-18). The intents it
//  names stay in MessageManagerCore.
//

import AppIntents
import Foundation
import MessageManagerCore

@available(macOS 14.0, iOS 17.0, *)
public struct ImpartShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchMessagesIntent(),
            phrases: [
                "Search \(.applicationName) messages",
                "Find messages in \(.applicationName)"
            ],
            shortTitle: "Search Messages",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ComposeMessageIntent(),
            phrases: [
                "Compose message in \(.applicationName)",
                "Send email with \(.applicationName)"
            ],
            shortTitle: "Compose Message",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: ListConversationsIntent(),
            phrases: [
                "List \(.applicationName) conversations",
                "Show my \(.applicationName) conversations"
            ],
            shortTitle: "List Conversations",
            systemImageName: "bubble.left.and.bubble.right"
        )

        AppShortcut(
            intent: NavigateImpartIntent(),
            phrases: [
                "Go to \(.applicationName) inbox",
                "Show my \(.applicationName) inbox"
            ],
            shortTitle: "Go to Inbox",
            systemImageName: "tray"
        )
    }
}
