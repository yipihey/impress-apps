import Foundation

/// Result of handling a key event in Helix mode.
public enum HelixKeyResult: Sendable, Equatable {
    /// The key was handled and produced a command.
    case command(HelixCommand)
    /// The key was handled and produced multiple commands.
    case commands([HelixCommand])
    /// The key should be passed through to the text view (e.g., in insert mode).
    case passThrough
    /// The key is part of a pending sequence (e.g., "g" waiting for "g").
    case pending
    /// The key was consumed but produced no command (e.g., invalid key in normal mode).
    case consumed
}

/// Handles key events and translates them to Helix commands.
@MainActor
public final class HelixKeyHandler: ObservableObject {
    /// Pending key for multi-key sequences (e.g., "g" in "gg").
    @Published public private(set) var pendingKey: Character?

    /// Current count prefix for repeated commands (e.g., "3j" for move down 3 lines).
    @Published public private(set) var countPrefix: Int?

    public init() {}

    /// Handle a key event in the given mode.
    public func handleKey(_ key: Character, in mode: HelixMode, modifiers: KeyModifiers = []) -> HelixKeyResult {
        // In insert mode, only Escape returns to normal mode
        if mode == .insert {
            if key == "\u{1B}" { // Escape
                return .command(.enterNormalMode)
            }
            return .passThrough
        }

        // Handle numeric prefix for count
        if let digit = key.wholeNumberValue, digit > 0 || (countPrefix != nil && digit == 0) {
            countPrefix = (countPrefix ?? 0) * 10 + digit
            return .pending
        }

        let count = countPrefix ?? 1
        defer { countPrefix = nil }

        // Handle pending key sequences
        if let pending = pendingKey {
            pendingKey = nil
            return handlePendingSequence(first: pending, second: key, count: count, mode: mode)
        }

        // Handle single keys
        return handleSingleKey(key, count: count, mode: mode, modifiers: modifiers)
    }

    /// Reset any pending state.
    public func reset() {
        pendingKey = nil
        countPrefix = nil
    }

    // MARK: - Private

    private func handleSingleKey(_ key: Character, count: Int, mode: HelixMode, modifiers: KeyModifiers) -> HelixKeyResult {
        switch key {
        // Mode changes
        case "i":
            return .command(.enterInsertMode)
        case "\u{1B}": // Escape
            return .command(.enterNormalMode)
        case "v":
            return mode == .select ? .command(.enterNormalMode) : .command(.enterSelectMode)

        // Movement
        case "h":
            return .command(.moveLeft(count: count))
        case "j":
            return .command(.moveDown(count: count))
        case "k":
            return .command(.moveUp(count: count))
        case "l":
            return .command(.moveRight(count: count))
        case "w":
            return .command(.wordForward(count: count))
        case "b":
            return .command(.wordBackward(count: count))
        case "0":
            return .command(.lineStart)
        case "$":
            return .command(.lineEnd)

        // Multi-key sequences (start)
        case "g":
            pendingKey = "g"
            return .pending

        // Selection
        case "x":
            return .command(.selectLine)
        case "%":
            return .command(.selectAll)

        // Editing
        case "d":
            return .command(.delete)
        case "y":
            return .command(.yank)
        case "p":
            return .command(.pasteAfter)
        case "P":
            return .command(.pasteBefore)
        case "c":
            return .commands([.delete, .enterInsertMode])

        // Undo/Redo
        case "u":
            return .command(.undo)
        case "U":
            return .command(.redo)

        // G for document end
        case "G":
            return .command(.documentEnd)

        default:
            return .consumed
        }
    }

    private func handlePendingSequence(first: Character, second: Character, count: Int, mode: HelixMode) -> HelixKeyResult {
        switch (first, second) {
        case ("g", "g"):
            return .command(.documentStart)
        default:
            // Invalid sequence, consume both keys
            return .consumed
        }
    }
}

/// Modifier keys for key events.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

#if canImport(AppKit)
import AppKit

public extension KeyModifiers {
    /// Create from NSEvent modifier flags.
    init(flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
#endif

#if canImport(UIKit)
import UIKit

public extension KeyModifiers {
    /// Create from UIKeyModifierFlags.
    init(flags: UIKeyModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
#endif
