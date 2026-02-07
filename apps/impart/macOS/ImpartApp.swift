//
//  ImpartApp.swift
//  impart (macOS)
//
//  Main application entry point for impart on macOS.
//

import SwiftUI
import MessageManagerCore
import ImpressKit

// MARK: - App Entry Point

@main
struct ImpartApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Register default settings (HTTP automation enabled by default for MCP)
        UserDefaults.standard.register(defaults: [
            "httpAutomationEnabled": true,
            "httpAutomationPort": 23122
        ])

        // Start HTTP automation server for AI/MCP integration
        Task { @MainActor in
            await ImpartHTTPServer.shared.start()
        }
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environment(appState)
                .withAppearance()
                .task {
                    // Start heartbeat for SiblingDiscovery
                    Task.detached {
                        while !Task.isCancelled {
                            ImpressNotification.postHeartbeat(from: .impart)
                            try? await Task.sleep(for: .seconds(25))
                        }
                    }
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    NotificationCenter.default.post(name: .composeMessage, object: nil)
                }
                .keyboardShortcut("N", modifiers: [.command])

                Divider()

                Button("Check for New Mail") {
                    NotificationCenter.default.post(name: .checkMail, object: nil)
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }

            // Message menu
            CommandMenu("Message") {
                Button("Reply") {
                    NotificationCenter.default.post(name: .replyToMessage, object: nil)
                }
                .keyboardShortcut("R", modifiers: [.command])

                Button("Reply All") {
                    NotificationCenter.default.post(name: .replyAllToMessage, object: nil)
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])

                Button("Forward") {
                    NotificationCenter.default.post(name: .forwardMessage, object: nil)
                }
                .keyboardShortcut("F", modifiers: [.command, .shift])

                Divider()

                Button("Mark as Read") {
                    NotificationCenter.default.post(name: .markAsRead, object: nil)
                }
                .keyboardShortcut("U", modifiers: [.command, .shift])

                Button("Mark as Unread") {
                    NotificationCenter.default.post(name: .markAsUnread, object: nil)
                }

                Divider()

                Button("Archive") {
                    NotificationCenter.default.post(name: .archiveMessage, object: nil)
                }
                .keyboardShortcut("E", modifiers: [.command])

                Button("Delete") {
                    NotificationCenter.default.post(name: .deleteMessage, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }

            // View menu additions
            CommandGroup(after: .sidebar) {
                Button("Show Mailboxes") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command])

                Divider()

                Picker("View Mode", selection: $appState.viewMode) {
                    Text("Messages").tag(ViewMode.messages)
                    Text("Threads").tag(ViewMode.threads)
                }

                Divider()

                Button("Show Console") {
                    openWindow(id: "console")
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
            }
        }

        // Settings window
        #if os(macOS)
        Settings {
            SettingsView()
        }

        // Console window (Cmd+Shift+C)
        Window("Console", id: "console") {
            ConsoleView()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .defaultSize(width: 800, height: 400)
        #endif
    }

    private func handleURL(_ url: URL) {
        guard let parsed = ImpressURL.parse(url), parsed.app == .impart else { return }

        switch parsed.action {
        case "compose":
            // impart://compose?to=email&subject=...&body=...
            NotificationCenter.default.post(
                name: .composeMessage,
                object: nil,
                userInfo: parsed.parameters as [String: Any]
            )

        case "message":
            // impart://message?id=...
            if let messageId = parsed.parameters["id"] {
                NotificationCenter.default.post(
                    name: .showMessage,
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
            }

        default:
            break
        }
    }
}

// MARK: - App State

/// Global application state
@MainActor @Observable
final class AppState {
    /// Current view mode
    var viewMode: ViewMode = .threads

    /// Selected account ID
    var selectedAccountId: UUID?

    /// Selected mailbox ID
    var selectedMailboxId: UUID?

    /// Selected message IDs
    var selectedMessageIds: Set<UUID> = []

    /// Whether compose sheet is showing
    var isComposing = false

    /// Draft being composed
    var currentDraft: DraftMessage?
}

/// View mode for message list
enum ViewMode: String, CaseIterable {
    case messages = "messages"
    case threads = "threads"
}

// MARK: - Appearance Modifier

struct AppearanceModifier: ViewModifier {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        content.preferredColorScheme(colorScheme)
    }
}

extension View {
    func withAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let composeMessage = Notification.Name("composeMessage")
    static let checkMail = Notification.Name("checkMail")
    static let replyToMessage = Notification.Name("replyToMessage")
    static let replyAllToMessage = Notification.Name("replyAllToMessage")
    static let forwardMessage = Notification.Name("forwardMessage")
    static let markAsRead = Notification.Name("markAsRead")
    static let markAsUnread = Notification.Name("markAsUnread")
    static let archiveMessage = Notification.Name("archiveMessage")
    static let deleteMessage = Notification.Name("deleteMessage")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let showMessage = Notification.Name("showMessage")
}
