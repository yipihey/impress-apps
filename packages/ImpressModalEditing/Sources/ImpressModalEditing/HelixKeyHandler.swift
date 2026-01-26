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
    /// Need to enter search mode with a UI prompt.
    case enterSearch(backward: Bool)
    /// Waiting for character input (for f/t/r commands).
    case awaitingCharacter
}

/// Type of pending operation that expects a character.
public enum PendingCharacterOperation: Sendable, Equatable {
    case findForward      // f
    case findBackward     // F
    case tillForward      // t
    case tillBackward     // T
    case replace          // r
}

/// Handles key events and translates them to Helix commands.
@MainActor
public final class HelixKeyHandler: ObservableObject {
    /// Pending key for multi-key sequences (e.g., "g" in "gg").
    @Published public private(set) var pendingKey: Character?

    /// Current count prefix for repeated commands (e.g., "3j" for move down 3 lines).
    @Published public private(set) var countPrefix: Int?

    /// Pending operation waiting for a character input (f, t, r commands).
    @Published public private(set) var pendingCharOp: PendingCharacterOperation?

    /// Last find character command for ; and , repeat.
    @Published public private(set) var lastFindOp: (Character, PendingCharacterOperation)?

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

        // Handle pending character operation (f, t, r waiting for character)
        if let op = pendingCharOp {
            pendingCharOp = nil
            let count = countPrefix ?? 1
            countPrefix = nil
            return handleCharacterInput(key, operation: op, count: count)
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
        pendingCharOp = nil
    }

    // MARK: - Private

    private func handleCharacterInput(_ char: Character, operation: PendingCharacterOperation, count: Int) -> HelixKeyResult {
        // Store for repeat
        lastFindOp = (char, operation)

        switch operation {
        case .findForward:
            return .command(.findCharacter(char: char, count: count))
        case .findBackward:
            return .command(.findCharacterBackward(char: char, count: count))
        case .tillForward:
            return .command(.tillCharacter(char: char, count: count))
        case .tillBackward:
            return .command(.tillCharacterBackward(char: char, count: count))
        case .replace:
            return .command(.replaceCharacter(char: char))
        }
    }

    private func handleSingleKey(_ key: Character, count: Int, mode: HelixMode, modifiers: KeyModifiers) -> HelixKeyResult {
        switch key {
        // Mode changes
        case "i":
            return .command(.enterInsertMode)
        case "\u{1B}": // Escape
            return .command(.enterNormalMode)
        case "v":
            return mode == .select ? .command(.enterNormalMode) : .command(.enterSelectMode)

        // Insert mode variants
        case "a":
            return .command(.appendAfterCursor)
        case "A":
            return .command(.appendAtLineEnd)
        case "I":
            return .command(.insertAtLineStart)
        case "o":
            return .command(.openLineBelow)
        case "O":
            return .command(.openLineAbove)
        case "s":
            return .command(.substitute)

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
        case "e":
            return .command(.wordEnd(count: count))
        case "0":
            return .command(.lineStart)
        case "^":
            return .command(.lineFirstNonBlank)
        case "$":
            return .command(.lineEnd)

        // Find character (await next character)
        case "f":
            pendingCharOp = .findForward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "F":
            pendingCharOp = .findBackward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "t":
            pendingCharOp = .tillForward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "T":
            pendingCharOp = .tillBackward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter

        // Repeat find
        case ";":
            return .command(.repeatFind)
        case ",":
            return .command(.repeatFindReverse)

        // Search
        case "/":
            return .enterSearch(backward: false)
        case "?":
            return .enterSearch(backward: true)
        case "n":
            return .command(.searchNext(count: count))
        case "N":
            return .command(.searchPrevious(count: count))

        // Multi-key sequences (start)
        case "g":
            pendingKey = "g"
            return .pending
        case "r":
            pendingCharOp = .replace
            return .awaitingCharacter

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
        case "J":
            return .command(.joinLines)
        case "~":
            return .command(.toggleCase)
        case ">":
            return .command(.indent)
        case "<":
            return .command(.dedent)

        // Repeat
        case ".":
            return .command(.repeatLastChange)

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
        case ("g", "e"):
            // ge - go to end of previous word (backward word end)
            return .command(.wordBackward(count: count))
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
