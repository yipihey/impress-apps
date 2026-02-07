//
//  ImpartIOSApp.swift
//  impart-iOS
//
//  Main application entry point for impart on iOS.
//

import SwiftUI
import MessageManagerCore
import ImpressKit

// MARK: - iOS App Entry Point

@main
struct ImpartIOSApp: App {
    @State private var appState = IOSAppState()

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .environment(appState)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }

    private func handleURL(_ url: URL) {
        guard let parsed = ImpressURL.parse(url), parsed.app == .impart else { return }

        switch parsed.action {
        case "compose":
            // impart://compose?to=email&subject=...&body=...
            let to = parsed.parameters["to"]
            let subject = parsed.parameters["subject"]
            let body = parsed.parameters["body"]

            if let accountId = appState.selectedAccountId {
                appState.currentDraft = DraftMessage(
                    accountId: accountId,
                    to: to.map { [EmailAddress(email: $0)] } ?? [],
                    subject: subject ?? "",
                    body: body ?? ""
                )
                appState.isComposing = true
            }

        case "message":
            // impart://message?id=...
            if let messageIdString = parsed.parameters["id"],
               let messageId = UUID(uuidString: messageIdString) {
                appState.selectedMessageId = messageId
            }

        default:
            break
        }
    }
}

// MARK: - iOS App State

@MainActor @Observable
final class IOSAppState {
    /// Selected account ID
    var selectedAccountId: UUID?

    /// Selected mailbox ID
    var selectedMailboxId: UUID?

    /// Selected message ID
    var selectedMessageId: UUID?

    /// Whether compose sheet is showing
    var isComposing = false

    /// Current draft
    var currentDraft: DraftMessage?

    /// Navigation path
    var navigationPath = NavigationPath()
}
