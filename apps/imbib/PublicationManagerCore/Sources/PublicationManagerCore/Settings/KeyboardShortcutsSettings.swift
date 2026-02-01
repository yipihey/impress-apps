//
//  KeyboardShortcutsSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import SwiftUI

// MARK: - Shortcut Category

/// Categories for organizing keyboard shortcuts in the UI
public enum ShortcutCategory: String, Codable, CaseIterable, Sendable {
    case navigation = "Navigation"
    case views = "Views"
    case focus = "Focus"
    case paperActions = "Paper Actions"
    case clipboard = "Clipboard"
    case filtering = "Filtering"
    case inboxTriage = "Inbox Triage"
    case pdfViewer = "PDF Viewer"
    case fileOperations = "File Operations"
    case app = "App"

    public var displayName: String { rawValue }
}

// MARK: - Shortcut Key

/// Represents a keyboard key (character or special key)
public enum ShortcutKey: Codable, Equatable, Hashable, Sendable {
    case character(String)      // Single character like "a", "1", "/"
    case special(SpecialKey)    // Special keys like return, delete, arrows

    public enum SpecialKey: String, Codable, CaseIterable, Sendable {
        case `return` = "return"
        case escape = "escape"
        case delete = "delete"
        case tab = "tab"
        case space = "space"
        case upArrow = "upArrow"
        case downArrow = "downArrow"
        case leftArrow = "leftArrow"
        case rightArrow = "rightArrow"
        case home = "home"
        case end = "end"
        case pageUp = "pageUp"
        case pageDown = "pageDown"
        case plus = "plus"          // For ⌘+ zoom
        case minus = "minus"        // For ⌘- zoom

        /// SwiftUI KeyEquivalent for this special key
        public var keyEquivalent: KeyEquivalent {
            switch self {
            case .return: return .return
            case .escape: return .escape
            case .delete: return .delete
            case .tab: return .tab
            case .space: return .space
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .plus: return KeyEquivalent("+")
            case .minus: return KeyEquivalent("-")
            }
        }

        /// Display symbol for this special key
        public var displaySymbol: String {
            switch self {
            case .return: return "↩"
            case .escape: return "⎋"
            case .delete: return "⌫"
            case .tab: return "⇥"
            case .space: return "Space"
            case .upArrow: return "↑"
            case .downArrow: return "↓"
            case .leftArrow: return "←"
            case .rightArrow: return "→"
            case .home: return "↖"
            case .end: return "↘"
            case .pageUp: return "⇞"
            case .pageDown: return "⇟"
            case .plus: return "+"
            case .minus: return "-"
            }
        }
    }

    /// SwiftUI KeyEquivalent for this key
    public var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let char):
            return KeyEquivalent(Character(char))
        case .special(let special):
            return special.keyEquivalent
        }
    }

    /// Display string for the key (lowercase for clarity)
    public var displayString: String {
        switch self {
        case .character(let char):
            return char.lowercased()
        case .special(let special):
            return special.displaySymbol
        }
    }

    /// Create from a string representation
    public init(from string: String) {
        if let special = SpecialKey(rawValue: string) {
            self = .special(special)
        } else {
            self = .character(string.lowercased())
        }
    }

    /// String representation for storage
    public var stringValue: String {
        switch self {
        case .character(let char): return char
        case .special(let special): return special.rawValue
        }
    }
}

// MARK: - Shortcut Modifiers

/// Modifier keys for shortcuts
public struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)

    public static let none: ShortcutModifiers = []

    /// Convert to SwiftUI EventModifiers
    public var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    /// Display string with modifier symbols
    /// Uses "Shift+" for shift-only shortcuts (clearer), symbols otherwise
    public var displayString: String {
        // For shift-only modifier, use readable format "Shift+"
        if self == .shift {
            return "Shift+"
        }
        // For other combinations, use symbol format
        var symbols: [String] = []
        if contains(.control) { symbols.append("⌃") }
        if contains(.option) { symbols.append("⌥") }
        if contains(.shift) { symbols.append("⇧") }
        if contains(.command) { symbols.append("⌘") }
        return symbols.joined()
    }
}

// MARK: - Keyboard Shortcut Binding

/// A single keyboard shortcut binding
public struct KeyboardShortcutBinding: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Unique identifier (notification name without "com.imbib.")
    public let id: String

    /// Display name shown in settings
    public let displayName: String

    /// Category for grouping in UI
    public let category: ShortcutCategory

    /// The key for this shortcut
    public var key: ShortcutKey

    /// Modifier keys (command, shift, option, control)
    public var modifiers: ShortcutModifiers

    /// Notification name to post when triggered
    public let notificationName: String

    /// Whether this shortcut can be customized
    public let isCustomizable: Bool

    public init(
        id: String,
        displayName: String,
        category: ShortcutCategory,
        key: ShortcutKey,
        modifiers: ShortcutModifiers = .none,
        notificationName: String,
        isCustomizable: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.key = key
        self.modifiers = modifiers
        self.notificationName = notificationName
        self.isCustomizable = isCustomizable
    }

    /// Full display string including modifiers and key
    public var displayShortcut: String {
        modifiers.displayString + key.displayString
    }

    /// Apply this shortcut to a SwiftUI Button
    public func keyboardShortcut() -> KeyboardShortcut {
        KeyboardShortcut(key.keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    /// Check if this binding matches a KeyPress event.
    /// Used for `.onKeyPress` handlers to support customizable shortcuts.
    public func matches(_ press: KeyPress) -> Bool {
        let keyMatches: Bool
        switch key {
        case .character(let char):
            keyMatches = press.characters.lowercased() == char.lowercased()
        case .special(let special):
            keyMatches = press.key == special.keyEquivalent
        }
        guard keyMatches else { return false }
        return ShortcutModifiers(press.modifiers) == modifiers
    }
}

// MARK: - ShortcutModifiers + KeyPress

extension ShortcutModifiers {
    /// Initialize from SwiftUI EventModifiers (used for KeyPress matching)
    public init(_ modifiers: EventModifiers) {
        var result: ShortcutModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        self = result
    }
}

// MARK: - Keyboard Shortcuts Settings

/// All keyboard shortcut bindings
public struct KeyboardShortcutsSettings: Codable, Equatable, Sendable {
    public var bindings: [KeyboardShortcutBinding]

    public init(bindings: [KeyboardShortcutBinding]) {
        self.bindings = bindings
    }

    /// Get binding by ID
    public func binding(id: String) -> KeyboardShortcutBinding? {
        bindings.first { $0.id == id }
    }

    /// Get binding by notification name
    public func binding(forNotification name: String) -> KeyboardShortcutBinding? {
        bindings.first { $0.notificationName == name }
    }

    /// Get bindings for a category
    public func bindings(for category: ShortcutCategory) -> [KeyboardShortcutBinding] {
        bindings.filter { $0.category == category }
    }

    /// Update a binding
    public mutating func updateBinding(_ binding: KeyboardShortcutBinding) {
        if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[index] = binding
        }
    }

    /// Detect conflicts (same key + modifiers used by multiple shortcuts)
    public func detectConflicts() -> [(KeyboardShortcutBinding, KeyboardShortcutBinding)] {
        var conflicts: [(KeyboardShortcutBinding, KeyboardShortcutBinding)] = []
        for i in 0..<bindings.count {
            for j in (i+1)..<bindings.count {
                let a = bindings[i]
                let b = bindings[j]
                if a.key == b.key && a.modifiers == b.modifiers {
                    conflicts.append((a, b))
                }
            }
        }
        return conflicts
    }

    /// Check if a key combination conflicts with existing bindings
    public func conflictsWith(key: ShortcutKey, modifiers: ShortcutModifiers, excluding id: String) -> KeyboardShortcutBinding? {
        bindings.first { $0.id != id && $0.key == key && $0.modifiers == modifiers }
    }

    // MARK: - Factory Defaults

    /// Default keyboard shortcuts
    public static let defaults = KeyboardShortcutsSettings(bindings: [
        // MARK: Navigation (Vim-style)
        KeyboardShortcutBinding(
            id: "navigateDown",
            displayName: "Down (Vim)",
            category: .navigation,
            key: .character("j"),
            modifiers: .none,
            notificationName: "navigateNextPaper"
        ),
        KeyboardShortcutBinding(
            id: "navigateUp",
            displayName: "Up (Vim)",
            category: .navigation,
            key: .character("k"),
            modifiers: .none,
            notificationName: "navigatePreviousPaper"
        ),
        KeyboardShortcutBinding(
            id: "cycleFocusLeft",
            displayName: "Focus Left Pane",
            category: .navigation,
            key: .character("h"),
            modifiers: .none,
            notificationName: "cycleFocusLeft"
        ),
        KeyboardShortcutBinding(
            id: "cycleFocusRight",
            displayName: "Focus Right Pane",
            category: .navigation,
            key: .character("l"),
            modifiers: .none,
            notificationName: "cycleFocusRight"
        ),
        KeyboardShortcutBinding(
            id: "showInfoTabVim",
            displayName: "Info Tab",
            category: .navigation,
            key: .character("i"),
            modifiers: .none,
            notificationName: "showInfoTab"
        ),
        KeyboardShortcutBinding(
            id: "showPDFTabVim",
            displayName: "PDF Tab",
            category: .navigation,
            key: .character("p"),
            modifiers: .none,
            notificationName: "showPDFTab"
        ),
        KeyboardShortcutBinding(
            id: "showNotesTabVim",
            displayName: "Notes Tab",
            category: .navigation,
            key: .character("n"),
            modifiers: .none,
            notificationName: "showNotesTab"
        ),
        KeyboardShortcutBinding(
            id: "showBibTeXTabVim",
            displayName: "BibTeX Tab",
            category: .navigation,
            key: .character("b"),
            modifiers: .none,
            notificationName: "showBibTeXTab"
        ),
        // MARK: Navigation (Arrow Keys)
        KeyboardShortcutBinding(
            id: "navigateNextPaper",
            displayName: "Next Paper",
            category: .navigation,
            key: .special(.downArrow),
            modifiers: .none,
            notificationName: "navigateNextPaper"
        ),
        KeyboardShortcutBinding(
            id: "navigatePreviousPaper",
            displayName: "Previous Paper",
            category: .navigation,
            key: .special(.upArrow),
            modifiers: .none,
            notificationName: "navigatePreviousPaper"
        ),
        KeyboardShortcutBinding(
            id: "navigateFirstPaper",
            displayName: "First Paper",
            category: .navigation,
            key: .special(.upArrow),
            modifiers: .command,
            notificationName: "navigateFirstPaper"
        ),
        KeyboardShortcutBinding(
            id: "navigateLastPaper",
            displayName: "Last Paper",
            category: .navigation,
            key: .special(.downArrow),
            modifiers: .command,
            notificationName: "navigateLastPaper"
        ),
        KeyboardShortcutBinding(
            id: "navigateNextUnread",
            displayName: "Next Unread",
            category: .navigation,
            key: .special(.downArrow),
            modifiers: .option,
            notificationName: "navigateNextUnread"
        ),
        KeyboardShortcutBinding(
            id: "navigatePreviousUnread",
            displayName: "Previous Unread",
            category: .navigation,
            key: .special(.upArrow),
            modifiers: .option,
            notificationName: "navigatePreviousUnread"
        ),
        KeyboardShortcutBinding(
            id: "navigateNextUnreadVim",
            displayName: "Next Unread (Vim)",
            category: .navigation,
            key: .character("j"),
            modifiers: .option,
            notificationName: "navigateNextUnread"
        ),
        KeyboardShortcutBinding(
            id: "navigatePreviousUnreadVim",
            displayName: "Previous Unread (Vim)",
            category: .navigation,
            key: .character("k"),
            modifiers: .option,
            notificationName: "navigatePreviousUnread"
        ),
        KeyboardShortcutBinding(
            id: "openSelectedPaper",
            displayName: "Open Paper",
            category: .navigation,
            key: .special(.return),
            modifiers: .none,
            notificationName: "openSelectedPaper"
        ),

        // MARK: Views
        KeyboardShortcutBinding(
            id: "showLibrary",
            displayName: "Show Library",
            category: .views,
            key: .character("1"),
            modifiers: .command,
            notificationName: "showLibrary"
        ),
        KeyboardShortcutBinding(
            id: "showSearch",
            displayName: "Show Search",
            category: .views,
            key: .character("2"),
            modifiers: .command,
            notificationName: "showSearch"
        ),
        KeyboardShortcutBinding(
            id: "showInbox",
            displayName: "Show Inbox",
            category: .views,
            key: .character("3"),
            modifiers: .command,
            notificationName: "showInbox"
        ),
        KeyboardShortcutBinding(
            id: "showPDFTab",
            displayName: "Show PDF Tab",
            category: .views,
            key: .character("4"),
            modifiers: .command,
            notificationName: "showPDFTab"
        ),
        KeyboardShortcutBinding(
            id: "showBibTeXTab",
            displayName: "Show BibTeX Tab",
            category: .views,
            key: .character("5"),
            modifiers: .command,
            notificationName: "showBibTeXTab"
        ),
        KeyboardShortcutBinding(
            id: "showNotesTab",
            displayName: "Show Notes Tab",
            category: .views,
            key: .character("6"),
            modifiers: .command,
            notificationName: "showNotesTab"
        ),
        KeyboardShortcutBinding(
            id: "toggleDetailPane",
            displayName: "Toggle Detail Pane",
            category: .views,
            key: .character("0"),
            modifiers: .command,
            notificationName: "toggleDetailPane"
        ),
        KeyboardShortcutBinding(
            id: "toggleSidebar",
            displayName: "Toggle Sidebar",
            category: .views,
            key: .character("s"),
            modifiers: [.control, .command],
            notificationName: "toggleSidebar"
        ),

        // MARK: Focus
        KeyboardShortcutBinding(
            id: "focusSidebar",
            displayName: "Focus Sidebar",
            category: .focus,
            key: .character("1"),
            modifiers: [.option, .command],
            notificationName: "focusSidebar"
        ),
        KeyboardShortcutBinding(
            id: "focusList",
            displayName: "Focus List",
            category: .focus,
            key: .character("2"),
            modifiers: [.option, .command],
            notificationName: "focusList"
        ),
        KeyboardShortcutBinding(
            id: "focusDetail",
            displayName: "Focus Detail",
            category: .focus,
            key: .character("3"),
            modifiers: [.option, .command],
            notificationName: "focusDetail"
        ),
        KeyboardShortcutBinding(
            id: "focusSearch",
            displayName: "Focus Search Field",
            category: .focus,
            key: .character("f"),
            modifiers: .command,
            notificationName: "focusSearch"
        ),

        // MARK: Paper Actions
        KeyboardShortcutBinding(
            id: "showNotesTabR",
            displayName: "Open Notes",
            category: .paperActions,
            key: .character("r"),
            modifiers: .command,
            notificationName: "showNotesTab"
        ),
        KeyboardShortcutBinding(
            id: "openReferences",
            displayName: "Open References",
            category: .paperActions,
            key: .character("r"),
            modifiers: [.shift, .command],
            notificationName: "openReferences"
        ),
        KeyboardShortcutBinding(
            id: "toggleReadStatus",
            displayName: "Toggle Read/Unread",
            category: .paperActions,
            key: .character("u"),
            modifiers: [.shift, .command],
            notificationName: "toggleReadStatus"
        ),
        KeyboardShortcutBinding(
            id: "markAllAsRead",
            displayName: "Mark All as Read",
            category: .paperActions,
            key: .character("u"),
            modifiers: [.option, .command],
            notificationName: "markAllAsRead"
        ),
        KeyboardShortcutBinding(
            id: "saveToLibrary",
            displayName: "Save to Library",
            category: .paperActions,
            key: .character("s"),
            modifiers: [.control, .command],
            notificationName: "saveToLibrary"
        ),
        KeyboardShortcutBinding(
            id: "dismissFromInbox",
            displayName: "Dismiss from Inbox",
            category: .paperActions,
            key: .character("j"),
            modifiers: [.shift, .command],
            notificationName: "dismissFromInbox"
        ),
        KeyboardShortcutBinding(
            id: "addToCollection",
            displayName: "Add to Collection",
            category: .paperActions,
            key: .character("l"),
            modifiers: .command,
            notificationName: "addToCollection"
        ),
        KeyboardShortcutBinding(
            id: "removeFromCollection",
            displayName: "Remove from Collection",
            category: .paperActions,
            key: .character("l"),
            modifiers: [.shift, .command],
            notificationName: "removeFromCollection"
        ),
        KeyboardShortcutBinding(
            id: "moveToCollection",
            displayName: "Move to Collection",
            category: .paperActions,
            key: .character("m"),
            modifiers: [.control, .command],
            notificationName: "moveToCollection"
        ),
        KeyboardShortcutBinding(
            id: "sharePapers",
            displayName: "Share",
            category: .paperActions,
            key: .character("f"),
            modifiers: [.shift, .command],
            notificationName: "sharePapers"
        ),
        KeyboardShortcutBinding(
            id: "deleteSelectedPapers",
            displayName: "Delete",
            category: .paperActions,
            key: .special(.delete),
            modifiers: .command,
            notificationName: "deleteSelectedPapers"
        ),

        // MARK: Clipboard
        KeyboardShortcutBinding(
            id: "copyPublications",
            displayName: "Copy BibTeX",
            category: .clipboard,
            key: .character("c"),
            modifiers: .command,
            notificationName: "copyPublications"
        ),
        KeyboardShortcutBinding(
            id: "copyAsCitation",
            displayName: "Copy as Citation",
            category: .clipboard,
            key: .character("c"),
            modifiers: [.shift, .command],
            notificationName: "copyAsCitation"
        ),
        KeyboardShortcutBinding(
            id: "copyIdentifier",
            displayName: "Copy DOI/URL",
            category: .clipboard,
            key: .character("c"),
            modifiers: [.option, .command],
            notificationName: "copyIdentifier"
        ),
        KeyboardShortcutBinding(
            id: "cutPublications",
            displayName: "Cut",
            category: .clipboard,
            key: .character("x"),
            modifiers: .command,
            notificationName: "cutPublications"
        ),
        KeyboardShortcutBinding(
            id: "pastePublications",
            displayName: "Paste",
            category: .clipboard,
            key: .character("v"),
            modifiers: .command,
            notificationName: "pastePublications"
        ),
        KeyboardShortcutBinding(
            id: "selectAllPublications",
            displayName: "Select All",
            category: .clipboard,
            key: .character("a"),
            modifiers: .command,
            notificationName: "selectAllPublications"
        ),

        // MARK: Filtering
        KeyboardShortcutBinding(
            id: "toggleUnreadFilter",
            displayName: "Toggle Unread Filter",
            category: .filtering,
            key: .character("\\"),
            modifiers: .command,
            notificationName: "toggleUnreadFilter"
        ),
        KeyboardShortcutBinding(
            id: "togglePDFFilter",
            displayName: "Toggle PDF Filter",
            category: .filtering,
            key: .character("\\"),
            modifiers: [.shift, .command],
            notificationName: "togglePDFFilter"
        ),

        // MARK: Inbox Triage (Single Keys)
        KeyboardShortcutBinding(
            id: "inboxSave",
            displayName: "Save",
            category: .inboxTriage,
            key: .character("s"),
            modifiers: .none,
            notificationName: "inboxSave"
        ),
        KeyboardShortcutBinding(
            id: "inboxSaveAndStar",
            displayName: "Save and Star",
            category: .inboxTriage,
            key: .character("s"),
            modifiers: .shift,
            notificationName: "inboxSaveAndStar"
        ),
        KeyboardShortcutBinding(
            id: "inboxToggleStar",
            displayName: "Toggle Star",
            category: .inboxTriage,
            key: .character("t"),
            modifiers: .none,
            notificationName: "inboxToggleStar"
        ),
        KeyboardShortcutBinding(
            id: "inboxDismiss",
            displayName: "Dismiss",
            category: .inboxTriage,
            key: .character("d"),
            modifiers: .none,
            notificationName: "inboxDismiss"
        ),
        KeyboardShortcutBinding(
            id: "inboxMarkRead",
            displayName: "Mark as Read",
            category: .inboxTriage,
            key: .character("r"),
            modifiers: .none,
            notificationName: "inboxMarkRead"
        ),
        KeyboardShortcutBinding(
            id: "inboxMarkUnread",
            displayName: "Mark as Unread",
            category: .inboxTriage,
            key: .character("u"),
            modifiers: .none,
            notificationName: "inboxMarkUnread"
        ),
        KeyboardShortcutBinding(
            id: "inboxNextItem",
            displayName: "Next (Vim)",
            category: .inboxTriage,
            key: .character("j"),
            modifiers: .none,
            notificationName: "inboxNextItem"
        ),
        KeyboardShortcutBinding(
            id: "inboxPreviousItem",
            displayName: "Previous (Vim)",
            category: .inboxTriage,
            key: .character("k"),
            modifiers: .none,
            notificationName: "inboxPreviousItem"
        ),
        KeyboardShortcutBinding(
            id: "inboxOpenItem",
            displayName: "Open (Vim)",
            category: .inboxTriage,
            key: .character("o"),
            modifiers: .none,
            notificationName: "inboxOpenItem"
        ),

        // MARK: PDF Viewer
        KeyboardShortcutBinding(
            id: "pdfPageDown",
            displayName: "Page Down",
            category: .pdfViewer,
            key: .special(.space),
            modifiers: .none,
            notificationName: "pdfPageDown"
        ),
        KeyboardShortcutBinding(
            id: "pdfPageUp",
            displayName: "Page Up",
            category: .pdfViewer,
            key: .special(.space),
            modifiers: .shift,
            notificationName: "pdfPageUp"
        ),
        // Note: j/k navigation is context-aware via "navigateDown"/"navigateUp" bindings
        // - In list/sidebar: navigates papers
        // - In detail tabs: scrolls content
        // - In PDF: half-page scroll
        KeyboardShortcutBinding(
            id: "pdfZoomIn",
            displayName: "Zoom In",
            category: .pdfViewer,
            key: .special(.plus),
            modifiers: [.command, .shift],
            notificationName: "pdfZoomIn"
        ),
        KeyboardShortcutBinding(
            id: "pdfZoomOut",
            displayName: "Zoom Out",
            category: .pdfViewer,
            key: .special(.minus),
            modifiers: [.command, .shift],
            notificationName: "pdfZoomOut"
        ),
        KeyboardShortcutBinding(
            id: "pdfGoToPage",
            displayName: "Go to Page",
            category: .pdfViewer,
            key: .character("g"),
            modifiers: .command,
            notificationName: "pdfGoToPage"
        ),

        // MARK: File Operations
        KeyboardShortcutBinding(
            id: "importBibTeX",
            displayName: "Import BibTeX",
            category: .fileOperations,
            key: .character("i"),
            modifiers: .command,
            notificationName: "importBibTeX"
        ),
        KeyboardShortcutBinding(
            id: "exportBibTeX",
            displayName: "Export Library",
            category: .fileOperations,
            key: .character("e"),
            modifiers: [.shift, .command],
            notificationName: "exportBibTeX"
        ),
        KeyboardShortcutBinding(
            id: "refreshData",
            displayName: "Refresh",
            category: .fileOperations,
            key: .character("n"),
            modifiers: [.shift, .command],
            notificationName: "refreshData"
        ),

        // MARK: App
        KeyboardShortcutBinding(
            id: "showKeyboardShortcuts",
            displayName: "Keyboard Shortcuts",
            category: .app,
            key: .character("/"),
            modifiers: .command,
            notificationName: "showKeyboardShortcuts"
        ),
    ])

    // MARK: - Documentation Export

    /// A simplified shortcut structure for documentation generation.
    /// This serves as the single source of truth for all shortcut documentation.
    public struct DocumentationShortcut: Codable, Sendable {
        public let id: String
        public let displayName: String
        public let category: String
        public let shortcut: String
        public let notificationName: String
    }

    /// Export all default shortcuts as documentation-ready structures.
    /// This is the single source of truth for keyboard shortcuts documentation.
    public static func exportForDocumentation() -> [DocumentationShortcut] {
        defaults.bindings.map { binding in
            DocumentationShortcut(
                id: binding.id,
                displayName: binding.displayName,
                category: binding.category.displayName,
                shortcut: binding.displayShortcut,
                notificationName: binding.notificationName
            )
        }
    }

    /// Export shortcuts as JSON for external tools.
    /// Usage: `print(KeyboardShortcutsSettings.exportJSON())`
    public static func exportJSON() -> String {
        let shortcuts = exportForDocumentation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shortcuts),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Export shortcuts grouped by category as JSON.
    public static func exportGroupedJSON() -> String {
        let shortcuts = exportForDocumentation()
        var grouped: [String: [[String: String]]] = [:]

        for shortcut in shortcuts {
            let entry: [String: String] = [
                "action": shortcut.displayName,
                "shortcut": shortcut.shortcut
            ]
            grouped[shortcut.category, default: []].append(entry)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(grouped),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Generate markdown documentation directly.
    /// This ensures documentation is always in sync with code.
    public static func generateMarkdown() -> String {
        let shortcuts = exportForDocumentation()
        var grouped: [String: [DocumentationShortcut]] = [:]

        for shortcut in shortcuts {
            grouped[shortcut.category, default: []].append(shortcut)
        }

        // Category order
        let categoryOrder = [
            "Navigation", "Views", "Focus", "Paper Actions",
            "Clipboard", "Filtering", "Inbox Triage",
            "PDF Viewer", "File Operations", "App"
        ]

        var markdown = """
        ---
        layout: default
        title: Keyboard Shortcuts
        nav_order: 5
        ---

        # Keyboard Shortcuts

        imbib provides extensive keyboard shortcuts for efficient paper management.

        {: .note }
        > **Vim-style navigation**: Use `j`/`k` for down/up, `h`/`l` for previous/next tab.
        > **Single-key shortcuts** (in Inbox Triage) only work when the Inbox is focused.

        ---


        """

        for category in categoryOrder {
            guard let categoryShortcuts = grouped[category], !categoryShortcuts.isEmpty else {
                continue
            }

            markdown += "## \(category)\n\n"
            markdown += "| Action | Shortcut |\n"
            markdown += "|--------|----------|\n"

            for shortcut in categoryShortcuts {
                // Escape pipe characters in shortcut display
                let escapedShortcut = shortcut.shortcut.replacingOccurrences(of: "|", with: "\\|")
                markdown += "| \(shortcut.displayName) | \(escapedShortcut) |\n"
            }

            markdown += "\n"
        }

        markdown += """
        ---

        *Auto-generated from `KeyboardShortcutsSettings.defaults` — the single source of truth.*
        """

        return markdown
    }
}
