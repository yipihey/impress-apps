//
//  ImpressSyntaxTheme.swift
//  ImpressSyntaxHighlight
//
//  Maps tree-sitter capture names (@keyword, @comment, @function.macro, etc.)
//  to NSColors. Uses macOS semantic colors so light/dark mode works automatically.
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

public extension ImpressSyntaxTheme {
    /// Default theme using semantic NSColors — adapts to light/dark mode automatically.
    /// Category names follow nvim-treesitter conventions (markup.heading, function.macro, etc.)
    static var impressDefault: ImpressSyntaxTheme {
        #if canImport(AppKit)
        return ImpressSyntaxTheme(
            defaultColor: .textColor,
            colors: [
                // Comments — muted gray
                "comment": .secondaryLabelColor,

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
                "markup.italic": .labelColor,
                "markup.strong": .labelColor,
                "markup.bold": .labelColor,
                "markup.heading.marker": .systemPurple,
                "markup.raw.block": .systemRed,
                "markup.link": .linkColor,
                "markup.link.url": .linkColor,
                "markup.link.label": .systemOrange,
                "markup.math": .systemTeal,
                "markup.list": .systemBrown,
                "markup.quote": .secondaryLabelColor,
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
                "string.special.path": .linkColor,

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
                "variable": .labelColor,
                "variable.parameter": .systemOrange,
                "variable.builtin": .systemBrown,

                // Operators, punctuation — muted
                "operator": .secondaryLabelColor,
                "punctuation": .tertiaryLabelColor,
                "punctuation.bracket": .tertiaryLabelColor,
                "punctuation.delimiter": .tertiaryLabelColor,
                "punctuation.special": .secondaryLabelColor,

                // Tags / attributes
                "tag": .systemBlue,
                "tag.attribute": .systemOrange,
                "attribute": .systemOrange,

                // Errors
                "error": .systemRed,
            ]
        )
        #else
        return ImpressSyntaxTheme(
            defaultColor: .label,
            colors: [:]
        )
        #endif
    }
}
