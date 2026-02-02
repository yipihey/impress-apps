import Foundation
import SwiftUI

/// Modifier keys for keyboard shortcuts.
///
/// An `OptionSet` representing command, shift, option, and control modifiers.
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

    /// Display string with modifier symbols.
    ///
    /// Uses "Shift+" for shift-only shortcuts (clearer), symbols otherwise.
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

    /// Initialize from SwiftUI EventModifiers
    public init(from eventModifiers: EventModifiers) {
        var result: ShortcutModifiers = []
        if eventModifiers.contains(.command) { result.insert(.command) }
        if eventModifiers.contains(.shift) { result.insert(.shift) }
        if eventModifiers.contains(.option) { result.insert(.option) }
        if eventModifiers.contains(.control) { result.insert(.control) }
        self = result
    }
}
