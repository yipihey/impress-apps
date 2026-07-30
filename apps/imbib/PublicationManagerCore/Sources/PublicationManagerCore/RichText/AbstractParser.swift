//
//  AbstractParser.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//  Stage 7 item 9: the whole pipeline moved to Rust
//  (`crates/imbib-core/src/text/abstract_parser.rs`).
//

import Foundation
import ImbibRustCore

// MARK: - Abstract Segment

/// A segment of parsed abstract content.
public enum AbstractSegment: Identifiable, Equatable {
    case text(String)
    case inlineMath(String)     // LaTeX for inline rendering
    case displayMath(String)    // LaTeX for display/block rendering

    public var id: String {
        switch self {
        case .text(let str): return "text:\(str.hashValue)"
        case .inlineMath(let latex): return "inline:\(latex.hashValue)"
        case .displayMath(let latex): return "display:\(latex.hashValue)"
        }
    }

    /// The segment's payload, regardless of kind.
    public var value: String {
        switch self {
        case .text(let str), .inlineMath(let str), .displayMath(let str): return str
        }
    }
}

// MARK: - Abstract Parser

/// Parses scientific abstracts into renderable segments.
///
/// Handles:
/// - MathML from ADS, CrossRef, etc. (converted to LaTeX)
/// - LaTeX expressions (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`)
/// - arXiv/JSON double-escaping (`\\beta` → `\beta`) over 186 command names
/// - HTML entities: 41 named plus decimal and hex numeric forms
/// - HTML subscript/superscript tags (`<sub>`, `<sup>`)
///
/// **This is a shim.** Every transformation lives in `imbib-core`'s
/// `text::abstract_parser` and is pinned by 56 golden cases (168 assertions) in
/// `crates/imbib-core/test_fixtures/golden/abstract_parse.json`, captured from
/// this file before its bodies were replaced. Before the port this file had
/// **zero tests**.
///
/// ## ⚠️ This logic is not wired into the shipping detail pane
///
/// Production abstract rendering is `MathJaxAbstractView` (`InfoTab` on macOS,
/// `IOSInfoTab` on iOS), and `MathJaxView` interpolates the **raw** abstract
/// into its WKWebView with no preprocessing. So an arXiv abstract's
/// `\\Omega_m` still renders with visible backslashes and an ADS `<mml:math>`
/// abstract still renders as markup — even though this type fixes both.
///
/// Wiring it is one line at `MathJaxView`'s body interpolation. It was
/// deliberately NOT done in the port wave: changing what the detail pane renders
/// is a product decision that deserves its own before/after, not a side effect
/// of a port. Recorded as a known gap in docs/chassis-capability-matrix.md and
/// docs/parser-batch-swift-rust-split.md.
///
/// Usage:
/// ```swift
/// let segments = AbstractParser.parse(abstract)
/// for segment in segments {
///     // Render each segment appropriately
/// }
/// ```
public enum AbstractParser {

    // MARK: - Public Interface

    /// Parse abstract text into segments for rendering.
    public static func parse(_ text: String) -> [AbstractSegment] {
        ImbibRustCore.abstractParse(text: text).compactMap { segment in
            switch segment.kind {
            case "text": return .text(segment.value)
            case "inlineMath": return .inlineMath(segment.value)
            case "displayMath": return .displayMath(segment.value)
            default: return nil
            }
        }
    }

    /// Whether the text contains math delimiters or MathML markup.
    public static func containsMath(_ text: String) -> Bool {
        ImbibRustCore.abstractContainsMath(text: text)
    }
}

// MARK: - MathML → LaTeX

/// Converts MathML markup to LaTeX.
///
/// Distinct from `ImbibRustCore.parseMathml`, which targets **Unicode**
/// super/subscripts (`H²`) because it feeds the full-text search index. This
/// targets **LaTeX** (`{H}^{2}`) because it feeds a LaTeX renderer. Both
/// renderings now come from one traversal in `imbib-core`'s
/// `text::mathml_parser`, parameterised by target, rather than two copies of the
/// same depth-counting child scanner.
public enum MathMLToLaTeX {

    /// Convert MathML in `text` to LaTeX, wrapping each formula in `$…$`.
    public static func convert(_ text: String) -> String {
        ImbibRustCore.abstractMathmlToLatex(text: text)
    }
}
