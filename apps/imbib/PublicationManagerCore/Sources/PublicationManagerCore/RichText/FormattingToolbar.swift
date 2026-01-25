//
//  FormattingToolbar.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-09.
//

import SwiftUI

// MARK: - Formatting Toolbar

/// A Slack-style formatting toolbar for markdown text input.
///
/// Provides quick-access buttons for common formatting:
/// - Bold (**text**)
/// - Italic (_text_)
/// - Strikethrough (~~text~~)
/// - Inline code (`code`)
/// - Math ($equation$)
/// - Link ([text](url))
/// - Code block
///
/// Usage:
/// ```swift
/// @State private var text: String = ""
/// @State private var selectedRange: NSRange?
///
/// VStack {
///     FormattingToolbar(text: $text, selectedRange: $selectedRange)
///     TextEditor(text: $text)
/// }
/// ```
public struct FormattingToolbar: View {

    // MARK: - Properties

    @Environment(\.themeColors) private var theme
    @Binding public var text: String

    /// Optional: track cursor position for wrap-at-cursor behavior
    @Binding public var cursorPosition: Int?

    /// Compact mode (smaller buttons, horizontal scroll)
    public var compact: Bool

    // MARK: - Initialization

    public init(
        text: Binding<String>,
        cursorPosition: Binding<Int?> = .constant(nil),
        compact: Bool = false
    ) {
        self._text = text
        self._cursorPosition = cursorPosition
        self.compact = compact
    }

    // MARK: - Body

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 4 : 8) {
                // Bold
                toolbarButton(
                    icon: "bold",
                    label: "B",
                    help: "Bold (**text**)"
                ) {
                    wrapText(with: "**")
                }

                // Italic
                toolbarButton(
                    icon: "italic",
                    label: "I",
                    help: "Italic (_text_)"
                ) {
                    wrapText(with: "_")
                }

                // Strikethrough
                toolbarButton(
                    icon: "strikethrough",
                    label: "S",
                    help: "Strikethrough (~~text~~)"
                ) {
                    wrapText(with: "~~")
                }

                Divider()
                    .frame(height: compact ? 16 : 20)

                // Inline code
                toolbarButton(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: "<>",
                    help: "Inline code (`code`)"
                ) {
                    wrapText(with: "`")
                }

                // Math
                toolbarButton(
                    icon: "sum",
                    label: "∑",
                    help: "Math equation ($x^2$)"
                ) {
                    wrapText(with: "$")
                }

                Divider()
                    .frame(height: compact ? 16 : 20)

                // Link
                toolbarButton(
                    icon: "link",
                    label: nil,
                    help: "Link ([text](url))"
                ) {
                    insertLink()
                }

                // Code block
                toolbarButton(
                    icon: "text.alignleft",
                    label: nil,
                    help: "Code block (```)"
                ) {
                    insertCodeBlock()
                }
            }
            .padding(.horizontal, compact ? 4 : 8)
            .padding(.vertical, compact ? 2 : 4)
        }
        .background(theme.contentBackground)
    }

    // MARK: - Toolbar Button

    @ViewBuilder
    private func toolbarButton(
        icon: String,
        label: String?,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let label = label {
                    Text(label)
                        .font(compact ? .caption : .callout)
                        .fontWeight(.medium)
                        .fontDesign(.monospaced)
                } else {
                    Image(systemName: icon)
                        .font(compact ? .caption : .callout)
                }
            }
            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onHover { hovering in
            // macOS hover effect handled by button style
        }
        #endif
        .help(help)
    }

    // MARK: - Text Manipulation

    /// Wrap text at cursor position or append to end
    private func wrapText(with wrapper: String) {
        if let position = cursorPosition, position <= text.count {
            // Insert at cursor position
            let index = text.index(text.startIndex, offsetBy: position)
            text.insert(contentsOf: wrapper + wrapper, at: index)
            // Move cursor between wrappers
            cursorPosition = position + wrapper.count
        } else {
            // Append to end
            text += wrapper + wrapper
        }
    }

    /// Insert a link template
    private func insertLink() {
        let template = "[link text](https://)"
        if let position = cursorPosition, position <= text.count {
            let index = text.index(text.startIndex, offsetBy: position)
            text.insert(contentsOf: template, at: index)
        } else {
            text += template
        }
    }

    /// Insert a code block template
    private func insertCodeBlock() {
        let template = "\n```python\n\n```\n"
        if let position = cursorPosition, position <= text.count {
            let index = text.index(text.startIndex, offsetBy: position)
            text.insert(contentsOf: template, at: index)
        } else {
            text += template
        }
    }
}

// MARK: - Compact Formatting Bar

/// A minimal formatting bar for inline use.
public struct CompactFormattingBar: View {
    @Binding public var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        FormattingToolbar(text: $text, compact: true)
    }
}

// MARK: - Preview

#Preview("Standard Toolbar") {
    @Previewable @State var text = "Some text here"

    VStack {
        FormattingToolbar(text: $text)

        TextEditor(text: $text)
            .frame(height: 200)
            .border(Color.gray.opacity(0.3))

        Text("Preview: \(text)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
}

#Preview("Compact Toolbar") {
    @Previewable @State var text = ""

    VStack {
        CompactFormattingBar(text: $text)
            .frame(maxWidth: 200)

        TextEditor(text: $text)
            .frame(height: 100)
            .border(Color.gray.opacity(0.3))
    }
    .padding()
}
