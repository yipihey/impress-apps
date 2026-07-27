//
//  ImpartApp.swift
//  impart (macOS)
//
//  Main application entry point for impart on macOS.
//

import CoreData
import CoreSpotlight
import ImpressKit
import ImpressKeyboard
import ImpressSpotlight
import MessageManagerCore
import SwiftUI

// MARK: - App Entry Point

@main
struct ImpartApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    /// Stage 2-A flag-gated cutover: when set, the unified chassis
    /// (ImpartChassisRoot) becomes the DEFAULT window and the classic
    /// ContentView moves to a secondary "Mail (Classic)" window. Default
    /// off — mail is a daily driver and compose/reply aren't wired into the
    /// chassis yet, so the classic window stays primary (deliberate
    /// deviation from implore's replace-outright).
    private static let useChassisWindow =
        UserDefaults.standard.bool(forKey: "impart.useChassisWindow")

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

        // Prepare shared impress-core workspace (creates directory if needed).
        // Setup opens the store handle and declares the mail schemas
        // sync-excluded (IMAP is mail's own sync protocol).
        // ImpartStoreAdapter.shared.storeEmailMessage / storeChatMessage are safe
        // to call after this point.
        Task { @MainActor in
            ImpartStoreAdapter.shared.setup()

            // Stage 0 WP3: resumable Core Data → unified store backfill.
            // Sleeps ≥90 s internally before its first store mutation
            // (CLAUDE.md startup invariant), then pages CDMessages
            // oldest-first and checkpoints a watermark per batch.
            let persistence = PersistenceController.shared
            Task.detached(priority: .background) {
                await ImpartStoreBackfill.shared.startIfNeeded(persistence: persistence)
            }
        }

        // Spotlight indexing — deferred 90s per startup grace period
        Task.detached {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }

            let coordinator = SpotlightSyncCoordinator(provider: ImpartSpotlightProvider())
            await coordinator.initialRebuildIfNeeded()
            await coordinator.startObserving(
                mutationName: NSManagedObjectContext.didSaveObjectsNotification
            )
            await SpotlightBridge.shared.setCoordinator(coordinator)
        }
    }

    /// The classic three-column mail window content, with its long-standing
    /// lifecycle modifiers (heartbeat, Spotlight continuation, URL handling).
    private var classicRoot: some View {
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
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                _ = SpotlightDeepLinkHandler.handle(activity, currentApp: .impart) { uuid, _ in
                    NotificationCenter.default.post(
                        name: .showMessage,
                        object: nil,
                        userInfo: ["conversationID": uuid.uuidString]
                    )
                }
            }
            .onOpenURL { url in
                handleURL(url)
            }
    }

    /// The unified chassis (Stage 2-A): PMC's TabContentView on the Mail
    /// facet, with chat/research/development as custom surfaces.
    private var chassisRoot: some View {
        ImpartChassisRoot()
            .environment(appState)
            .withAppearance()
    }

    var body: some Scene {
        // Main window: classic mail by default; the unified chassis when the
        // "impart.useChassisWindow" flag is set (Stage 2-A gated cutover).
        WindowGroup {
            if Self.useChassisWindow {
                chassisRoot
            } else {
                classicRoot
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

            // Edit menu - context-aware pasteboard commands
            // When a text field has focus, use system clipboard; otherwise, use message clipboard
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .copyMessages, object: nil)
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("Cut") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                    }
                    // No cut for messages — messages can't be moved via clipboard
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Paste") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                    // No paste for messages — not applicable
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("Select All") {
                    if TextFieldFocusDetection.isTextFieldFocused() {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .selectAllMessages, object: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
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

        // Secondary window (Stage 2-A): whichever surface is NOT the default
        // gets a Window-menu entry — "Mail (Unified)" opens the chassis while
        // classic stays primary; with the flag flipped, "Mail (Classic)"
        // keeps the old window reachable (compose/reply live there).
        // One scene with conditional CONTENT — SceneBuilder rejects `if`.
        Window(
            Self.useChassisWindow ? "Mail (Classic)" : "Mail (Unified)",
            id: Self.useChassisWindow ? "mail-classic" : "mail-unified"
        ) {
            if Self.useChassisWindow {
                classicRoot
            } else {
                chassisRoot
            }
        }
        .defaultSize(width: 1100, height: 700)

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

    // Clipboard operations
    static let copyMessages = Notification.Name("com.impart.copyMessages")
    static let selectAllMessages = Notification.Name("com.impart.selectAllMessages")
}
