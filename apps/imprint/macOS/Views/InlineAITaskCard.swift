//
//  InlineAITaskCard.swift
//  imprint
//
//  Non-modal, flow-preserving preview of an AI author-task result. Anchored in
//  the editor (not a sheet), it streams the model output and offers Accept /
//  Discard / Retry for replacing tasks, or Copy / Dismiss for advisory tasks
//  (e.g. Review), whose output is commentary rather than replacement text.
//

import SwiftUI
import AppKit

struct InlineAITaskCard: View {
    let suggestion: RewriteSuggestion
    /// Advisory tasks (Review, etc.) show commentary — never a destructive Accept.
    let isAdvisory: Bool
    let onAccept: (String) -> Void
    let onDiscard: () -> Void
    let onRetry: () -> Void

    private var isStreaming: Bool { suggestion.isStreaming }
    private var text: String { suggestion.suggestedText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 14, y: 5)
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: suggestion.action.effectiveIcon)
                .foregroundStyle(.tint)
            Text(suggestion.action.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isStreaming { ProgressView().controlSize(.small) }
            Button(action: onDiscard) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(12)
    }

    private var content: some View {
        ScrollView {
            Text(displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .padding(12)
        }
    }

    private var displayText: String {
        if text.isEmpty { return isStreaming ? "Thinking…" : "No output." }
        return text
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isAdvisory {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(text.isEmpty)
                Button("Dismiss", role: .cancel, action: onDiscard)
                    .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("Retry", action: onRetry)
                    .disabled(isStreaming)
                Spacer()
                Button("Discard", role: .cancel, action: onDiscard)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Accept") { onAccept(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(isStreaming || text.isEmpty)
            }
        }
        .padding(12)
    }
}
