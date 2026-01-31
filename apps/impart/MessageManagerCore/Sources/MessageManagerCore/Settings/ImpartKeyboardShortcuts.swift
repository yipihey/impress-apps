//
//  ImpartKeyboardShortcuts.swift
//  MessageManagerCore
//
//  Keyboard shortcuts for impart, following imbib's pattern.
//  Consistent with impress suite keyboard conventions.
//

import Foundation
import SwiftUI

// MARK: - Shortcut Category

/// Categories for organizing keyboard shortcuts in the UI.
public enum ImpartShortcutCategory: String, Codable, CaseIterable, Sendable {
    case navigation = "Navigation"
    case viewModes = "View Modes"
    case focus = "Focus"
    case messageActions = "Message Actions"
    case triage = "Triage"
    case compose = "Compose"
    case search = "Search"
    case app = "App"

    public var displayName: String { rawValue }
}

// MARK: - Shortcut Key

/// Represents a keyboard key (character or special key).
public enum ImpartShortcutKey: Codable, Equatable, Hashable, Sendable {
    case character(String)
    case special(SpecialKey)

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
            }
        }

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
            }
        }
    }

    public var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let char):
            return KeyEquivalent(Character(char))
        case .special(let special):
            return special.keyEquivalent
        }
    }

    public var displayString: String {
        switch self {
        case .character(let char):
            return char.lowercased()
        case .special(let special):
            return special.displaySymbol
        }
    }

    public init(from string: String) {
        if let special = SpecialKey(rawValue: string) {
            self = .special(special)
        } else {
            self = .character(string.lowercased())
        }
    }

    public var stringValue: String {
        switch self {
        case .character(let char): return char
        case .special(let special): return special.rawValue
        }
    }
}

// MARK: - Shortcut Modifiers

/// Modifier keys for shortcuts.
public struct ImpartShortcutModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ImpartShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ImpartShortcutModifiers(rawValue: 1 << 1)
    public static let option = ImpartShortcutModifiers(rawValue: 1 << 2)
    public static let control = ImpartShortcutModifiers(rawValue: 1 << 3)

    public static let none: ImpartShortcutModifiers = []

    public var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    public var displayString: String {
        if self == .shift {
            return "Shift+"
        }
        var symbols: [String] = []
        if contains(.control) { symbols.append("⌃") }
        if contains(.option) { symbols.append("⌥") }
        if contains(.shift) { symbols.append("⇧") }
        if contains(.command) { symbols.append("⌘") }
        return symbols.joined()
    }
}

// MARK: - Keyboard Shortcut Binding

/// A single keyboard shortcut binding.
public struct ImpartKeyboardShortcutBinding: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let category: ImpartShortcutCategory
    public var key: ImpartShortcutKey
    public var modifiers: ImpartShortcutModifiers
    public let notificationName: String
    public let isCustomizable: Bool

    public init(
        id: String,
        displayName: String,
        category: ImpartShortcutCategory,
        key: ImpartShortcutKey,
        modifiers: ImpartShortcutModifiers = .none,
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

    public var displayShortcut: String {
        modifiers.displayString + key.displayString
    }

    public func keyboardShortcut() -> KeyboardShortcut {
        KeyboardShortcut(key.keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    public func matches(_ press: KeyPress) -> Bool {
        let keyMatches: Bool
        switch key {
        case .character(let char):
            keyMatches = press.characters.lowercased() == char.lowercased()
        case .special(let special):
            keyMatches = press.key == special.keyEquivalent
        }
        guard keyMatches else { return false }
        return ImpartShortcutModifiers(press.modifiers) == modifiers
    }
}

// MARK: - ShortcutModifiers + KeyPress

extension ImpartShortcutModifiers {
    public init(_ modifiers: EventModifiers) {
        var result: ImpartShortcutModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        self = result
    }
}

// MARK: - Keyboard Shortcuts Settings

/// All keyboard shortcut bindings for impart.
public struct ImpartKeyboardShortcutsSettings: Codable, Equatable, Sendable {
    public var bindings: [ImpartKeyboardShortcutBinding]

    public init(bindings: [ImpartKeyboardShortcutBinding]) {
        self.bindings = bindings
    }

    public func binding(id: String) -> ImpartKeyboardShortcutBinding? {
        bindings.first { $0.id == id }
    }

    public func binding(forNotification name: String) -> ImpartKeyboardShortcutBinding? {
        bindings.first { $0.notificationName == name }
    }

    public func bindings(for category: ImpartShortcutCategory) -> [ImpartKeyboardShortcutBinding] {
        bindings.filter { $0.category == category }
    }

    public mutating func updateBinding(_ binding: ImpartKeyboardShortcutBinding) {
        if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[index] = binding
        }
    }

    // MARK: - Factory Defaults

    public static let defaults = ImpartKeyboardShortcutsSettings(bindings: [
        // MARK: Navigation (Vim-style, consistent with imbib)
        ImpartKeyboardShortcutBinding(
            id: "navigateDown",
            displayName: "Down (Vim)",
            category: .navigation,
            key: .character("j"),
            modifiers: .none,
            notificationName: "navigateNextMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "navigateUp",
            displayName: "Up (Vim)",
            category: .navigation,
            key: .character("k"),
            modifiers: .none,
            notificationName: "navigatePreviousMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "cycleFocusLeft",
            displayName: "Focus Left Pane",
            category: .navigation,
            key: .character("h"),
            modifiers: .none,
            notificationName: "cycleFocusLeft"
        ),
        ImpartKeyboardShortcutBinding(
            id: "cycleFocusRight",
            displayName: "Focus Right Pane",
            category: .navigation,
            key: .character("l"),
            modifiers: .none,
            notificationName: "cycleFocusRight"
        ),
        ImpartKeyboardShortcutBinding(
            id: "navigateNextMessage",
            displayName: "Next Message",
            category: .navigation,
            key: .special(.downArrow),
            modifiers: .none,
            notificationName: "navigateNextMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "navigatePreviousMessage",
            displayName: "Previous Message",
            category: .navigation,
            key: .special(.upArrow),
            modifiers: .none,
            notificationName: "navigatePreviousMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "openMessage",
            displayName: "Open Message",
            category: .navigation,
            key: .special(.return),
            modifiers: .none,
            notificationName: "openMessage"
        ),

        // MARK: View Modes
        ImpartKeyboardShortcutBinding(
            id: "showEmailView",
            displayName: "Email View",
            category: .viewModes,
            key: .character("1"),
            modifiers: .command,
            notificationName: "switchToEmailView"
        ),
        ImpartKeyboardShortcutBinding(
            id: "showChatView",
            displayName: "Chat View",
            category: .viewModes,
            key: .character("2"),
            modifiers: .command,
            notificationName: "switchToChatView"
        ),
        ImpartKeyboardShortcutBinding(
            id: "showCategoryView",
            displayName: "Category View",
            category: .viewModes,
            key: .character("3"),
            modifiers: .command,
            notificationName: "switchToCategoryView"
        ),
        ImpartKeyboardShortcutBinding(
            id: "toggleThreads",
            displayName: "Toggle Threads",
            category: .viewModes,
            key: .character("t"),
            modifiers: .command,
            notificationName: "toggleThreads"
        ),

        // MARK: Focus
        ImpartKeyboardShortcutBinding(
            id: "focusSidebar",
            displayName: "Focus Sidebar",
            category: .focus,
            key: .character("1"),
            modifiers: [.option, .command],
            notificationName: "focusSidebar"
        ),
        ImpartKeyboardShortcutBinding(
            id: "focusList",
            displayName: "Focus List",
            category: .focus,
            key: .character("2"),
            modifiers: [.option, .command],
            notificationName: "focusList"
        ),
        ImpartKeyboardShortcutBinding(
            id: "focusDetail",
            displayName: "Focus Detail",
            category: .focus,
            key: .character("3"),
            modifiers: [.option, .command],
            notificationName: "focusDetail"
        ),

        // MARK: Triage (Single Keys - impart's core workflow)
        ImpartKeyboardShortcutBinding(
            id: "triageDismiss",
            displayName: "Dismiss/Archive",
            category: .triage,
            key: .character("d"),
            modifiers: .none,
            notificationName: "dismissMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "triageSave",
            displayName: "Save/Keep",
            category: .triage,
            key: .character("s"),
            modifiers: .none,
            notificationName: "saveMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "triageToggleStar",
            displayName: "Toggle Star",
            category: .triage,
            key: .character("s"),
            modifiers: .shift,
            notificationName: "toggleStar"
        ),
        ImpartKeyboardShortcutBinding(
            id: "triageMarkRead",
            displayName: "Mark as Read",
            category: .triage,
            key: .character("r"),
            modifiers: .none,
            notificationName: "markRead"
        ),
        ImpartKeyboardShortcutBinding(
            id: "triageMarkUnread",
            displayName: "Mark as Unread",
            category: .triage,
            key: .character("u"),
            modifiers: .none,
            notificationName: "markUnread"
        ),

        // MARK: Message Actions
        ImpartKeyboardShortcutBinding(
            id: "reply",
            displayName: "Reply",
            category: .messageActions,
            key: .character("r"),
            modifiers: .command,
            notificationName: "replyToMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "replyAll",
            displayName: "Reply All",
            category: .messageActions,
            key: .character("r"),
            modifiers: [.shift, .command],
            notificationName: "replyAllToMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "forward",
            displayName: "Forward",
            category: .messageActions,
            key: .character("f"),
            modifiers: [.shift, .command],
            notificationName: "forwardMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "delete",
            displayName: "Delete",
            category: .messageActions,
            key: .special(.delete),
            modifiers: .command,
            notificationName: "deleteMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "moveToFolder",
            displayName: "Move to Folder",
            category: .messageActions,
            key: .character("m"),
            modifiers: .command,
            notificationName: "moveToFolder"
        ),

        // MARK: Compose
        ImpartKeyboardShortcutBinding(
            id: "newMessage",
            displayName: "New Message",
            category: .compose,
            key: .character("n"),
            modifiers: .command,
            notificationName: "newMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "sendMessage",
            displayName: "Send Message",
            category: .compose,
            key: .character("d"),
            modifiers: [.shift, .command],
            notificationName: "sendMessage"
        ),
        ImpartKeyboardShortcutBinding(
            id: "saveDraft",
            displayName: "Save Draft",
            category: .compose,
            key: .character("s"),
            modifiers: .command,
            notificationName: "saveDraft"
        ),

        // MARK: Search
        ImpartKeyboardShortcutBinding(
            id: "focusSearch",
            displayName: "Search",
            category: .search,
            key: .character("f"),
            modifiers: .command,
            notificationName: "focusSearch"
        ),
        ImpartKeyboardShortcutBinding(
            id: "globalSearch",
            displayName: "Global Search",
            category: .search,
            key: .character("f"),
            modifiers: [.shift, .command],
            notificationName: "globalSearch"
        ),

        // MARK: App
        ImpartKeyboardShortcutBinding(
            id: "refresh",
            displayName: "Refresh",
            category: .app,
            key: .character("r"),
            modifiers: [.shift, .command],
            notificationName: "refresh"
        ),
        ImpartKeyboardShortcutBinding(
            id: "showSettings",
            displayName: "Settings",
            category: .app,
            key: .character(","),
            modifiers: .command,
            notificationName: "showSettings"
        ),
        ImpartKeyboardShortcutBinding(
            id: "showKeyboardShortcuts",
            displayName: "Keyboard Shortcuts",
            category: .app,
            key: .character("/"),
            modifiers: .command,
            notificationName: "showKeyboardShortcuts"
        ),
    ])
}

// MARK: - Keyboard Shortcuts Store

/// Observable store for keyboard shortcuts.
@MainActor
@Observable
public final class ImpartKeyboardShortcutsStore {
    public static let shared = ImpartKeyboardShortcutsStore()

    public var settings: ImpartKeyboardShortcutsSettings

    private let userDefaultsKey = "com.impart.keyboardShortcuts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let settings = try? JSONDecoder().decode(ImpartKeyboardShortcutsSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = .defaults
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    public func resetToDefaults() {
        settings = .defaults
        save()
    }

    /// Get binding by notification name.
    public func binding(forNotification name: String) -> ImpartKeyboardShortcutBinding? {
        settings.binding(forNotification: name)
    }

    /// Check if a key press matches any shortcut.
    public func matchingBinding(for press: KeyPress) -> ImpartKeyboardShortcutBinding? {
        settings.bindings.first { $0.matches(press) }
    }
}
