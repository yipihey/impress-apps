//
//  ChatMarkdownView.swift
//  MessageManagerCore
//
//  Rich markdown rendering for AI chat messages.
//  Supports GFM markdown with syntax-highlighted code blocks.
//

import MarkdownUI
import SwiftUI

// MARK: - Chat Markdown View

/// Renders markdown content with syntax highlighting for code blocks.
///
/// Optimized for AI chat messages that often contain:
/// - Code blocks with language hints
/// - Inline code
/// - Headers, lists, links
/// - Bold, italic, strikethrough
///
/// Usage:
/// ```swift
/// ChatMarkdownView(content: message.contentMarkdown)
/// ```
public struct ChatMarkdownView: View {
    let content: String
    let fontSize: CGFloat

    public init(content: String, fontSize: CGFloat = 14) {
        self.content = content
        self.fontSize = fontSize
    }

    public var body: some View {
        Markdown(content)
            .markdownTheme(.impartChat(fontSize: fontSize))
            .textSelection(.enabled)
    }
}

// MARK: - Impart Chat Theme

extension MarkdownUI.Theme {
    /// Theme optimized for AI chat messages.
    static func impartChat(fontSize: CGFloat = 14) -> Theme {
        Theme()
            .text {
                FontSize(fontSize)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(.secondary.opacity(0.1))
            }
            .codeBlock { configuration in
                CodeBlockView(configuration: configuration)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 16, bottom: 8)
                    .markdownTextStyle {
                        FontSize(fontSize * 1.5)
                        FontWeight(.bold)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 12, bottom: 6)
                    .markdownTextStyle {
                        FontSize(fontSize * 1.3)
                        FontWeight(.semibold)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 10, bottom: 4)
                    .markdownTextStyle {
                        FontSize(fontSize * 1.1)
                        FontWeight(.medium)
                    }
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 8)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                            FontStyle(.italic)
                        }
                        .padding(.leading, 12)
                }
                .markdownMargin(top: 8, bottom: 8)
            }
    }
}

// MARK: - Code Block View

/// Custom code block rendering with syntax highlighting and copy button.
private struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var isCopied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language and copy button
            HStack {
                if let language = configuration.language {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(codeBackground.opacity(0.8))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
            }
            .background(codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .markdownMargin(top: 8, bottom: 8)
    }

    private var codeBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.12)
            : Color(white: 0.96)
    }

    private func copyToClipboard() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        #else
        UIPasteboard.general.string = configuration.content
        #endif

        withAnimation {
            isCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

// MARK: - Preview

#Preview("Chat Message") {
    ScrollView {
        ChatMarkdownView(content: """
        # Research Summary

        Here's the key finding from the paper:

        ## Main Result

        The authors demonstrate that **surface codes** achieve a threshold error rate of approximately `1%`.

        ```python
        import numpy as np

        def calculate_threshold(data):
            \"\"\"Calculate the error threshold.\"\"\"
            return np.mean(data) / np.std(data)

        result = calculate_threshold(measurements)
        print(f"Threshold: {result:.4f}")
        ```

        ### Key Points

        - Error correction works when physical error rate < threshold
        - The paper uses *Monte Carlo* simulations
        - Results are consistent with previous work

        > This is a significant advancement in quantum error correction.

        For more details, see the [original paper](https://arxiv.org/abs/1208.0928).
        """)
        .padding()
    }
    .frame(width: 600, height: 500)
}
