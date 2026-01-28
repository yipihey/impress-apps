//
//  HelixState.swift
//  ImpressHelixCore
//
//  Observable wrapper around FfiHelixEditor for SwiftUI integration.
//

import SwiftUI
import Combine

/// Observable state wrapper for the Helix modal editor.
///
/// This class wraps `FfiHelixEditor` and publishes mode changes for SwiftUI views.
/// Use it as a `@StateObject` or `@ObservedObject` in your views.
@MainActor
public final class HelixState: ObservableObject {
    /// The underlying FFI editor instance
    private let editor: FfiHelixEditor

    /// Current editing mode (normal, insert, select)
    @Published public private(set) var mode: FfiHelixMode = .normal

    /// Whether search mode is currently active
    @Published public private(set) var isSearching: Bool = false

    /// Current search query text
    @Published public private(set) var searchQuery: String = ""

    /// Whether space-mode menu is showing
    @Published public private(set) var isSpaceMode: Bool = false

    /// Available keys in space-mode
    @Published public private(set) var spaceModeKeys: [FfiWhichKeyItem] = []

    /// Whether awaiting a character input (f/t/r operations)
    @Published public private(set) var isAwaitingCharacter: Bool = false

    /// Whether awaiting a motion (operator pending)
    @Published public private(set) var isAwaitingMotion: Bool = false

    /// Register (clipboard) content
    @Published public private(set) var registerContent: String = ""

    /// Create a new Helix state instance
    public init() {
        self.editor = FfiHelixEditor()
        syncState()
    }

    /// Handle a key press and return the result.
    ///
    /// - Parameters:
    ///   - key: The key character as a string
    ///   - modifiers: Key modifiers (shift, control, alt)
    /// - Returns: The result indicating what action should be taken
    public func handleKey(_ key: String, modifiers: FfiKeyModifiers = .none) -> FfiKeyResult {
        let result = editor.handleKey(key: key, modifiers: modifiers)
        syncState()
        return result
    }

    /// Reset the editor to normal mode
    public func reset() {
        editor.reset()
        syncState()
    }

    /// Exit space-mode
    public func exitSpaceMode() {
        editor.exitSpaceMode()
        syncState()
    }

    /// Sync published properties with the editor state
    private func syncState() {
        mode = editor.mode()
        isSearching = editor.isSearching()
        searchQuery = editor.searchQuery()
        isSpaceMode = editor.isSpaceMode()
        spaceModeKeys = editor.spaceModeAvailableKeys()
        isAwaitingCharacter = editor.isAwaitingCharacter()
        isAwaitingMotion = editor.isAwaitingMotion()
        registerContent = editor.registerContent()
    }
}
