//
//  ImpartIOSApp.swift
//  impart-iOS
//
//  Main application entry point for impart on iOS.
//

import SwiftUI
import MessageManagerCore

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
        guard url.scheme == "impart" else { return }

        switch url.host {
        case "compose":
            handleComposeURL(url)
        case "message":
            handleMessageURL(url)
        default:
            break
        }
    }

    private func handleComposeURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }

        var to: String?
        var subject: String?
        var body: String?

        for item in queryItems {
            switch item.name {
            case "to": to = item.value
            case "subject": subject = item.value
            case "body": body = item.value
            default: break
            }
        }

        if let accountId = appState.selectedAccountId {
            appState.currentDraft = DraftMessage(
                accountId: accountId,
                to: to.map { [EmailAddress(email: $0)] } ?? [],
                subject: subject ?? "",
                body: body ?? ""
            )
            appState.isComposing = true
        }
    }

    private func handleMessageURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let messageIdString = queryItems.first(where: { $0.name == "id" })?.value,
              let messageId = UUID(uuidString: messageIdString) else { return }

        appState.selectedMessageId = messageId
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
