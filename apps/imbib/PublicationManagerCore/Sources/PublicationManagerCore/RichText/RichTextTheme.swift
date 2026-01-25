//
//  RichTextTheme.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import MarkdownUI

// MARK: - Scientific Theme Extension

public extension Theme {
    /// A theme optimized for scientific content with LaTeX math support.
    ///
    /// Features:
    /// - Syntax-highlighted code blocks (Python, R, Julia, etc.)
    /// - Inline code styling
    /// - GitHub-like styling for other elements
    static var scientific: Theme {
        Theme.gitHub
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(Theme.secondaryBackground)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    code: configuration.content,
                    language: configuration.language,
                    showLineNumbers: true
                )
            }
    }

    /// Secondary background color for code elements
    private static var secondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.5)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}

// MARK: - Math-Aware Text Parser

/// Parses text content and extracts LaTeX math expressions.
///
/// Supports:
/// - Inline math: `$...$` or `\(...\)`
/// - Display math: `$$...$$` or `\[...\]`
public enum MathTextParser {

    /// A segment of parsed text content.
    public enum Segment: Identifiable, Equatable {
        case text(String)
        case inlineMath(String)
        case displayMath(String)

        public var id: String {
            switch self {
            case .text(let str): return "text:\(str.prefix(20))"
            case .inlineMath(let latex): return "inline:\(latex)"
            case .displayMath(let latex): return "display:\(latex)"
            }
        }
    }

    /// Parse text into segments of plain text and math expressions.
    public static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var currentText = ""
        var index = text.startIndex

        while index < text.endIndex {
            // Check for display math ($$...$$)
            if text[index...].hasPrefix("$$") {
                // Save any accumulated text
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                // Find closing $$
                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "$$")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd])
                    segments.append(.displayMath(latex))
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Check for display math \[...\]
            if text[index...].hasPrefix("\\[") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "\\]")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd])
                    segments.append(.displayMath(latex))
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Check for inline math ($...$) - but not $$
            if text[index] == "$" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex && text[nextIndex] != "$" {
                    // Single $ - inline math
                    if !currentText.isEmpty {
                        segments.append(.text(currentText))
                        currentText = ""
                    }

                    // Find closing $
                    if let mathEnd = text[nextIndex...].firstIndex(of: "$") {
                        let latex = String(text[nextIndex..<mathEnd])
                        // Validate it's not empty and doesn't contain newlines (likely not math)
                        if !latex.isEmpty && !latex.contains("\n") {
                            segments.append(.inlineMath(latex))
                            index = text.index(after: mathEnd)
                            continue
                        }
                    }
                }
            }

            // Check for inline math \(...\)
            if text[index...].hasPrefix("\\(") {
                if !currentText.isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }

                let mathStart = text.index(index, offsetBy: 2)
                if let mathEnd = text[mathStart...].range(of: "\\)")?.lowerBound {
                    let latex = String(text[mathStart..<mathEnd])
                    segments.append(.inlineMath(latex))
                    index = text.index(mathEnd, offsetBy: 2)
                    continue
                }
            }

            // Regular character
            currentText.append(text[index])
            index = text.index(after: index)
        }

        // Add remaining text
        if !currentText.isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }

    /// Check if text contains any math expressions.
    public static func containsMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
    }
}

// MARK: - Math-Aware Text View

/// A view that renders text with embedded LaTeX math expressions.
///
/// Usage:
/// ```swift
/// MathAwareText("The equation $E=mc^2$ is famous.")
/// ```
public struct MathAwareText: View {
    private let segments: [MathTextParser.Segment]
    private let fontSize: CGFloat

    public init(_ text: String, fontSize: CGFloat = 14) {
        self.segments = MathTextParser.parse(text)
        self.fontSize = fontSize
    }

    public var body: some View {
        // Use a flow layout to wrap content
        FlowLayoutView(spacing: 2) {
            ForEach(segments) { segment in
                segmentView(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MathTextParser.Segment) -> some View {
        switch segment {
        case .text(let str):
            Text(str)
                .font(.system(size: fontSize))

        case .inlineMath(let latex):
            InlineMathView(latex: latex, fontSize: fontSize)

        case .displayMath(let latex):
            DisplayMathView(latex: latex, fontSize: fontSize + 2)
        }
    }
}

// MARK: - Flow Layout for Mixed Content

/// A simple flow layout that wraps content horizontally.
struct FlowLayoutView<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // For now, use an HStack with wrapping behavior
        // In production, this would use a proper Layout protocol implementation
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            content()
        }
    }
}

// MARK: - Preview

#Preview("Math-Aware Text") {
    VStack(alignment: .leading, spacing: 16) {
        MathAwareText("The equation $E=mc^2$ relates energy and mass.")

        MathAwareText("Einstein's field equations: $$R_{\\mu\\nu} - \\frac{1}{2}Rg_{\\mu\\nu} = \\frac{8\\pi G}{c^4}T_{\\mu\\nu}$$")

        MathAwareText("The fine structure constant is $\\alpha \\approx 1/137$, which governs electromagnetic interactions.")

        MathAwareText("No math here, just plain text.")
    }
    .padding()
}

#Preview("Math Parser") {
    let testText = "The equation $E=mc^2$ is famous. Also $$\\int_0^\\infty e^{-x} dx = 1$$"
    let segments = MathTextParser.parse(testText)

    VStack(alignment: .leading, spacing: 8) {
        Text("Input: \(testText)")
            .font(.caption)

        Divider()

        ForEach(segments) { segment in
            switch segment {
            case .text(let str):
                Text("TEXT: \"\(str)\"")
                    .foregroundStyle(.secondary)
            case .inlineMath(let latex):
                Text("INLINE: \(latex)")
                    .foregroundStyle(.blue)
            case .displayMath(let latex):
                Text("DISPLAY: \(latex)")
                    .foregroundStyle(.green)
            }
        }
    }
    .padding()
}
