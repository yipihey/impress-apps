//
//  ImpressSyntaxTheme.swift
//  ImpressSyntaxHighlight
//
//  Maps tree-sitter capture names (@keyword, @comment, @function.macro, etc.)
//  to platform colors. Uses semantic system colors so light/dark mode works
//  automatically on BOTH platforms.
//

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ImpressSyntaxTheme: Sendable {
    public let defaultColor: ImpressColor
    public let colors: [String: ImpressColor]

    public init(defaultColor: ImpressColor, colors: [String: ImpressColor]) {
        self.defaultColor = defaultColor
        self.colors = colors
    }

    /// Look up a color for a tree-sitter capture name.
    /// Supports dotted hierarchy: `@function.macro` falls back to `@function`.
    public func color(for captureName: String) -> ImpressColor? {
        if let direct = colors[captureName] { return direct }
        // Try progressively shorter prefixes: function.macro.builtin → function.macro → function
        var name = captureName
        while let lastDot = name.lastIndex(of: ".") {
            name = String(name[..<lastDot])
            if let color = colors[name] { return color }
        }
        return nil
    }
}

// MARK: - Cross-platform semantic colors

/// The five semantic colors whose *names* differ between AppKit and UIKit.
/// Everything else in the palette (`.systemPurple`, `.systemBlue`, …) is
/// spelled identically on `NSColor` and `UIColor`, so the capture table below
/// is written ONCE and resolves per platform through these aliases.
///
/// The AppKit values are exactly the ones the macOS editor shipped with — this
/// is a de-duplication, not a re-theme.
extension ImpressColor {
    static var impressText: ImpressColor {
        #if canImport(AppKit)
        return .textColor
        #else
        return .label
        #endif
    }

    static var impressLabel: ImpressColor {
        #if canImport(AppKit)
        return .labelColor
        #else
        return .label
        #endif
    }

    static var impressSecondaryLabel: ImpressColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }

    static var impressTertiaryLabel: ImpressColor {
        #if canImport(AppKit)
        return .tertiaryLabelColor
        #else
        return .tertiaryLabel
        #endif
    }

    static var impressLink: ImpressColor {
        #if canImport(AppKit)
        return .linkColor
        #else
        return .link
        #endif
    }
}

public extension ImpressSyntaxTheme {
    /// Default theme using semantic system colors — adapts to light/dark mode
    /// automatically, on macOS (AppKit) and iOS/iPadOS (UIKit) alike.
    ///
    /// Category names follow nvim-treesitter conventions (markup.heading,
    /// function.macro, etc.). ONE table for both platforms: the iOS branch used
    /// to be `colors: [:]`, which silently rendered every capture in the default
    /// color — i.e. no highlighting at all on iPhone/iPad.
    static var impressDefault: ImpressSyntaxTheme {
        ImpressSyntaxTheme(
            defaultColor: .impressText,
            colors: [
                // Comments — muted gray
                "comment": .impressSecondaryLabel,

                // Keywords — purple
                "keyword": .systemPurple,
                "keyword.conditional": .systemPurple,
                "keyword.directive": .systemPurple,
                "keyword.import": .systemPurple,
                "keyword.function": .systemPurple,
                "keyword.operator": .systemPurple,
                "keyword.control": .systemPurple,
                "keyword.control.conditional": .systemPurple,
                "keyword.control.import": .systemPurple,
                "keyword.control.repeat": .systemPurple,
                "keyword.storage": .systemPurple,
                "keyword.storage.type": .systemPurple,

                // Functions / commands — blue
                "function": .systemBlue,
                "function.call": .systemBlue,
                "function.macro": .systemBlue, // \newcommand etc
                "function.builtin": .systemBlue,

                // Markup (LaTeX/Typst prose)
                "markup.heading": .systemBlue,
                "markup.heading.1": .systemBlue,
                "markup.heading.2": .systemBlue,
                "markup.heading.3": .systemBlue,
                "markup.heading.4": .systemBlue,
                "markup.heading.5": .systemBlue,
                "markup.heading.6": .systemBlue,
                "markup.italic": .impressLabel,
                "markup.strong": .impressLabel,
                "markup.bold": .impressLabel,
                "markup.heading.marker": .systemPurple,
                "markup.raw.block": .systemRed,
                "markup.link": .impressLink,
                "markup.link.url": .impressLink,
                "markup.link.label": .systemOrange,
                "markup.math": .systemTeal,
                "markup.list": .systemBrown,
                "markup.quote": .impressSecondaryLabel,
                "markup.raw": .systemRed,

                // Modules / namespaces (packages, environments) — purple
                "module": .systemPurple,
                "namespace": .systemPurple,
                "include": .systemPurple,

                // Labels — orange (cite keys, refs, anchors)
                "label": .systemOrange,
                "reference": .systemOrange,

                // Types — teal
                "type": .systemTeal,
                "type.builtin": .systemTeal,
                "type.definition": .systemTeal,

                // Strings — red
                "string": .systemRed,
                "string.escape": .systemRed,
                "string.regexp": .systemRed,
                "string.special": .systemOrange,
                "string.special.path": .impressLink,

                // Numbers, constants — indigo
                "number": .systemIndigo,
                "constant": .systemIndigo,
                "constant.builtin": .systemIndigo,
                "constant.builtin.boolean": .systemIndigo,
                "constant.numeric": .systemIndigo,
                "constant.character": .systemRed,
                "constant.character.escape": .systemRed,
                "boolean": .systemIndigo,

                // Variables
                "variable": .impressLabel,
                "variable.parameter": .systemOrange,
                "variable.builtin": .systemBrown,

                // Operators, punctuation — muted
                "operator": .impressSecondaryLabel,
                "punctuation": .impressTertiaryLabel,
                "punctuation.bracket": .impressTertiaryLabel,
                "punctuation.delimiter": .impressTertiaryLabel,
                "punctuation.special": .impressSecondaryLabel,

                // Tags / attributes
                "tag": .systemBlue,
                "tag.attribute": .systemOrange,
                "attribute": .systemOrange,

                // Errors
                "error": .systemRed,
            ]
        )
    }
}
