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
public enum FlagColor: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    public var id: String { rawValue }

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

    /// THE mapping — hexes + semantic label — for this flag colour.
    ///
    /// Exhaustive over `Self`, deliberately: a dictionary literal can be
    /// empty on one platform and still compile (that is exactly how
    /// `ImpressSyntaxTheme.impressDefault` shipped `colors: [:]` on UIKit and
    /// rendered nothing), whereas a `switch` cannot lose a case silently.
    /// Everything colour-shaped below — light, dark, adaptive, the
    /// `FlagColorConfig.defaults` table — is derived from here, so there is
    /// one place to change a flag's colour and one place to get it wrong.
    public var defaultConfig: FlagColorConfig {
        switch self {
        case .red:
            return FlagColorConfig(lightHex: "E53935", darkHex: "EF5350", semanticLabel: "Urgent")
        case .amber:
            return FlagColorConfig(lightHex: "FB8C00", darkHex: "FFA726", semanticLabel: "Review")
        case .blue:
            return FlagColorConfig(lightHex: "1E88E5", darkHex: "42A5F5", semanticLabel: "Read")
        case .gray:
            return FlagColorConfig(lightHex: "757575", darkHex: "9E9E9E", semanticLabel: "Archive")
        }
    }

    /// Default color for light mode.
    public var defaultLightColor: Color { Color(hex: defaultConfig.lightHex) }

    /// Default color for dark mode.
    public var defaultDarkColor: Color { Color(hex: defaultConfig.darkHex) }

    /// The workflow meaning of the colour ("Urgent", "Review", …).
    public var semanticLabel: String { defaultConfig.semanticLabel }

    /// THE display colour for this flag, on every platform and in every
    /// appearance — macOS sidebar rows, imbib-iOS rows, the chassis
    /// `RecordSidebarView`, list dots, triage flashes.
    ///
    /// It is a *dynamic* colour (UIKit trait / AppKit appearance aware), so a
    /// caller with no `@Environment(\.colorScheme)` — a data-shaped sidebar
    /// node, an `NSOutlineView` cell — still gets the right colour in dark
    /// mode. Callers that DO have the environment can use
    /// `displayColor(for:)` instead; both resolve to the same two hexes.
    public var displayColor: Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .impressHex(defaultConfig.darkHex)
                : .impressHex(defaultConfig.lightHex)
        })
        #elseif canImport(AppKit)
        let config = defaultConfig
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .impressHex(config.darkHex)
                : .impressHex(config.lightHex)
        })
        #else
        return defaultLightColor
        #endif
    }

    /// The display colour resolved against a known appearance.
    public func displayColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? defaultDarkColor : defaultLightColor
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

    /// Parse a flag colour as it is STORED (the store's `flag_color` column,
    /// a payload string, an automation rule) rather than as a Swift case.
    ///
    /// Tolerates case and the British spelling, because both appear in the
    /// wild (`SidebarSnapshotMaintainer`, `PublicationSource`) and a colour
    /// that fails to parse is a row that silently loses its flag.
    public init?(storedValue: String?) {
        guard let raw = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if raw == "grey" {
            self = .gray
            return
        }
        guard let parsed = FlagColor(rawValue: raw) else { return nil }
        self = parsed
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

    /// DERIVED from `FlagColor.defaultConfig`, never written out by hand:
    /// a literal table can go missing an entry (or be `[:]` on one platform)
    /// and still compile, and the caller only finds out at render time.
    /// Built from `allCases`, it cannot.
    public static let defaults: [FlagColor: FlagColorConfig] = Dictionary(
        uniqueKeysWithValues: FlagColor.allCases.map { ($0, $0.defaultConfig) })
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
