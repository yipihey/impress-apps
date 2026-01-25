//
//  RichTextView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import MarkdownUI

// MARK: - Render Mode

/// The rendering mode for rich text content.
public enum RichTextRenderMode {
    /// Full Markdown rendering with LaTeX math support.
    /// Use for notes, comments, and user-generated content.
    case markdown

    /// Scientific abstract rendering with LaTeX/MathML support.
    /// Optimized for displaying paper abstracts from ADS, arXiv, etc.
    case scientific

    /// Plain text with no formatting.
    case plain
}

// MARK: - Rich Text View

/// A unified view for rendering rich text content with Markdown and LaTeX support.
///
/// Usage:
/// ```swift
/// // For user notes (full markdown)
/// RichTextView(content: notes, mode: .markdown)
///
/// // For paper abstracts (scientific text)
/// RichTextView(content: abstract, mode: .scientific)
///
/// // Plain text
/// RichTextView(content: text, mode: .plain)
/// ```
///
/// Supports:
/// - **Markdown mode**: Full GitHub Flavored Markdown + inline/display LaTeX math
/// - **Scientific mode**: Optimized for abstracts with LaTeX, MathML, subscripts/superscripts
/// - **Plain mode**: No formatting, just text
public struct RichTextView: View {

    // MARK: - Properties

    /// The text content to render
    public let content: String

    /// The rendering mode
    public let mode: RichTextRenderMode

    /// Font size for the content
    public var fontSize: CGFloat

    // MARK: - Initialization

    public init(
        content: String,
        mode: RichTextRenderMode = .markdown,
        fontSize: CGFloat = 14
    ) {
        self.content = content
        self.mode = mode
        self.fontSize = fontSize
    }

    // MARK: - Body

    public var body: some View {
        switch mode {
        case .markdown:
            markdownView

        case .scientific:
            scientificView

        case .plain:
            plainView
        }
    }

    // MARK: - Mode-Specific Views

    /// Full Markdown rendering with math support
    @ViewBuilder
    private var markdownView: some View {
        if MathTextParser.containsMath(content) {
            // Content has math - use math-aware rendering
            MathAwareMarkdown(content: content, fontSize: fontSize)
        } else {
            // Pure markdown - use standard renderer
            Markdown(content)
                .markdownTheme(.scientific)
        }
    }

    /// Scientific text rendering (abstracts, titles)
    private var scientificView: some View {
        MathAwareText(content, fontSize: fontSize)
    }

    /// Plain text (no formatting)
    private var plainView: some View {
        Text(content)
            .font(.system(size: fontSize))
    }
}

// MARK: - Math-Aware Markdown

/// Renders Markdown content with embedded LaTeX math.
///
/// This view preprocesses the markdown to extract math blocks,
/// then renders them appropriately.
struct MathAwareMarkdown: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        // Parse content into blocks
        let blocks = parseBlocks(content)

        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block Types

    enum Block {
        case markdown(String)
        case displayMath(String)
    }

    // MARK: - Parsing

    /// Parse content into markdown and display math blocks.
    private func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var remaining = text

        // Pattern for display math: $$...$$ or \[...\]
        while let range = findDisplayMath(in: remaining) {
            // Add markdown before the math
            let before = String(remaining[..<range.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.markdown(before))
            }

            // Extract math content
            let mathContent = extractMathContent(from: remaining, range: range)
            blocks.append(.displayMath(mathContent.latex))

            // Continue with remaining text
            remaining = String(remaining[mathContent.endIndex...])
        }

        // Add any remaining markdown
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.markdown(remaining))
        }

        return blocks
    }

    private func findDisplayMath(in text: String) -> Range<String.Index>? {
        // Try $$...$$
        if let start = text.range(of: "$$") {
            return start
        }
        // Try \[...\]
        if let start = text.range(of: "\\[") {
            return start
        }
        return nil
    }

    private func extractMathContent(from text: String, range: Range<String.Index>) -> (latex: String, endIndex: String.Index) {
        let isDoubleDollar = text[range].hasPrefix("$$")
        let closer = isDoubleDollar ? "$$" : "\\]"
        let openerLength = 2

        let contentStart = text.index(range.lowerBound, offsetBy: openerLength)
        if let closeRange = text[contentStart...].range(of: closer) {
            let latex = String(text[contentStart..<closeRange.lowerBound])
            let endIndex = text.index(closeRange.lowerBound, offsetBy: closer.count)
            return (latex, endIndex)
        }

        // No closer found - treat rest as math
        return (String(text[contentStart...]), text.endIndex)
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .markdown(let md):
            // Render markdown with inline math support
            InlineMathMarkdown(content: md, fontSize: fontSize)

        case .displayMath(let latex):
            DisplayMathView(latex: latex, fontSize: fontSize + 4)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Inline Math Markdown

/// Renders markdown with inline math ($...$) support.
struct InlineMathMarkdown: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        // If no inline math, use standard markdown
        if !content.contains("$") && !content.contains("\\(") {
            Markdown(content)
                .markdownTheme(.scientific)
        } else {
            // Has inline math - render with math-aware text
            MathAwareText(content, fontSize: fontSize)
        }
    }
}

// MARK: - Convenience Extensions

public extension View {
    /// Renders the view's text content as rich text.
    func richText(mode: RichTextRenderMode = .markdown) -> some View {
        environment(\.richTextMode, mode)
    }
}

// MARK: - Environment Key

private struct RichTextModeKey: EnvironmentKey {
    static let defaultValue: RichTextRenderMode = .markdown
}

extension EnvironmentValues {
    var richTextMode: RichTextRenderMode {
        get { self[RichTextModeKey.self] }
        set { self[RichTextModeKey.self] = newValue }
    }
}

// MARK: - Preview

#Preview("Markdown Mode") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            RichTextView(
                content: """
                # Research Notes

                ## Summary

                This paper presents a **novel approach** to solving the problem of $\\alpha$-stable distributions.

                ### Key Equations

                The main result is:

                $$\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}$$

                ### Code Example

                ```python
                import numpy as np
                x = np.linspace(0, 10, 100)
                y = np.exp(-x**2)
                ```

                The function `np.exp()` computes the exponential.

                - First point with $E = mc^2$
                - Second point
                - Third point
                """,
                mode: .markdown
            )
        }
        .padding()
    }
}

#Preview("Scientific Mode") {
    RichTextView(
        content: """
        We present observations of the H$\\alpha$ emission line in the spectrum of the star.
        The measured flux is $F = 10^{-15}$ erg s$^{-1}$ cm$^{-2}$.
        Using the standard relation $L = 4\\pi d^2 F$, we derive the luminosity.
        """,
        mode: .scientific
    )
    .padding()
}

#Preview("Plain Mode") {
    RichTextView(
        content: "This is plain text with no formatting. Even $math$ is not rendered.",
        mode: .plain
    )
    .padding()
}
