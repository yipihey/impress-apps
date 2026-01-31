//
//  ViewModeTypes.swift
//  MessageManagerCore
//
//  View mode types for impart's three-mode display system.
//

import Foundation
import SwiftUI

// MARK: - Message View Mode

/// Main view modes for displaying messages.
public enum MessageViewMode: String, CaseIterable, Sendable {
    /// Traditional email list with optional threading.
    case email

    /// Chat bubble layout, conversation-grouped, most recent first.
    case chat

    /// Split view: conversations vs broadcasts.
    case category

    /// AI research conversations with counsel.
    case research

    /// Display name for UI.
    public var displayName: String {
        switch self {
        case .email: return "Email"
        case .chat: return "Chat"
        case .category: return "Category"
        case .research: return "Research"
        }
    }

    /// SF Symbol for UI.
    public var iconName: String {
        switch self {
        case .email: return "envelope"
        case .chat: return "bubble.left.and.bubble.right"
        case .category: return "tray.2"
        case .research: return "brain.head.profile"
        }
    }

    /// Keyboard shortcut (⌘1, ⌘2, ⌘3, ⌘4).
    public var keyboardShortcut: KeyEquivalent {
        switch self {
        case .email: return "1"
        case .chat: return "2"
        case .category: return "3"
        case .research: return "4"
        }
    }
}

// MARK: - Category Filter

/// Filter for category view mode.
public enum CategoryFilter: String, CaseIterable, Sendable {
    case all
    case conversations
    case broadcasts

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .conversations: return "Conversations"
        case .broadcasts: return "Broadcasts"
        }
    }

    public var iconName: String {
        switch self {
        case .all: return "tray"
        case .conversations: return "person.2"
        case .broadcasts: return "megaphone"
        }
    }
}

// MARK: - View Mode State

/// Observable state for view mode management.
@MainActor
@Observable
public final class ViewModeState {
    /// Current view mode.
    public var mode: MessageViewMode = .email

    /// Category filter (only used in category mode).
    public var categoryFilter: CategoryFilter = .all

    /// Whether to show threads in email mode.
    public var showThreads: Bool = true

    /// Whether to group by conversation in chat mode.
    public var groupByConversation: Bool = true

    public init() {}

    /// Switch to a specific view mode.
    public func switchTo(_ newMode: MessageViewMode) {
        mode = newMode
    }

    /// Cycle to next view mode.
    public func cycleMode() {
        let allModes = MessageViewMode.allCases
        guard let currentIndex = allModes.firstIndex(of: mode) else { return }
        let nextIndex = (currentIndex + 1) % allModes.count
        mode = allModes[nextIndex]
    }
}

// MARK: - Sort Order

/// Message list sort order.
public enum MessageSortOrder: String, CaseIterable, Sendable {
    case dateDescending
    case dateAscending
    case senderAZ
    case senderZA
    case subjectAZ
    case subjectZA

    public var displayName: String {
        switch self {
        case .dateDescending: return "Date (Newest First)"
        case .dateAscending: return "Date (Oldest First)"
        case .senderAZ: return "Sender (A-Z)"
        case .senderZA: return "Sender (Z-A)"
        case .subjectAZ: return "Subject (A-Z)"
        case .subjectZA: return "Subject (Z-A)"
        }
    }

    public var iconName: String {
        switch self {
        case .dateDescending: return "arrow.down"
        case .dateAscending: return "arrow.up"
        case .senderAZ, .subjectAZ: return "textformat.abc"
        case .senderZA, .subjectZA: return "textformat.abc"
        }
    }
}

// MARK: - Selection State

/// Message selection state for keyboard navigation.
@MainActor
@Observable
public final class MessageSelectionState {
    /// Currently selected message IDs.
    public var selectedIds: Set<UUID> = []

    /// Focused message ID (for keyboard navigation).
    public var focusedId: UUID?

    public init() {}

    /// Select a single message.
    public func select(_ id: UUID) {
        selectedIds = [id]
        focusedId = id
    }

    /// Toggle selection of a message.
    public func toggle(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        focusedId = id
    }

    /// Extend selection to include a message.
    public func extend(to id: UUID) {
        selectedIds.insert(id)
        focusedId = id
    }

    /// Clear selection.
    public func clear() {
        selectedIds.removeAll()
        focusedId = nil
    }

    /// Whether a message is selected.
    public func isSelected(_ id: UUID) -> Bool {
        selectedIds.contains(id)
    }
}
