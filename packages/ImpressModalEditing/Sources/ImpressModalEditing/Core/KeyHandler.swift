import Foundation

/// Result of handling a key event.
public enum KeyResult<Command: EditorCommand>: Sendable, Equatable where Command: Equatable {
    /// The key produced a command.
    case command(Command)
    /// The key produced multiple commands.
    case commands([Command])
    /// The key should be passed through to the text view.
    case passThrough
    /// The key is part of a pending sequence.
    case pending
    /// The key was consumed but produced no command.
    case consumed
    /// Need to enter search mode.
    case enterSearch(backward: Bool)
    /// Waiting for character input (for f/t/r commands).
    case awaitingCharacter
}

/// Protocol for key event handlers.
///
/// Key handlers translate key events into commands based on the current mode.
@MainActor
public protocol KeyHandler: AnyObject, ObservableObject {
    associatedtype Mode: EditorMode
    associatedtype Command: EditorCommand

    /// Pending key for multi-key sequences.
    var pendingKey: Character? { get }

    /// Current count prefix for repeated commands.
    var countPrefix: Int? { get }

    /// Whether waiting for a character input (f/t/r commands).
    var isAwaitingCharacter: Bool { get }

    /// Handle a key event in the given mode.
    func handleKey(_ key: Character, in mode: Mode, modifiers: KeyModifiers) -> KeyResult<Command>

    /// Reset any pending state.
    func reset()
}

/// Modifier keys for key events.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    /// Meta key (for Emacs - maps to Option on macOS).
    public static let meta = KeyModifiers(rawValue: 1 << 4)
}

#if canImport(AppKit)
import AppKit

public extension KeyModifiers {
    /// Create from NSEvent modifier flags.
    init(flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option); modifiers.insert(.meta) }
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
        if flags.contains(.alternate) { modifiers.insert(.option); modifiers.insert(.meta) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
#endif
