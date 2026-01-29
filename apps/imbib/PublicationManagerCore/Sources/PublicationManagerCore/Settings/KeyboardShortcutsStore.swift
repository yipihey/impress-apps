//
//  KeyboardShortcutsStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import Foundation
import OSLog
import SwiftUI

// MARK: - Keyboard Shortcuts Store

/// Actor for managing keyboard shortcut settings with persistence.
@MainActor
@Observable
public final class KeyboardShortcutsStore {

    // MARK: - Singleton

    public static let shared = KeyboardShortcutsStore()

    // MARK: - Observable State

    public private(set) var settings: KeyboardShortcutsSettings

    // MARK: - Private Properties

    private let userDefaults: UserDefaults
    private let storageKey = "keyboardShortcutsSettings"
    private let logger = Logger.settings

    // MARK: - Notification

    /// Posted when keyboard shortcuts settings change
    public static let didChangeNotification = Notification.Name("KeyboardShortcutsDidChange")

    // MARK: - Initialization

    private init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
        self.settings = Self.load(from: userDefaults, key: storageKey)
        logger.info("KeyboardShortcutsStore initialized with \(self.settings.bindings.count) shortcuts")
    }

    // MARK: - Public API

    /// Update the entire settings object
    public func update(_ newSettings: KeyboardShortcutsSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        save()
        postChangeNotification()
        logger.info("Keyboard shortcuts updated")
    }

    /// Update a single binding
    public func updateBinding(_ binding: KeyboardShortcutBinding) {
        var updated = settings
        updated.updateBinding(binding)
        update(updated)
    }

    /// Reset all shortcuts to defaults
    public func resetToDefaults() {
        update(.defaults)
        logger.info("Keyboard shortcuts reset to defaults")
    }

    /// Reset a single category to defaults
    public func resetCategory(_ category: ShortcutCategory) {
        let defaultBindings = KeyboardShortcutsSettings.defaults.bindings(for: category)
        var updated = settings

        for defaultBinding in defaultBindings {
            updated.updateBinding(defaultBinding)
        }

        update(updated)
        logger.info("Keyboard shortcuts category '\(category.displayName)' reset to defaults")
    }

    /// Get binding by ID
    public func binding(id: String) -> KeyboardShortcutBinding? {
        settings.binding(id: id)
    }

    /// Get binding by notification name
    public func binding(forNotification name: String) -> KeyboardShortcutBinding? {
        settings.binding(forNotification: name)
    }

    #if os(macOS)
    /// Check if a KeyPress matches a specific shortcut action by ID.
    /// Use this in `.onKeyPress` handlers for customizable vim-style navigation.
    @available(macOS 14.0, *)
    public func matches(_ press: KeyPress, action id: String) -> Bool {
        guard let binding = binding(id: id) else { return false }
        return binding.matches(press)
    }
    #endif

    /// Get all bindings for a category
    public func bindings(for category: ShortcutCategory) -> [KeyboardShortcutBinding] {
        settings.bindings(for: category)
    }

    /// Detect all conflicts in current settings
    public func detectConflicts() -> [(KeyboardShortcutBinding, KeyboardShortcutBinding)] {
        settings.detectConflicts()
    }

    /// Check if assigning a key combination would conflict
    public func wouldConflict(key: ShortcutKey, modifiers: ShortcutModifiers, excluding id: String) -> KeyboardShortcutBinding? {
        settings.conflictsWith(key: key, modifiers: modifiers, excluding: id)
    }

    /// Check if a key combination is reserved by the system
    public func isReservedSystemShortcut(key: ShortcutKey, modifiers: ShortcutModifiers) -> Bool {
        // Reserved system shortcuts that should not be overridden
        let reserved: [(ShortcutKey, ShortcutModifiers)] = [
            (.character("q"), .command),        // Quit
            (.character("h"), .command),        // Hide
            (.character("m"), .command),        // Minimize
            (.special(.tab), .command),         // App Switcher
            (.character("w"), .command),        // Close Window (allow with warning)
            (.character(","), .command),        // Preferences (allow with warning)
        ]

        return reserved.contains { $0.0 == key && $0.1 == modifiers }
    }

    // MARK: - Private Methods

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            userDefaults.set(data, forKey: storageKey)
            logger.debug("Keyboard shortcuts saved to UserDefaults")
        } catch {
            logger.error("Failed to save keyboard shortcuts: \(error.localizedDescription)")
        }
    }

    private static func load(from userDefaults: UserDefaults, key: String) -> KeyboardShortcutsSettings {
        guard let data = userDefaults.data(forKey: key) else {
            return .defaults
        }

        do {
            var loaded = try JSONDecoder().decode(KeyboardShortcutsSettings.self, from: data)

            // Merge with defaults to ensure new shortcuts are included
            loaded = mergeWithDefaults(loaded)

            return loaded
        } catch {
            Logger.settings.error("Failed to load keyboard shortcuts: \(error.localizedDescription)")
            return .defaults
        }
    }

    /// Merge loaded settings with defaults to handle new shortcuts added in updates
    private static func mergeWithDefaults(_ loaded: KeyboardShortcutsSettings) -> KeyboardShortcutsSettings {
        let loadedIds = Set(loaded.bindings.map { $0.id })
        let defaultBindings = KeyboardShortcutsSettings.defaults.bindings

        // Find new bindings that don't exist in loaded settings
        let newBindings = defaultBindings.filter { !loadedIds.contains($0.id) }

        if newBindings.isEmpty {
            return loaded
        }

        // Add new bindings to loaded settings
        var merged = loaded
        merged.bindings.append(contentsOf: newBindings)
        return merged
    }

    private func postChangeNotification() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }
}
