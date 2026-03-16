//
//  MultiVariantView.swift
//  imprint
//
//  Displays multiple AI-generated text variants in a side-by-side scrollable panel.
//  Used for "3 rewrites" and similar multi-candidate AI actions.
//
//  Keyboard:
//    j/k     → navigate between variants
//    Return  → accept focused variant (replaces selection)
//    Escape  → dismiss without changes
//    d       → toggle diff view for focused variant
//

import SwiftUI
import AppKit

// MARK: - Variant Entry

/// One streaming variant result.
struct VariantEntry: Identifiable {
    let id = UUID()
    let index: Int
    var suggestedText: String
    var isStreaming: Bool

    var label: String { "Variant \(index + 1)" }
}

// MARK: - Multi Variant View

/// Panel showing N streaming rewrite variants with keyboard navigation.
///
/// Appears as a right-side sheet overlay on the editor.
/// Streaming variants appear progressively as they arrive in parallel.
struct MultiVariantView: View {
    let originalText: String
    let selectedRange: NSRange
    let onAccept: (String, NSRange) -> Void
    let onDismiss: () -> Void

    @State private var variants: [VariantEntry] = []
    @State private var focusedIndex: Int = 0
    @State private var showDiff: Bool = false
    @State private var error: String?
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let error = error {
                errorBanner(error)
            }

            variantList

            Divider()

            actionBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .frame(width: 480)
        .onAppear { startStreaming() }
        .keyboardGuardedVariantNav()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "square.split.1x2")
                .foregroundStyle(.purple)
            Text("3 Rewrites")
                .font(.headline)

            if isLoading {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }

            Spacer()

            // Diff toggle
            Toggle(isOn: $showDiff) {
                Label("Diff", systemImage: "text.badge.plus")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle diff view")

            Button { onDismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Variant List

    private var variantList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if variants.isEmpty && isLoading {
                        ForEach(0..<3, id: \.self) { i in
                            variantPlaceholder(index: i)
                        }
                    } else {
                        ForEach(Array(variants.enumerated()), id: \.element.id) { idx, variant in
                            variantCard(variant, index: idx)
                                .id(variant.id)
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 420)
            .onChange(of: focusedIndex) { _, newVal in
                if let variant = variants[safe: newVal] {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(variant.id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Variant Card

    @ViewBuilder
    private func variantCard(_ variant: VariantEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Card header
            HStack {
                Circle()
                    .fill(index == focusedIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(variant.label)
                    .font(.caption)
                    .fontWeight(index == focusedIndex ? .semibold : .regular)
                    .foregroundStyle(index == focusedIndex ? .primary : .secondary)
                Spacer()
                if variant.isStreaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else {
                    Button {
                        onAccept(variant.suggestedText, selectedRange)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                    .help("Accept this variant")
                }
            }

            // Content: diff or plain text
            if showDiff && !variant.suggestedText.isEmpty {
                diffContent(original: originalText, suggested: variant.suggestedText)
            } else {
                Text(variant.suggestedText.isEmpty ? "Generating…" : variant.suggestedText)
                    .font(.system(.callout, design: .default))
                    .foregroundStyle(variant.suggestedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(index == focusedIndex
                    ? Color.accentColor.opacity(0.07)
                    : Color(nsColor: .textBackgroundColor))
                .stroke(index == focusedIndex
                    ? Color.accentColor.opacity(0.4)
                    : Color(nsColor: .separatorColor),
                    lineWidth: index == focusedIndex ? 1.5 : 0.5)
        )
        .onTapGesture { focusedIndex = index }
    }

    @ViewBuilder
    private func variantPlaceholder(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color.secondary.opacity(0.2)).frame(width: 8, height: 8)
                Text("Variant \(index + 1)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 60)
                .shimmer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Diff Content

    @ViewBuilder
    private func diffContent(original: String, suggested: String) -> some View {
        let segments = DiffCalculator.computeDiff(original: original, suggested: suggested)
        DiffFlowText(segments: segments)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button { onDismiss() } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            // Navigation hint
            HStack(spacing: 4) {
                Text("j/k").font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                Text("navigate")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            if let focused = variants[safe: focusedIndex], !focused.isStreaming {
                Button {
                    onAccept(focused.suggestedText, selectedRange)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding()
    }

    // MARK: - Streaming

    private func startStreaming() {
        let service = AIContextMenuService.shared
        let action = AIAction.threeRewrites
        let capturedText = originalText
        let capturedRange = selectedRange

        Task { @MainActor in
            // Initialize 3 empty variant slots
            variants = (0..<3).map { VariantEntry(index: $0, suggestedText: "", isStreaming: true) }

            let stream = service.executeActionStreaming(
                action, selectedText: capturedText, range: capturedRange
            )

            var fullText = ""
            do {
                for try await suggestion in stream {
                    fullText = suggestion.suggestedText
                    let parsed = parseVariants(fullText)
                    // Update each variant slot as text arrives
                    for (i, text) in parsed.enumerated() {
                        if i < variants.count {
                            variants[i].suggestedText = text
                            variants[i].isStreaming = suggestion.isStreaming || i >= parsed.count - 1
                        }
                    }
                }
                // Final parse on completion
                let finalVariants = parseVariants(fullText)
                for i in variants.indices {
                    variants[i].suggestedText = finalVariants[safe: i] ?? variants[i].suggestedText
                    variants[i].isStreaming = false
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Split the raw streamed text into up to 3 variants using the separator marker.
    private func parseVariants(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "---VARIANT---")
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Keyboard Navigation ViewModifier

private extension View {
    func keyboardGuardedVariantNav() -> some View {
        self.onKeyPress(.init("j")) { .ignored }
            .onKeyPress(.init("k")) { .ignored }
    }
}

// MARK: - Inline Diff Flow Text

/// Word-level inline diff rendered as a flow of Text segments.
private struct DiffFlowText: View {
    let segments: [DiffSegment]

    var body: some View {
        segments.reduce(Text("")) { acc, seg in
            acc + styledText(for: seg)
        }
        .font(.system(.callout))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func styledText(for seg: DiffSegment) -> Text {
        switch seg.type {
        case .removed:
            return Text(seg.text)
                .foregroundColor(.red)
                .strikethrough()
        case .added:
            return Text(seg.text)
                .foregroundColor(.green)
                .bold()
        case .unchanged:
            return Text(seg.text)
        }
    }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: phase - 0.3),
                        .init(color: .white.opacity(0.3), location: phase),
                        .init(color: .clear, location: phase + 0.3),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: phase)
            )
            .onAppear { phase = 1.3 }
            .clipped()
    }
}

private extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Preview

#Preview("MultiVariantView") {
    MultiVariantView(
        originalText: "The results show that the method works well in most cases.",
        selectedRange: NSRange(location: 0, length: 60),
        onAccept: { _, _ in },
        onDismiss: {}
    )
    .padding()
    .frame(width: 540, height: 600)
}
