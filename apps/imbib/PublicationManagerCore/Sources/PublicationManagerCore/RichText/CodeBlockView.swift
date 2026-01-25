//
//  CodeBlockView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI
import HighlightSwift

// MARK: - Supported Languages

/// Languages supported for syntax highlighting (scientific focus).
public enum SupportedLanguage: String, CaseIterable {
    case python
    case r
    case julia
    case matlab
    case latex
    case sql
    case shell
    case bash
    case c
    case cpp
    case fortran
    case json
    case yaml
    case markdown
    case plaintext

    /// Map common language identifiers to HighlightSwift language names
    public init?(identifier: String?) {
        guard let id = identifier?.lowercased() else {
            self = .plaintext
            return
        }

        switch id {
        case "python", "py", "python3":
            self = .python
        case "r":
            self = .r
        case "julia", "jl":
            self = .julia
        case "matlab", "m", "octave":
            self = .matlab
        case "latex", "tex":
            self = .latex
        case "sql", "mysql", "postgresql", "sqlite":
            self = .sql
        case "shell", "sh", "zsh":
            self = .shell
        case "bash":
            self = .bash
        case "c":
            self = .c
        case "cpp", "c++", "cxx":
            self = .cpp
        case "fortran", "f90", "f95", "f03":
            self = .fortran
        case "json":
            self = .json
        case "yaml", "yml":
            self = .yaml
        case "markdown", "md":
            self = .markdown
        default:
            self = .plaintext
        }
    }

    /// The HighlightSwift language name
    var highlightLanguage: String {
        switch self {
        case .python: return "python"
        case .r: return "r"
        case .julia: return "julia"
        case .matlab: return "matlab"
        case .latex: return "latex"
        case .sql: return "sql"
        case .shell: return "shell"
        case .bash: return "bash"
        case .c: return "c"
        case .cpp: return "cpp"
        case .fortran: return "fortran"
        case .json: return "json"
        case .yaml: return "yaml"
        case .markdown: return "markdown"
        case .plaintext: return "plaintext"
        }
    }
}

// MARK: - Code Block View

/// A view that displays syntax-highlighted code blocks.
///
/// Uses HighlightSwift for syntax highlighting with support for
/// scientific programming languages.
public struct CodeBlockView: View {

    // MARK: - Properties

    /// The code content to display
    public let code: String

    /// The programming language (for syntax highlighting)
    public let language: String?

    /// Whether to show line numbers
    public var showLineNumbers: Bool

    /// Font size for the code
    public var fontSize: CGFloat

    // MARK: - State

    @State private var highlightedCode: AttributedString?
    @State private var isHighlighting = false

    // MARK: - Environment

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Initialization

    public init(
        code: String,
        language: String? = nil,
        showLineNumbers: Bool = true,
        fontSize: CGFloat = 13
    ) {
        self.code = code
        self.language = language
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
    }

    // MARK: - Body

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                // Line numbers
                if showLineNumbers {
                    lineNumbersView
                }

                // Code content
                codeContentView
            }
        }
        .padding(12)
        .background(codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: code + (language ?? "") + (colorScheme == .dark ? "dark" : "light")) {
            await highlightCode()
        }
    }

    // MARK: - Subviews

    private var lineNumbersView: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(1...lineCount, id: \.self) { lineNum in
                Text("\(lineNum)")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .padding(.trailing, 12)
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var codeContentView: some View {
        if let highlighted = highlightedCode {
            Text(highlighted)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
        } else {
            // Fallback while highlighting
            Text(code)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private var codeBackground: some ShapeStyle {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.5)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    // MARK: - Computed Properties

    private var lineCount: Int {
        code.components(separatedBy: "\n").count
    }

    // MARK: - Highlighting

    private func highlightCode() async {
        guard !isHighlighting else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        let lang = SupportedLanguage(identifier: language)
        let highlight = Highlight()

        do {
            // Use appropriate theme based on color scheme
            let result = try await highlight.attributedText(
                code,
                language: lang?.highlightLanguage ?? "plaintext"
            )
            await MainActor.run {
                highlightedCode = result
            }
        } catch {
            // Fall back to plain text on error
            await MainActor.run {
                highlightedCode = AttributedString(code)
            }
        }
    }
}

// MARK: - Inline Code View

/// A view for inline code spans (single backticks).
public struct InlineCodeView: View {
    public let code: String
    public var fontSize: CGFloat

    public init(code: String, fontSize: CGFloat = 14) {
        self.code = code
        self.fontSize = fontSize
    }

    public var body: some View {
        Text(code)
            .font(.system(size: fontSize, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(codeBackground)
            )
    }

    private var codeBackground: some ShapeStyle {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.5)
        #else
        Color(.tertiarySystemBackground)
        #endif
    }
}

// MARK: - Preview

#Preview("Python Code") {
    CodeBlockView(
        code: """
        import numpy as np
        import matplotlib.pyplot as plt

        # Generate data
        x = np.linspace(0, 2*np.pi, 100)
        y = np.sin(x)

        # Plot
        plt.figure(figsize=(10, 6))
        plt.plot(x, y, label='sin(x)')
        plt.xlabel('x')
        plt.ylabel('y')
        plt.legend()
        plt.show()
        """,
        language: "python"
    )
    .padding()
}

#Preview("SQL Query") {
    CodeBlockView(
        code: """
        SELECT
            authors.name,
            COUNT(papers.id) AS paper_count,
            AVG(papers.citations) AS avg_citations
        FROM authors
        JOIN paper_authors ON authors.id = paper_authors.author_id
        JOIN papers ON paper_authors.paper_id = papers.id
        WHERE papers.year >= 2020
        GROUP BY authors.id
        ORDER BY paper_count DESC
        LIMIT 10;
        """,
        language: "sql"
    )
    .padding()
}

#Preview("Inline Code") {
    VStack(alignment: .leading, spacing: 8) {
        HStack {
            Text("Use the")
            InlineCodeView(code: "numpy.array()")
            Text("function to create arrays.")
        }

        HStack {
            Text("The variable")
            InlineCodeView(code: "alpha")
            Text("represents the learning rate.")
        }
    }
    .padding()
}
