//
//  KeyboardShortcutsSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import ImpressKeyboard
import SwiftUI

// MARK: - Shared Types (moved to ImpressKeyboard, Stage 1b)

// `ShortcutCategory`, `ShortcutKey`, `ShortcutModifiers` and
// `KeyboardShortcutBinding` were declared here AND, byte-for-byte, in
// ImpressKeyboard — and a third time, `Impart`-prefixed, in impart's
// MessageManagerCore. They now live once, in ImpressKeyboard, alongside the
// shared `ShortcutCatalog`. These typealiases keep every imbib call site
// (`ShortcutCategory.allCases`, `ShortcutKey.character("j")`, …) unchanged.

public typealias ShortcutCategory = ImpressKeyboard.ShortcutCategory
public typealias ShortcutKey = ImpressKeyboard.ShortcutKey
public typealias ShortcutModifiers = ImpressKeyboard.ShortcutModifiers
public typealias KeyboardShortcutBinding = ImpressKeyboard.KeyboardShortcutBinding


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

    /// imbib's keyboard profile: which of the suite's shared vocabulary
    /// (`ImpressKeyboard.ShortcutCatalog.shared`) imbib adopts, in settings
    /// presentation order, with imbib's app-specific bindings spliced in.
    ///
    /// `.shared("x")` adopts a shared entry verbatim. `as:` pins imbib's
    /// persisted identifier where it differs from the suite's semantic one
    /// (user remaps are stored against the id, so these must never change);
    /// `displayName:` supplies imbib's domain noun ("Next Paper" for the
    /// suite's "Next Item"). `.own(...)` is a binding with no sibling
    /// counterpart — imbib's detail tabs, BibTeX import/export, PDF viewer and
    /// paper actions. Keys and modifiers for adopted entries live ONLY in the
    /// shared catalog, which is what stops imbib and impart drifting again.
    ///
    /// `KeyboardShortcutCatalogParityTests` pins the resolved list to a
    /// snapshot taken before the move, so the settings UI is byte-identical.
    static let profile: [ShortcutProfileItem] = [
        // MARK: Navigation (Vim-style)
        .shared("navigateDown", notificationName: "navigateNextPaper"),
        .shared("navigateUp", notificationName: "navigatePreviousPaper"),
        .shared("cycleFocusLeft"),
        .shared("cycleFocusRight"),
        .own(KeyboardShortcutBinding(
            id: "showInfoTabVim",
            displayName: "Info Tab",
            category: .navigation,
            key: .character("i"),
            modifiers: .none,
            notificationName: "showInfoTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "showPDFTabVim",
            displayName: "PDF Tab",
            category: .navigation,
            key: .character("p"),
            modifiers: .none,
            notificationName: "showPDFTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "showNotesTabVim",
            displayName: "Notes Tab",
            category: .navigation,
            key: .character("n"),
            modifiers: .none,
            notificationName: "showNotesTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "showBibTeXTabVim",
            displayName: "BibTeX Tab",
            category: .navigation,
            key: .character("b"),
            modifiers: .none,
            notificationName: "showBibTeXTab"
        )),
        // MARK: Navigation (Arrow Keys)
        .shared("navigateNextItem", as: "navigateNextPaper", displayName: "Next Paper"),
        .shared("navigatePreviousItem", as: "navigatePreviousPaper", displayName: "Previous Paper"),
        .shared("navigateFirstItem", as: "navigateFirstPaper", displayName: "First Paper"),
        .shared("navigateLastItem", as: "navigateLastPaper", displayName: "Last Paper"),
        .shared("navigateNextUnread"),
        .shared("navigatePreviousUnread"),
        .shared("navigateNextUnreadVim"),
        .shared("navigatePreviousUnreadVim"),
        .shared("openSelectedItem", as: "openSelectedPaper", displayName: "Open Paper"),
        // MARK: Views
        .shared("primaryView1", as: "showLibrary", displayName: "Show Library"),
        .shared("primaryView2", as: "showSearch", displayName: "Show Search"),
        .shared("primaryView3", as: "showInbox", displayName: "Show Inbox"),
        .own(KeyboardShortcutBinding(
            id: "showPDFTab",
            displayName: "Show PDF Tab",
            category: .views,
            key: .character("4"),
            modifiers: .command,
            notificationName: "showPDFTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "showBibTeXTab",
            displayName: "Show BibTeX Tab",
            category: .views,
            key: .character("5"),
            modifiers: .command,
            notificationName: "showBibTeXTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "showNotesTab",
            displayName: "Show Notes Tab",
            category: .views,
            key: .character("6"),
            modifiers: .command,
            notificationName: "showNotesTab"
        )),
        .shared("toggleDetailPane"),
        .shared("toggleSidebar"),
        // MARK: Focus
        .shared("focusSidebar"),
        .shared("focusList"),
        .shared("focusDetail"),
        .shared("focusSearch"),
        // MARK: Paper Actions
        .own(KeyboardShortcutBinding(
            id: "showNotesTabR",
            displayName: "Open Notes",
            category: .paperActions,
            key: .character("r"),
            modifiers: .command,
            notificationName: "showNotesTab"
        )),
        .own(KeyboardShortcutBinding(
            id: "openReferences",
            displayName: "Open References",
            category: .paperActions,
            key: .character("r"),
            modifiers: [.shift, .command],
            notificationName: "openReferences"
        )),
        .own(KeyboardShortcutBinding(
            id: "toggleReadStatus",
            displayName: "Toggle Read/Unread",
            category: .paperActions,
            key: .character("u"),
            modifiers: [.shift, .command],
            notificationName: "toggleReadStatus"
        )),
        .own(KeyboardShortcutBinding(
            id: "markAllAsRead",
            displayName: "Mark All as Read",
            category: .paperActions,
            key: .character("u"),
            modifiers: [.option, .command],
            notificationName: "markAllAsRead"
        )),
        .own(KeyboardShortcutBinding(
            id: "saveToLibrary",
            displayName: "Save to Library",
            category: .paperActions,
            key: .character("s"),
            modifiers: [.control, .command],
            notificationName: "saveToLibrary"
        )),
        .own(KeyboardShortcutBinding(
            id: "dismissFromInbox",
            displayName: "Dismiss from Inbox",
            category: .paperActions,
            key: .character("j"),
            modifiers: [.shift, .command],
            notificationName: "dismissFromInbox"
        )),
        .own(KeyboardShortcutBinding(
            id: "addToCollection",
            displayName: "Add to Collection",
            category: .paperActions,
            key: .character("l"),
            modifiers: .command,
            notificationName: "addToCollection"
        )),
        .own(KeyboardShortcutBinding(
            id: "removeFromCollection",
            displayName: "Remove from Collection",
            category: .paperActions,
            key: .character("l"),
            modifiers: [.shift, .command],
            notificationName: "removeFromCollection"
        )),
        .own(KeyboardShortcutBinding(
            id: "moveToCollection",
            displayName: "Move to Collection",
            category: .paperActions,
            key: .character("m"),
            modifiers: [.control, .command],
            notificationName: "moveToCollection"
        )),
        .own(KeyboardShortcutBinding(
            id: "sharePapers",
            displayName: "Share",
            category: .paperActions,
            key: .character("f"),
            modifiers: [.shift, .command],
            notificationName: "sharePapers"
        )),
        .own(KeyboardShortcutBinding(
            id: "deleteSelectedPapers",
            displayName: "Delete",
            category: .paperActions,
            key: .special(.delete),
            modifiers: .command,
            notificationName: "deleteSelectedPapers"
        )),
        // MARK: Clipboard
        .shared("copyItems", as: "copyPublications", displayName: "Copy BibTeX"),
        .shared("copyItemsAsCitation", as: "copyAsCitation"),
        .shared("copyItemIdentifier", as: "copyIdentifier", displayName: "Copy DOI/URL"),
        .shared("cutItems", as: "cutPublications"),
        .shared("pasteItems", as: "pastePublications"),
        .shared("selectAllItems", as: "selectAllPublications"),
        // MARK: Filtering
        .own(KeyboardShortcutBinding(
            id: "toggleUnreadFilter",
            displayName: "Toggle Unread Filter",
            category: .filtering,
            key: .character("\\"),
            modifiers: .command,
            notificationName: "toggleUnreadFilter"
        )),
        .own(KeyboardShortcutBinding(
            id: "togglePDFFilter",
            displayName: "Toggle PDF Filter",
            category: .filtering,
            key: .character("\\"),
            modifiers: [.shift, .command],
            notificationName: "togglePDFFilter"
        )),
        // MARK: Inbox Triage (Single Keys)
        .shared("triageSave", as: "inboxSave"),
        .shared("triageSaveAndStar", as: "inboxSaveAndStar"),
        .shared("triageToggleStar", as: "inboxToggleStar"),
        .shared("triageDismiss", as: "inboxDismiss"),
        .shared("triageMarkRead", as: "inboxMarkRead"),
        .shared("triageMarkUnread", as: "inboxMarkUnread"),
        .shared("triageNextItem", as: "inboxNextItem"),
        .shared("triagePreviousItem", as: "inboxPreviousItem"),
        .shared("triageOpenItem", as: "inboxOpenItem"),
        // MARK: Flags & Tags
        .shared("flagMode"),
        .shared("tagMode"),
        .shared("tagDeleteMode"),
        .shared("filterMode"),
        // MARK: PDF Viewer
        .own(KeyboardShortcutBinding(
            id: "pdfPageDown",
            displayName: "Page Down",
            category: .pdfViewer,
            key: .special(.space),
            modifiers: .none,
            notificationName: "pdfPageDown"
        )),
        .own(KeyboardShortcutBinding(
            id: "pdfPageUp",
            displayName: "Page Up",
            category: .pdfViewer,
            key: .special(.space),
            modifiers: .shift,
            notificationName: "pdfPageUp"
        )),
        .own(KeyboardShortcutBinding(
            id: "pdfZoomIn",
            displayName: "Zoom In",
            category: .pdfViewer,
            key: .special(.plus),
            modifiers: [.command, .shift],
            notificationName: "pdfZoomIn"
        )),
        .own(KeyboardShortcutBinding(
            id: "pdfZoomOut",
            displayName: "Zoom Out",
            category: .pdfViewer,
            key: .special(.minus),
            modifiers: [.command, .shift],
            notificationName: "pdfZoomOut"
        )),
        .own(KeyboardShortcutBinding(
            id: "pdfGoToPage",
            displayName: "Go to Page",
            category: .pdfViewer,
            key: .character("g"),
            modifiers: .command,
            notificationName: "pdfGoToPage"
        )),
        // MARK: File Operations
        .own(KeyboardShortcutBinding(
            id: "importBibTeX",
            displayName: "Import BibTeX",
            category: .fileOperations,
            key: .character("i"),
            modifiers: .command,
            notificationName: "importBibTeX"
        )),
        .own(KeyboardShortcutBinding(
            id: "exportBibTeX",
            displayName: "Export Library",
            category: .fileOperations,
            key: .character("e"),
            modifiers: [.shift, .command],
            notificationName: "exportBibTeX"
        )),
        .shared("refreshData"),
        // MARK: App
        .shared("showKeyboardShortcuts"),
        .own(KeyboardShortcutBinding(
            id: "showNLSearch",
            displayName: "Smart Search (AI)",
            category: .app,
            key: .character("s"),
            modifiers: .command,
            notificationName: "showNLSearch"
        )),
    ]

    /// Default keyboard shortcuts — resolved from the shared catalog.
    public static let defaults = KeyboardShortcutsSettings(
        bindings: ShortcutCatalog.resolve(profile)
    )

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
