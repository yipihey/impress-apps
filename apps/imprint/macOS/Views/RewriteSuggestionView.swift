//
//  RewriteSuggestionView.swift
//  imprint
//
//  Inline diff view for showing AI-generated text suggestions.
//  Provides Accept, Reject, and Edit options.
//

import SwiftUI

// MARK: - Rewrite Suggestion View

/// View for displaying an AI-generated text suggestion with inline diff.
///
/// Shows the original text vs suggested text with visual diff highlighting.
/// Provides buttons to Accept (replace selection), Reject (dismiss), or Edit (open in chat).
struct RewriteSuggestionView: View {
    let suggestion: RewriteSuggestion
    let onAccept: (String) -> Void
    let onReject: () -> Void
    let onEdit: () -> Void
    let onCancel: (() -> Void)?

    @State private var showDiff = true

    init(
        suggestion: RewriteSuggestion,
        onAccept: @escaping (String) -> Void,
        onReject: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.suggestion = suggestion
        self.onAccept = onAccept
        self.onReject = onReject
        self.onEdit = onEdit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showDiff {
                        diffView
                    } else {
                        sideBySideView
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)

            Divider()

            // Actions
            actionButtons
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .frame(width: 450)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text(suggestion.action.title)
                .font(.headline)

            Spacer()

            // Toggle diff/side-by-side view
            Picker("View", selection: $showDiff) {
                Image(systemName: "text.badge.plus").tag(true)
                Image(systemName: "rectangle.split.2x1").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 70)
            .help(showDiff ? "Showing inline diff" : "Showing side-by-side")

            if suggestion.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 8)

                // Cancel button during streaming
                if let onCancel = onCancel {
                    Button {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .padding()
    }

    // MARK: - Diff View

    private var diffView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes")
                .font(.caption)
                .foregroundStyle(.secondary)

            let segments = DiffCalculator.computeDiff(
                original: suggestion.originalText,
                suggested: suggestion.suggestedText
            )

            // Render diff segments
            DiffFlowLayout(spacing: 0) {
                ForEach(segments) { segment in
                    Text(segment.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(foregroundColor(for: segment.type))
                        .background(backgroundColor(for: segment.type))
                        .strikethrough(segment.type == .removed)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func foregroundColor(for type: DiffType) -> Color {
        switch type {
        case .removed: return .red
        case .added: return .green
        case .unchanged: return .primary
        }
    }

    private func backgroundColor(for type: DiffType) -> Color {
        switch type {
        case .removed: return .red.opacity(0.15)
        case .added: return .green.opacity(0.15)
        case .unchanged: return .clear
        }
    }

    // MARK: - Side-by-Side View

    private var sideBySideView: some View {
        HStack(alignment: .top, spacing: 16) {
            // Original
            VStack(alignment: .leading, spacing: 4) {
                Text("Original")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(suggestion.originalText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.05))
                    .clipShape(.rect(cornerRadius: 4))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)

            // Suggested
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(suggestion.suggestedText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.05))
                    .clipShape(.rect(cornerRadius: 4))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            // Reject button
            Button {
                onReject()
            } label: {
                Label("Reject", systemImage: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            // Copy button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(suggestion.suggestedText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy to clipboard")

            // Edit in chat button
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.bordered)
            .help("Refine in AI chat")

            // Accept button
            Button {
                onAccept(suggestion.suggestedText)
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(suggestion.isStreaming)
        }
        .padding()
    }
}

// MARK: - Flow Layout

/// A layout that wraps content to multiple lines (for inline diff display).
private struct DiffFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity

        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Move to next line
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))

            currentX += size.width
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX)
        }

        totalHeight = currentY + lineHeight

        return (CGSize(width: totalWidth, height: totalHeight), positions)
    }
}

// MARK: - Streaming Rewrite Suggestion View

/// A version of the suggestion view that supports streaming updates.
struct StreamingRewriteSuggestionView: View {
    @Binding var suggestion: RewriteSuggestion?
    let onAccept: (String) -> Void
    let onReject: () -> Void
    let onEdit: () -> Void

    var body: some View {
        if let suggestion = suggestion {
            RewriteSuggestionView(
                suggestion: suggestion,
                onAccept: onAccept,
                onReject: onReject,
                onEdit: onEdit
            )
        }
    }
}

// MARK: - Preview

#Preview("Suggestion View") {
    RewriteSuggestionView(
        suggestion: RewriteSuggestion(
            originalText: "The results show that the method works well in most cases and produces good outcomes.",
            suggestedText: "The results demonstrate that the method performs effectively across most scenarios, yielding favorable outcomes.",
            action: .improveClarity,
            range: NSRange(location: 0, length: 85)
        ),
        onAccept: { _ in },
        onReject: {},
        onEdit: {}
    )
    .padding()
}

#Preview("Streaming") {
    RewriteSuggestionView(
        suggestion: RewriteSuggestion(
            originalText: "The results show that the method works.",
            suggestedText: "The results demonstrate that the method...",
            action: .improveClarity,
            range: NSRange(location: 0, length: 40),
            isStreaming: true
        ),
        onAccept: { _ in },
        onReject: {},
        onEdit: {}
    )
    .padding()
}
