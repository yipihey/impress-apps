//
//  CommandRegistry.swift
//  PublicationManagerCore
//
//  Registry for all app commands, enabling the command palette.
//

import Foundation
import SwiftUI

// MARK: - Command Category

/// Categories for organizing commands in the palette
public enum CommandCategory: String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case paper = "Paper Actions"
    case view = "View"
    case search = "Search"
    case clipboard = "Clipboard"
    case importExport = "Import/Export"
    case app = "App"

    public var displayName: String { rawValue }

    /// Sort order for display
    public var sortOrder: Int {
        switch self {
        case .navigation: return 0
        case .paper: return 1
        case .view: return 2
        case .search: return 3
        case .clipboard: return 4
        case .importExport: return 5
        case .app: return 6
        }
    }
}

// MARK: - Command

/// A single command that can be executed via the command palette
public struct Command: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: CommandCategory
    public let shortcut: String?
    public let notificationName: Notification.Name

    public init(
        id: String,
        title: String,
        category: CommandCategory,
        shortcut: String? = nil,
        notificationName: Notification.Name
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.notificationName = notificationName
    }

    /// Execute this command by posting its notification
    public func execute() {
        NotificationCenter.default.post(name: notificationName, object: nil)
    }
}

// MARK: - Command Registry

/// Registry of all available commands
@Observable
public final class CommandRegistry: @unchecked Sendable {

    // MARK: - Shared Instance

    public static let shared = CommandRegistry()

    // MARK: - Properties

    private(set) public var commands: [Command] = []

    // MARK: - Initialization

    private init() {
        registerDefaultCommands()
    }

    // MARK: - Registration

    /// Register a command
    public func register(_ command: Command) {
        if !commands.contains(where: { $0.id == command.id }) {
            commands.append(command)
        }
    }

    // MARK: - Search

    /// Search commands by query (fuzzy matching on title)
    public func search(_ query: String) -> [Command] {
        guard !query.isEmpty else {
            return commands.sorted { $0.category.sortOrder < $1.category.sortOrder }
        }

        let lowercaseQuery = query.lowercased()

        return commands.filter { command in
            command.title.lowercased().contains(lowercaseQuery) ||
            command.category.displayName.lowercased().contains(lowercaseQuery)
        }.sorted { lhs, rhs in
            // Prioritize title matches over category matches
            let lhsTitleMatch = lhs.title.lowercased().hasPrefix(lowercaseQuery)
            let rhsTitleMatch = rhs.title.lowercased().hasPrefix(lowercaseQuery)

            if lhsTitleMatch != rhsTitleMatch {
                return lhsTitleMatch
            }

            return lhs.category.sortOrder < rhs.category.sortOrder
        }
    }

    // MARK: - Default Commands

    private func registerDefaultCommands() {
        // Navigation
        register(Command(id: "showLibrary", title: "Show Library", category: .navigation, shortcut: "⌘1", notificationName: .showLibrary))
        register(Command(id: "showSearch", title: "Show Search", category: .navigation, shortcut: "⌘2", notificationName: .showSearch))
        register(Command(id: "showInbox", title: "Show Inbox", category: .navigation, shortcut: "⌘3", notificationName: .showInbox))
        register(Command(id: "navigateBack", title: "Go Back", category: .navigation, shortcut: "⌘[", notificationName: .navigateBack))
        register(Command(id: "navigateForward", title: "Go Forward", category: .navigation, shortcut: "⌘]", notificationName: .navigateForward))
        register(Command(id: "nextPaper", title: "Next Paper", category: .navigation, shortcut: "↓", notificationName: .navigateNextPaper))
        register(Command(id: "previousPaper", title: "Previous Paper", category: .navigation, shortcut: "↑", notificationName: .navigatePreviousPaper))
        register(Command(id: "nextUnread", title: "Next Unread", category: .navigation, shortcut: "⌥↓", notificationName: .navigateNextUnread))
        register(Command(id: "previousUnread", title: "Previous Unread", category: .navigation, shortcut: "⌥↑", notificationName: .navigatePreviousUnread))

        // View
        register(Command(id: "showPDFTab", title: "Show PDF Tab", category: .view, shortcut: "⌘4", notificationName: .showPDFTab))
        register(Command(id: "showBibTeXTab", title: "Show BibTeX Tab", category: .view, shortcut: "⌘5", notificationName: .showBibTeXTab))
        register(Command(id: "showNotesTab", title: "Show Notes Tab", category: .view, shortcut: "⌘6", notificationName: .showNotesTab))
        register(Command(id: "toggleDetailPane", title: "Toggle Detail Pane", category: .view, shortcut: "⌘0", notificationName: .toggleDetailPane))
        register(Command(id: "toggleSidebar", title: "Toggle Sidebar", category: .view, shortcut: "⌃⌘S", notificationName: .toggleSidebar))
        register(Command(id: "focusSidebar", title: "Focus Sidebar", category: .view, shortcut: "⌥⌘1", notificationName: .focusSidebar))
        register(Command(id: "focusList", title: "Focus List", category: .view, shortcut: "⌥⌘2", notificationName: .focusList))
        register(Command(id: "focusDetail", title: "Focus Detail", category: .view, shortcut: "⌥⌘3", notificationName: .focusDetail))
        register(Command(id: "increaseFontSize", title: "Increase Text Size", category: .view, shortcut: "⇧⌘+", notificationName: .increaseFontSize))
        register(Command(id: "decreaseFontSize", title: "Decrease Text Size", category: .view, shortcut: "⇧⌘-", notificationName: .decreaseFontSize))

        // Paper Actions
        register(Command(id: "openPaper", title: "Open Paper", category: .paper, shortcut: "↩", notificationName: .openSelectedPaper))
        register(Command(id: "toggleReadStatus", title: "Toggle Read/Unread", category: .paper, shortcut: "⇧⌘U", notificationName: .toggleReadStatus))
        register(Command(id: "markAllAsRead", title: "Mark All as Read", category: .paper, shortcut: "⌥⌘U", notificationName: .markAllAsRead))
        register(Command(id: "keepToLibrary", title: "Keep to Library", category: .paper, shortcut: "⌃⌘K", notificationName: .keepToLibrary))
        register(Command(id: "dismissFromInbox", title: "Dismiss from Inbox", category: .paper, shortcut: "⇧⌘J", notificationName: .dismissFromInbox))
        register(Command(id: "addToCollection", title: "Add to Collection...", category: .paper, shortcut: "⌘L", notificationName: .addToCollection))
        register(Command(id: "removeFromCollection", title: "Remove from Collection", category: .paper, shortcut: "⇧⌘L", notificationName: .removeFromCollection))
        register(Command(id: "moveToCollection", title: "Move to Collection...", category: .paper, shortcut: "⌃⌘M", notificationName: .moveToCollection))
        register(Command(id: "sharePapers", title: "Share...", category: .paper, shortcut: "⇧⌘F", notificationName: .sharePapers))
        register(Command(id: "deletePapers", title: "Delete", category: .paper, shortcut: "⌘⌫", notificationName: .deleteSelectedPapers))
        register(Command(id: "openReferences", title: "Open References", category: .paper, shortcut: "⇧⌘R", notificationName: .openReferences))

        // Search
        register(Command(id: "globalSearch", title: "Global Search", category: .search, shortcut: "⌘F", notificationName: .focusSearch))
        register(Command(id: "toggleUnreadFilter", title: "Toggle Unread Filter", category: .search, shortcut: "⌘\\", notificationName: .toggleUnreadFilter))
        register(Command(id: "togglePDFFilter", title: "Toggle PDF Filter", category: .search, shortcut: "⇧⌘\\", notificationName: .togglePDFFilter))

        // Clipboard
        register(Command(id: "copyBibTeX", title: "Copy BibTeX", category: .clipboard, shortcut: "⌘C", notificationName: .copyPublications))
        register(Command(id: "copyAsCitation", title: "Copy as Citation", category: .clipboard, shortcut: "⇧⌘C", notificationName: .copyAsCitation))
        register(Command(id: "copyIdentifier", title: "Copy DOI/URL", category: .clipboard, shortcut: "⌥⌘C", notificationName: .copyIdentifier))
        register(Command(id: "paste", title: "Paste", category: .clipboard, shortcut: "⌘V", notificationName: .pastePublications))
        register(Command(id: "selectAll", title: "Select All", category: .clipboard, shortcut: "⌘A", notificationName: .selectAllPublications))

        // Import/Export
        register(Command(id: "importBibTeX", title: "Import BibTeX...", category: .importExport, shortcut: "⌘I", notificationName: .importBibTeX))
        register(Command(id: "exportLibrary", title: "Export Library...", category: .importExport, shortcut: "⇧⌘E", notificationName: .exportBibTeX))
        register(Command(id: "refresh", title: "Refresh", category: .importExport, shortcut: "⇧⌘N", notificationName: .refreshData))

        // App
        register(Command(id: "showKeyboardShortcuts", title: "Keyboard Shortcuts", category: .app, shortcut: "⌘/", notificationName: .showKeyboardShortcuts))
        register(Command(id: "showHelp", title: "Help", category: .app, shortcut: "⌘?", notificationName: .showHelp))
        register(Command(id: "showHelpSearch", title: "Search Help...", category: .app, shortcut: "⇧⌘?", notificationName: .showHelpSearchPalette))
    }
}
