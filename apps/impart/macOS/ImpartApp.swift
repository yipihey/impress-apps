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
import ImpressTheme
import MessageManagerCore
import PublicationManagerCore
import SwiftUI

// MARK: - App Entry Point

@main
struct ImpartApp: App {
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Register default settings (HTTP automation enabled by default for MCP)
        UserDefaults.standard.register(defaults: [
            "httpAutomationEnabled": true,
            // THE sibling-app table (ImpressKit) — never a second literal.
            "httpAutomationPort": Int(ImpartHTTPServer.defaultPort)
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

    /// impart's window: the unified chassis (PMC's `TabContentView` on the Mail
    /// facet) with chat / category / research / development as custom surfaces,
    /// plus `MailChassisHost` for the verbs only impart can perform (compose,
    /// reply/forward, mark-read on select, check-mail).
    ///
    /// Stage 4c: this is now the ONLY root. The classic three-column
    /// `ContentView` and the `impart.useChassisWindow` flag are deleted, and the
    /// flag is not kept as a kill switch because it could only restore a
    /// STRICTLY POORER window: the classic mail lists were permanently empty —
    /// `InboxViewModel.loadMessages()` is never called on macOS (only
    /// `IOSContentView` assigns `selectedMailbox`), `viewModel.accounts` is
    /// `private(set)` and assigned nowhere, and `loadFolders(for:)` has no
    /// caller — so its sidebar showed one row and its lists showed nothing, on
    /// every launch. Its lifecycle modifiers (heartbeat, Spotlight continuation,
    /// URL handling) move here unchanged.
    private var chassisRoot: some View {
        ImpartChassisRoot()
            .withAppearance()
            .modifier(MailChassisHost())
            // AFTER MailChassisHost, so the host sits INSIDE the injection —
            // its `@Environment(AppState.self)` traps at launch otherwise
            // (environment values flow down; a modifier applied after
            // `.environment` wraps it and cannot see the value).
            .environment(appState)
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

    var body: some Scene {
        WindowGroup {
            chassisRoot
        }
        .commands {
            // File menu
            //
            // Stage 4c shortcut correction: every chord in this block and the
            // Message menu below was written with a CAPITAL key literal and no
            // `.shift` — and in SwiftUI a capital letter IMPLIES Shift, so
            // `keyboardShortcut("N", modifiers: [.command])` registered ⌘⇧N, not
            // the ⌘N the menu displayed. That was invisible while these items
            // posted into a window that ignored them; now that they all have
            // observers, the chords have to be the ones docs/keyboard-grammar.md
            // and the menu titles claim.
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    NotificationCenter.default.post(name: .composeMessage, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                // Moved off ⌘⇧R, which Reply All owns (keyboard-grammar.md).
                // The two were bound to the same chord — one File, one Message —
                // plus the classic toolbar's refresh button, and AppKit picked a
                // winner unpredictably. ⌘⇧N is Mail.app's "Get New Mail".
                Button("Check for New Mail") {
                    NotificationCenter.default.post(name: .checkMail, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            // Message menu
            CommandMenu("Message") {
                Button("Reply") {
                    NotificationCenter.default.post(name: .replyToMessage, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Reply All") {
                    NotificationCenter.default.post(name: .replyAllToMessage, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Forward") {
                    NotificationCenter.default.post(name: .forwardMessage, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Divider()

                Button("Mark as Read") {
                    NotificationCenter.default.post(name: .markAsRead, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Mark as Unread") {
                    NotificationCenter.default.post(name: .markAsUnread, object: nil)
                }

                Divider()

                // Archive and Delete are the two items Stage 4c did NOT wire, and
                // deliberately: both are IMAP MOVES, and mail's lifecycle being
                // IMAP-owned is exactly why `MessageRecordKind.descriptor`
                // declares `dismissal: .none` / `deletion: .none` and the chassis
                // list ignores `d` (docs/chassis-capability-matrix.md, "Mail
                // IMAP-owned gaps"). They post into nothing, as they did before —
                // wiring them means an IMAP move path, not an observer.
                Button("Archive") {
                    NotificationCenter.default.post(name: .archiveMessage, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])

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
                // Stage 4c: "Show Mailboxes" posted `.toggleSidebar`, which had no
                // observer anywhere in impart — and it held ⌘0, which the chassis
                // advertises as the detail-pane toggle (`MessageSectionView`,
                // TabContentView's list button help text). Left in place it would
                // have SHADOWED a working chord with a dead one. Replaced by the
                // three declarative pane commands imbib and imprint already
                // declare over the same `PaneLayoutStore` — the chassis reads it,
                // impart just never spoke to it.
                // …and since ADR-0022 X2 (D9 finding 4) those three commands
                // are the CHASSIS's, not a fourth hand-written copy of them.
                // Embedded as content rather than inserted as a `Commands`
                // value so they keep their position in this group, ahead of the
                // ⌘1-5 view-mode accelerators below.
                ImpressPaneLayoutButtons()

                Divider()

                // Stage 4c: the ⌘1-5 view-mode accelerators, as MENU COMMANDS.
                //
                // They were never really bound before. `ContentView` carried
                // `.keyboardShortcut("1"…"5")` on a *view* (inert — the modifier
                // needs a Button), and the real path was ⌘1-3 → the keyboard
                // store → `switchTo{Email,Chat,Category}View`, with ⌘4/⌘5
                // falling through to a local switch. Only three of the five had
                // a store binding at all, and every one of them died with the
                // window that observed it.
                //
                // As commands they need no focused view, they appear in the menu
                // bar (discoverable), and they cover all five modes. The
                // notification names are UNCHANGED, so a user's customised
                // keyboard-store bindings still reach the same handlers.
                ForEach(MessageViewMode.allCases, id: \.self) { mode in
                    Button(mode.displayName) {
                        NotificationCenter.default.post(
                            name: mode.switchNotification, object: nil)
                    }
                    .keyboardShortcut(mode.commandShortcutKey, modifiers: [.command])
                }

                Divider()

                Button("Show Console") {
                    openWindow(id: "console")
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
            }
        }

        // Stage 4c: the "Mail (Unified)" / "Mail (Classic)" secondary window is
        // gone with the flag. It existed only so the non-default surface stayed
        // reachable during the gated cutover; with one root there is no second
        // surface to reach, and a duplicate chassis window would fork the mail
        // selection and the compose sheet between two `MailChassisHost`s.

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

// Stage 4c: `AppState.viewMode` and the `ViewMode` (messages/threads) enum are
// deleted. They existed for the View menu's "View Mode" picker, and NOTHING ever
// read them — the window's actual mode lived in `ViewModeState.mode:
// MessageViewMode`, a different type with five cases. The picker was a control
// that appeared to do something and did not; the ⌘1-5 commands that replaced it
// drive the chassis for real.

// MARK: - Appearance
//
// `AppearanceModifier` / `withAppearance()` are ImpressTheme's now (ADR-0022
// X2, D9 finding 5). The 18 lines that used to sit here were byte-identical to
// imprint's and impress's, and all three re-derived the string->ColorScheme
// mapping `AppearanceMode.colorScheme` already publishes. Same key
// (`appearanceMode`), same behaviour; `import ImpressTheme` is the migration.

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

    // MARK: View modes (Stage 4c)
    //
    // These five were raw `Notification.Name("switchTo…View")` strings spelled
    // once in `ContentView`'s observers and once more, as
    // `ImpartKeyboardShortcutsSettings` `notificationName` values, in
    // MessageManagerCore. The RAW VALUES are unchanged — a user's customised
    // ⌘1/⌘2/⌘3 bindings still post exactly these — they are just named now, so
    // the poster and the observer can no longer drift by a typo. (Two of the
    // five had no store binding and no poster at all before this.)
    static let switchToEmailView = Notification.Name("switchToEmailView")
    static let switchToChatView = Notification.Name("switchToChatView")
    static let switchToCategoryView = Notification.Name("switchToCategoryView")
    static let switchToResearchView = Notification.Name("switchToResearchView")
    static let switchToDevelopmentView = Notification.Name("switchToDevelopmentView")
}

// MARK: - View Mode Commands

extension MessageViewMode {

    /// The notification this mode's menu command / keyboard binding posts.
    var switchNotification: Notification.Name {
        switch self {
        case .email: return .switchToEmailView
        case .chat: return .switchToChatView
        case .category: return .switchToCategoryView
        case .research: return .switchToResearchView
        case .development: return .switchToDevelopmentView
        }
    }

    /// ⌘1-5, in `MessageViewMode.allCases` order — the order the classic
    /// toolbar's segmented picker showed and the order its help text promised
    /// ("Switch view mode (Cmd+1/2/3/4/5)").
    var commandShortcutKey: KeyEquivalent {
        switch self {
        case .email: return "1"
        case .chat: return "2"
        case .category: return "3"
        case .research: return "4"
        case .development: return "5"
        }
    }
}
