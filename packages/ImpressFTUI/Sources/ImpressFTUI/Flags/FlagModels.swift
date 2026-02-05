//
//  FlagModels.swift
//  ImpressFTUI
//

import SwiftUI

// MARK: - Flag Color

/// Workflow flag colors for publication triage.
///
/// Flags represent workflow state (read/review/revisit) — they sync via CloudKit
/// but are NOT exported to BibTeX. Use tags for knowledge categorization.
public enum FlagColor: String, Codable, CaseIterable, Sendable, Hashable {
    case red
    case amber
    case blue
    case gray

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .amber: return "Amber"
        case .blue: return "Blue"
        case .gray: return "Gray"
        }
    }

    /// Keyboard shortcut character for quick flag assignment.
    public var shortcut: Character {
        switch self {
        case .red: return "r"
        case .amber: return "a"
        case .blue: return "b"
        case .gray: return "g"
        }
    }

    /// Default color for light mode.
    public var defaultLightColor: Color {
        switch self {
        case .red: return Color(hex: "E53935")
        case .amber: return Color(hex: "FB8C00")
        case .blue: return Color(hex: "1E88E5")
        case .gray: return Color(hex: "757575")
        }
    }

    /// Default color for dark mode.
    public var defaultDarkColor: Color {
        switch self {
        case .red: return Color(hex: "EF5350")
        case .amber: return Color(hex: "FFA726")
        case .blue: return Color(hex: "42A5F5")
        case .gray: return Color(hex: "9E9E9E")
        }
    }

    /// SF Symbol name for menu display.
    public var systemImage: String {
        switch self {
        case .red: return "flag.fill"
        case .amber: return "flag.fill"
        case .blue: return "flag.fill"
        case .gray: return "flag.fill"
        }
    }
}

// MARK: - Flag Style

/// Visual style for the flag stripe.
public enum FlagStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case solid
    case dashed
    case dotted

    public var displayName: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }

    /// Keyboard shortcut character for style selection.
    public var shortcut: Character {
        switch self {
        case .solid: return "s"
        case .dashed: return "d"
        case .dotted: return "o"
        }
    }
}

// MARK: - Flag Length

/// How much of the row height the flag stripe covers.
public enum FlagLength: String, Codable, CaseIterable, Sendable, Hashable {
    case full
    case half
    case quarter

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .half: return "Half"
        case .quarter: return "Quarter"
        }
    }

    /// Fraction of row height (1.0, 0.5, 0.25).
    public var fraction: CGFloat {
        switch self {
        case .full: return 1.0
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }

    /// Keyboard shortcut character for length selection.
    public var shortcut: Character {
        switch self {
        case .full: return "f"
        case .half: return "h"
        case .quarter: return "q"
        }
    }
}

// MARK: - Publication Flag

/// Complete flag state for a publication.
public struct PublicationFlag: Codable, Equatable, Hashable, Sendable {
    public var color: FlagColor
    public var style: FlagStyle
    public var length: FlagLength

    public init(
        color: FlagColor,
        style: FlagStyle = .solid,
        length: FlagLength = .full
    ) {
        self.color = color
        self.style = style
        self.length = length
    }

    /// Simple flag with just a color (solid, full).
    public static func simple(_ color: FlagColor) -> PublicationFlag {
        PublicationFlag(color: color)
    }
}

// MARK: - Flag Color Config

/// Customizable color configuration for flags.
public struct FlagColorConfig: Codable, Equatable, Sendable {
    public var lightHex: String
    public var darkHex: String
    public var semanticLabel: String

    public init(lightHex: String, darkHex: String, semanticLabel: String) {
        self.lightHex = lightHex
        self.darkHex = darkHex
        self.semanticLabel = semanticLabel
    }

    public static let defaults: [FlagColor: FlagColorConfig] = [
        .red: FlagColorConfig(lightHex: "E53935", darkHex: "EF5350", semanticLabel: "Urgent"),
        .amber: FlagColorConfig(lightHex: "FB8C00", darkHex: "FFA726", semanticLabel: "Review"),
        .blue: FlagColorConfig(lightHex: "1E88E5", darkHex: "42A5F5", semanticLabel: "Read"),
        .gray: FlagColorConfig(lightHex: "757575", darkHex: "9E9E9E", semanticLabel: "Archive"),
    ]
}

// MARK: - Flag Command Parser (Swift, replaced by Rust in Phase 3)

/// Parse a flag shorthand command string.
///
/// Grammar:
/// - `r` → red solid full
/// - `a-h` → amber dashed half
/// - `b.q` → blue dotted quarter
/// - First char: color (r/a/b/g)
/// - Optional second char: style (-=dashed, .=dotted, default=solid)
/// - Optional third char: length (f=full, h=half, q=quarter, default=full)
public func parseFlagCommand(_ input: String) -> PublicationFlag? {
    let chars = Array(input.lowercased())
    guard let first = chars.first else { return nil }

    guard let color = FlagColor.allCases.first(where: { $0.shortcut == first }) else {
        return nil
    }

    var style: FlagStyle = .solid
    var length: FlagLength = .full

    if chars.count > 1 {
        switch chars[1] {
        case "-": style = .dashed
        case ".": style = .dotted
        case "s": style = .solid
        default:
            // Maybe it's a length character
            if let l = FlagLength.allCases.first(where: { $0.shortcut == chars[1] }) {
                length = l
                return PublicationFlag(color: color, style: style, length: length)
            }
        }
    }

    if chars.count > 2 {
        if let l = FlagLength.allCases.first(where: { $0.shortcut == chars[2] }) {
            length = l
        }
    }

    return PublicationFlag(color: color, style: style, length: length)
}
