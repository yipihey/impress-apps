import Foundation
import SwiftUI

/// Represents a keyboard key (character or special key).
///
/// Used across Impress apps for consistent keyboard shortcut handling.
public enum ShortcutKey: Codable, Equatable, Hashable, Sendable {
    case character(String)      // Single character like "a", "1", "/"
    case special(SpecialKey)    // Special keys like return, delete, arrows

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
        case home = "home"
        case end = "end"
        case pageUp = "pageUp"
        case pageDown = "pageDown"
        case plus = "plus"          // For ⌘+ zoom
        case minus = "minus"        // For ⌘- zoom

        /// SwiftUI KeyEquivalent for this special key
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
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .plus: return KeyEquivalent("+")
            case .minus: return KeyEquivalent("-")
            }
        }

        /// Display symbol for this special key
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
            case .home: return "↖"
            case .end: return "↘"
            case .pageUp: return "⇞"
            case .pageDown: return "⇟"
            case .plus: return "+"
            case .minus: return "-"
            }
        }
    }

    /// SwiftUI KeyEquivalent for this key
    public var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let char):
            return KeyEquivalent(Character(char))
        case .special(let special):
            return special.keyEquivalent
        }
    }

    /// Display string for the key (lowercase for clarity)
    public var displayString: String {
        switch self {
        case .character(let char):
            return char.lowercased()
        case .special(let special):
            return special.displaySymbol
        }
    }

    /// Create from a string representation
    public init(from string: String) {
        if let special = SpecialKey(rawValue: string) {
            self = .special(special)
        } else {
            self = .character(string.lowercased())
        }
    }

    /// String representation for storage
    public var stringValue: String {
        switch self {
        case .character(let char): return char
        case .special(let special): return special.rawValue
        }
    }
}
