//
//  ShortcutCatalog.swift
//  ImpressKeyboard
//
//  The suite-wide keyboard *binding table* as DATA — the third leg of the
//  keyboard grammar alongside `TriageKeyGrammar` (which key means what) and
//  `UniversalShortcut` (the semantic ⌘ layer). This file answers the question
//  neither of those does: what is the full, customizable, settings-visible list
//  of bindings an impress app ships with?
//
//  Before Stage 1b that list was a ~600-line literal inside imbib's
//  `KeyboardShortcutsSettings` — a SECOND catalog, invisible to every sibling.
//  impart had grown a third (`ImpartKeyboardShortcuts`), and the two had
//  already diverged on `s` (imbib: toggle star, impart: save). One vocabulary
//  in one place is the only thing that stops that.
//
//  Shape: `shared` holds the suite-neutral entries keyed by SEMANTIC id
//  ("navigateNextItem"). An app declares a *profile* — an ordered list that
//  adopts shared entries (pinning its own persisted id / label / notification
//  where its domain nouns differ) and splices in its app-specific entries.
//  Keys and modifiers therefore live in exactly one place; ids stay stable so
//  users' saved remaps survive.
//
//  docs/keyboard-grammar.md is the human-readable mirror.
//

import Foundation
import SwiftUI

// MARK: - Shortcut Category

/// Categories for organizing keyboard shortcuts in the settings UI.
///
/// `allCases` order IS the settings section order; empty sections are hidden by
/// the UI, so an app that uses only a subset renders only that subset.
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

// MARK: - Keyboard Shortcut Binding

/// A single, customizable keyboard shortcut binding.
public struct KeyboardShortcutBinding: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier. User customizations are persisted against this, so it
    /// must never change for an existing binding.
    public let id: String

    /// Display name shown in settings.
    public let displayName: String

    /// Category for grouping in the UI.
    public let category: ShortcutCategory

    /// The key for this shortcut.
    public var key: ShortcutKey

    /// Modifier keys (command, shift, option, control).
    public var modifiers: ShortcutModifiers

    /// Notification name to post when triggered.
    public let notificationName: String

    /// Whether this shortcut can be customized.
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

    /// Full display string including modifiers and key, e.g. "⇧⌘C".
    public var displayShortcut: String {
        modifiers.displayString + key.displayString
    }

    /// Apply this shortcut to a SwiftUI Button.
    public func keyboardShortcut() -> KeyboardShortcut {
        KeyboardShortcut(key.keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    /// Check if this binding matches a `KeyPress` event.
    /// Used for `.onKeyPress` / `.keyboardGuarded` handlers so customized
    /// shortcuts are honoured.
    public func matches(_ press: KeyPress) -> Bool {
        let keyMatches: Bool
        var isShiftedSymbol = false
        switch key {
        case .character(let char):
            keyMatches = press.characters.lowercased() == char.lowercased()
            // Symbols like *, !, @, # require Shift to type but Shift isn't a
            // semantic modifier — it's just how the character is produced.
            // Strip Shift from comparison for non-letter characters.
            if keyMatches {
                let scalar = char.unicodeScalars.first
                let isLetter = scalar.map { CharacterSet.letters.contains($0) } ?? false
                if !isLetter { isShiftedSymbol = true }
            }
        case .special(let special):
            keyMatches = press.key == special.keyEquivalent
        }
        guard keyMatches else { return false }
        var pressModifiers = ShortcutModifiers(press.modifiers)
        if isShiftedSymbol { pressModifiers.remove(.shift) }
        return pressModifiers == modifiers
    }
}

// MARK: - Profile Item

/// One line of an app's shortcut profile: either an adoption of a shared
/// catalog entry (optionally refined) or an app-specific binding.
public struct ShortcutProfileItem: Sendable {
    enum Kind: Sendable {
        case adopt(sharedID: String, refinement: Refinement)
        case own(KeyboardShortcutBinding)
    }

    struct Refinement: Sendable {
        var id: String?
        var displayName: String?
        var category: ShortcutCategory?
        var key: ShortcutKey?
        var modifiers: ShortcutModifiers?
        var notificationName: String?
        var isCustomizable: Bool?
    }

    let kind: Kind

    /// Adopt the shared entry `sharedID`.
    ///
    /// - Parameters:
    ///   - id: the app's persisted identifier, when it differs from the shared
    ///     semantic id (e.g. imbib stores `navigateNextItem` as
    ///     `navigateNextPaper`). `notificationName` defaults to this.
    ///   - displayName: the app's domain noun ("Next Paper" vs "Next Item").
    ///   - key / modifiers / category: refine only with a documented reason —
    ///     diverging here is what the shared catalog exists to prevent.
    public static func shared(
        _ sharedID: String,
        as id: String? = nil,
        displayName: String? = nil,
        category: ShortcutCategory? = nil,
        key: ShortcutKey? = nil,
        modifiers: ShortcutModifiers? = nil,
        notificationName: String? = nil,
        isCustomizable: Bool? = nil
    ) -> ShortcutProfileItem {
        ShortcutProfileItem(kind: .adopt(
            sharedID: sharedID,
            refinement: Refinement(
                id: id,
                displayName: displayName,
                category: category,
                key: key,
                modifiers: modifiers,
                notificationName: notificationName,
                isCustomizable: isCustomizable
            )
        ))
    }

    /// An app-specific binding with no shared-catalog counterpart.
    public static func own(_ binding: KeyboardShortcutBinding) -> ShortcutProfileItem {
        ShortcutProfileItem(kind: .own(binding))
    }
}

// MARK: - The Catalog

public enum ShortcutCatalog {

    /// Convenience builder: `notificationName` defaults to `id`, the convention
    /// the overwhelming majority of suite bindings already follow.
    private static func entry(
        _ id: String,
        _ displayName: String,
        _ category: ShortcutCategory,
        _ key: ShortcutKey,
        _ modifiers: ShortcutModifiers = .none,
        notificationName: String? = nil
    ) -> KeyboardShortcutBinding {
        KeyboardShortcutBinding(
            id: id,
            displayName: displayName,
            category: category,
            key: key,
            modifiers: modifiers,
            notificationName: notificationName ?? id
        )
    }

    /// THE suite-wide vocabulary. Entries here are the ones a sibling app would
    /// bind to the same key for the same reason; app-domain bindings (imbib's
    /// BibTeX import, impart's Reply) belong in the app's profile, not here.
    public static let shared: [KeyboardShortcutBinding] = [

        // MARK: Navigation — the guarded vim layer (mirrors TriageKeyGrammar)
        entry("navigateDown", "Down (Vim)", .navigation, .character("j")),
        entry("navigateUp", "Up (Vim)", .navigation, .character("k")),
        entry("cycleFocusLeft", "Focus Left Pane", .navigation, .character("h")),
        entry("cycleFocusRight", "Focus Right Pane", .navigation, .character("l")),

        // MARK: Navigation — arrow/chord list movement
        entry("navigateNextItem", "Next Item", .navigation, .special(.downArrow)),
        entry("navigatePreviousItem", "Previous Item", .navigation, .special(.upArrow)),
        entry("navigateFirstItem", "First Item", .navigation, .special(.upArrow), .command),
        entry("navigateLastItem", "Last Item", .navigation, .special(.downArrow), .command),
        entry("navigateNextUnread", "Next Unread", .navigation, .special(.downArrow), .option),
        entry("navigatePreviousUnread", "Previous Unread", .navigation, .special(.upArrow), .option),
        entry("navigateNextUnreadVim", "Next Unread (Vim)", .navigation, .character("j"), .option,
              notificationName: "navigateNextUnread"),
        entry("navigatePreviousUnreadVim", "Previous Unread (Vim)", .navigation, .character("k"), .option,
              notificationName: "navigatePreviousUnread"),
        entry("openSelectedItem", "Open Item", .navigation, .special(.return)),

        // MARK: Views — the UniversalShortcut ⌘ layer
        entry("primaryView1", "Primary View 1", .views, .character("1"), .command),
        entry("primaryView2", "Primary View 2", .views, .character("2"), .command),
        entry("primaryView3", "Primary View 3", .views, .character("3"), .command),
        entry("toggleDetailPane", "Toggle Detail Pane", .views, .character("0"), .command),
        entry("toggleSidebar", "Toggle Sidebar", .views, .character("s"), [.control, .command]),

        // MARK: Focus — the three-pane chassis
        entry("focusSidebar", "Focus Sidebar", .focus, .character("1"), [.option, .command]),
        entry("focusList", "Focus List", .focus, .character("2"), [.option, .command]),
        entry("focusDetail", "Focus Detail", .focus, .character("3"), [.option, .command]),
        entry("focusSearch", "Focus Search Field", .focus, .character("f"), .command),

        // MARK: Clipboard — OS conventions, suite-wide
        entry("copyItems", "Copy", .clipboard, .character("c"), .command),
        entry("copyItemsAsCitation", "Copy as Citation", .clipboard, .character("c"), [.shift, .command]),
        entry("copyItemIdentifier", "Copy Identifier", .clipboard, .character("c"), [.option, .command]),
        entry("cutItems", "Cut", .clipboard, .character("x"), .command),
        entry("pasteItems", "Paste", .clipboard, .character("v"), .command),
        entry("selectAllItems", "Select All", .clipboard, .character("a"), .command),

        // MARK: Triage — the single-key layer (ADR-0021 / Stage 3)
        // `s` = star and `d` = dismiss in EVERY impress list. imbib's
        // historical s=save moved to `*` (the old star key) — a one-swap
        // change; both actions stay single keys, and user-remapped bindings are
        // preserved by the settings merge.
        entry("triageSave", "Save", .inboxTriage, .character("*")),
        entry("triageSaveAndStar", "Save and Star", .inboxTriage, .character("s"), .shift),
        entry("triageToggleStar", "Toggle Star", .inboxTriage, .character("s")),
        entry("triageDismiss", "Dismiss", .inboxTriage, .character("d")),
        entry("triageMarkRead", "Mark as Read", .inboxTriage, .character("r")),
        entry("triageMarkUnread", "Mark as Unread", .inboxTriage, .character("u")),
        entry("triageNextItem", "Next (Vim)", .inboxTriage, .character("j")),
        entry("triagePreviousItem", "Previous (Vim)", .inboxTriage, .character("k")),
        entry("triageOpenItem", "Open (Vim)", .inboxTriage, .character("o")),

        // MARK: Flags & tags — the ImpressFTUI modal layer
        entry("flagMode", "Flag Mode", .paperActions, .character("f"),
              notificationName: "enterFlagMode"),
        entry("tagMode", "Tag Mode", .paperActions, .character("t"),
              notificationName: "enterTagMode"),
        entry("tagDeleteMode", "Tag Delete Mode", .paperActions, .character("t"), .shift,
              notificationName: "enterTagDeleteMode"),
        entry("filterMode", "Filter Mode", .paperActions, .character("/"),
              notificationName: "enterFilterMode"),

        // MARK: App
        entry("refreshData", "Refresh", .fileOperations, .character("n"), [.shift, .command]),
        entry("showKeyboardShortcuts", "Keyboard Shortcuts", .app, .character("/"), .command),
    ]

    private static let sharedByID: [String: KeyboardShortcutBinding] =
        Dictionary(uniqueKeysWithValues: shared.map { ($0.id, $0) })

    /// A shared catalog entry by its semantic id.
    public static func sharedEntry(_ id: String) -> KeyboardShortcutBinding? {
        sharedByID[id]
    }

    /// Resolve an app's profile into its concrete binding list, in profile order.
    ///
    /// An adoption of an unknown shared id is a programming error; it trips an
    /// `assertionFailure` in debug and is dropped in release rather than
    /// silently shipping a phantom binding.
    public static func resolve(_ profile: [ShortcutProfileItem]) -> [KeyboardShortcutBinding] {
        profile.compactMap { item in
            switch item.kind {
            case .own(let binding):
                return binding
            case .adopt(let sharedID, let refinement):
                guard let base = sharedByID[sharedID] else {
                    assertionFailure("ShortcutCatalog.shared has no entry '\(sharedID)'")
                    return nil
                }
                let id = refinement.id ?? base.id
                return KeyboardShortcutBinding(
                    id: id,
                    displayName: refinement.displayName ?? base.displayName,
                    category: refinement.category ?? base.category,
                    key: refinement.key ?? base.key,
                    modifiers: refinement.modifiers ?? base.modifiers,
                    // Default the notification to the app's own id: a renamed
                    // binding almost always renames its notification with it.
                    notificationName: refinement.notificationName
                        ?? (refinement.id != nil ? id : base.notificationName),
                    isCustomizable: refinement.isCustomizable ?? base.isCustomizable
                )
            }
        }
    }
}
