//
//  AIContextMenuView.swift
//  imprint
//
//  Hierarchical context menu for AI-powered text transformations.
//  Triggered by Cmd+Shift+A in the editor.
//

import SwiftUI

// MARK: - AI Context Menu View

/// The main AI context menu presented as a hierarchical menu.
///
/// Shows categories (Rewrite, Citations, Explain, Structure, Review) as submenus,
/// each containing specific actions that can be performed on selected text.
struct AIContextMenuView: View {
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    let documentSource: String
    let onActionResult: (RewriteSuggestion) -> Void

    @StateObject private var menuService = AIContextMenuService.shared
    @State private var isProcessing = false
    @State private var processingAction: AIAction?

    var body: some View {
        Menu {
            ForEach(menuService.availableCategories) { category in
                categoryMenu(category)
            }
        } label: {
            Label("AI Assistant", systemImage: "sparkles")
        }
    }

    @ViewBuilder
    private func categoryMenu(_ category: AIActionCategory) -> some View {
        Menu {
            ForEach(menuService.actions(for: category)) { action in
                actionButton(action)
            }
        } label: {
            Label(category.title, systemImage: category.icon)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: AIAction) -> some View {
        Button {
            Task {
                await executeAction(action)
            }
        } label: {
            if isProcessing && processingAction?.id == action.id {
                Label(action.title, systemImage: "ellipsis.circle")
            } else {
                Label(action.title, systemImage: action.effectiveIcon)
            }
        }
        .disabled(action.requiresSelection && selectedText.isEmpty)
    }

    private func executeAction(_ action: AIAction) async {
        guard let range = selectedRange else { return }

        isProcessing = true
        processingAction = action

        defer {
            isProcessing = false
            processingAction = nil
        }

        // Build document context
        let context = DocumentContext(
            documentTitle: extractDocumentTitle(from: documentSource),
            surroundingParagraph: extractSurroundingParagraph(source: documentSource, range: range),
            sectionHeading: extractNearestHeading(source: documentSource, position: range.location)
        )

        do {
            let suggestion = try await menuService.executeAction(
                action,
                selectedText: selectedText,
                range: range,
                context: context
            )
            onActionResult(suggestion)
        } catch AIContextMenuError.handledByImbib {
            // imbib opened, nothing more to do
        } catch {
            // Error is handled by the service
        }
    }

    // MARK: - Context Extraction

    private func extractDocumentTitle(from source: String) -> String? {
        // Look for the first = heading
        let lines = source.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("= ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return nil
    }

    private func extractSurroundingParagraph(source: String, range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: source) else { return nil }

        // Find paragraph boundaries (double newlines)
        let beforeText = source[..<swiftRange.lowerBound]
        let afterText = source[swiftRange.upperBound...]

        let paragraphStart = beforeText.range(of: "\n\n", options: .backwards)?.upperBound ?? source.startIndex
        let paragraphEnd = afterText.range(of: "\n\n")?.lowerBound ?? source.endIndex

        let paragraph = String(source[paragraphStart..<paragraphEnd])
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractNearestHeading(source: String, position: Int) -> String? {
        let lines = source.components(separatedBy: .newlines)
        var currentPosition = 0
        var lastHeading: String?

        for line in lines {
            // Check if we've passed the position
            if currentPosition > position {
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=") {
                // Extract heading text (remove = prefix)
                let headingText = trimmed.drop(while: { $0 == "=" || $0 == " " })
                lastHeading = String(headingText)
            }

            currentPosition += line.count + 1 // +1 for newline
        }

        return lastHeading
    }
}

// MARK: - AI Context Menu Popover

/// Popover wrapper for showing the AI context menu at a specific position.
struct AIContextMenuPopover: View {
    @Binding var isPresented: Bool
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    let documentSource: String
    let onActionResult: (RewriteSuggestion) -> Void
    let anchorPosition: CGPoint

    var body: some View {
        VStack(spacing: 0) {
            AIContextMenuContent(
                selectedText: $selectedText,
                selectedRange: $selectedRange,
                documentSource: documentSource,
                onActionResult: { suggestion in
                    onActionResult(suggestion)
                    isPresented = false
                },
                onDismiss: { isPresented = false }
            )
        }
        .frame(width: 280)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - AI Context Menu Content

/// The actual content of the AI context menu (for use in popover or sheet).
struct AIContextMenuContent: View {
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    let documentSource: String
    let onActionResult: (RewriteSuggestion) -> Void
    let onDismiss: () -> Void

    @StateObject private var menuService = AIContextMenuService.shared
    @State private var expandedCategory: AIActionCategory?
    @State private var isProcessing = false
    @State private var processingAction: AIAction?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("AI Assistant")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Selected text preview
            if !selectedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected text:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedText.prefix(80) + (selectedText.count > 80 ? "..." : ""))
                        .font(.caption)
                        .lineLimit(2)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Categories list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(menuService.availableCategories) { category in
                        categorySection(category)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 400)
        }
    }

    @ViewBuilder
    private func categorySection(_ category: AIActionCategory) -> some View {
        VStack(spacing: 0) {
            // Category header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedCategory == category {
                        expandedCategory = nil
                    } else {
                        expandedCategory = category
                    }
                }
            } label: {
                HStack {
                    Image(systemName: category.icon)
                        .frame(width: 20)
                        .foregroundStyle(.purple)
                    Text(category.title)
                        .font(.system(.body, weight: .medium))
                    Spacer()
                    Image(systemName: expandedCategory == category ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded actions
            if expandedCategory == category {
                VStack(spacing: 2) {
                    ForEach(menuService.actions(for: category)) { action in
                        actionRow(action)
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func actionRow(_ action: AIAction) -> some View {
        Button {
            Task {
                await executeAction(action)
            }
        } label: {
            HStack {
                if isProcessing && processingAction?.id == action.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                } else {
                    Image(systemName: action.effectiveIcon)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                Text(action.title)
                    .font(.system(.callout))
                Spacer()
                if action.opensImbib {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled((action.requiresSelection && selectedText.isEmpty) || isProcessing)
        .opacity((action.requiresSelection && selectedText.isEmpty) ? 0.5 : 1)
    }

    private func executeAction(_ action: AIAction) async {
        guard let range = selectedRange else { return }

        isProcessing = true
        processingAction = action

        defer {
            isProcessing = false
            processingAction = nil
        }

        let context = DocumentContext(
            documentTitle: extractDocumentTitle(from: documentSource),
            surroundingParagraph: extractSurroundingParagraph(source: documentSource, range: range),
            sectionHeading: extractNearestHeading(source: documentSource, position: range.location)
        )

        do {
            let suggestion = try await menuService.executeAction(
                action,
                selectedText: selectedText,
                range: range,
                context: context
            )
            onActionResult(suggestion)
        } catch AIContextMenuError.handledByImbib {
            onDismiss()
        } catch {
            // Error handled by service
        }
    }

    // MARK: - Context Helpers

    private func extractDocumentTitle(from source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("= ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return nil
    }

    private func extractSurroundingParagraph(source: String, range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: source) else { return nil }

        let beforeText = source[..<swiftRange.lowerBound]
        let afterText = source[swiftRange.upperBound...]

        let paragraphStart = beforeText.range(of: "\n\n", options: .backwards)?.upperBound ?? source.startIndex
        let paragraphEnd = afterText.range(of: "\n\n")?.lowerBound ?? source.endIndex

        let paragraph = String(source[paragraphStart..<paragraphEnd])
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractNearestHeading(source: String, position: Int) -> String? {
        let lines = source.components(separatedBy: .newlines)
        var currentPosition = 0
        var lastHeading: String?

        for line in lines {
            if currentPosition > position { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=") {
                let headingText = trimmed.drop(while: { $0 == "=" || $0 == " " })
                lastHeading = String(headingText)
            }

            currentPosition += line.count + 1
        }

        return lastHeading
    }
}

// MARK: - Visual Effect View

/// NSVisualEffectView wrapper for SwiftUI.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview

#Preview {
    AIContextMenuContent(
        selectedText: .constant("This is some selected text that the user wants to transform using AI."),
        selectedRange: .constant(NSRange(location: 0, length: 50)),
        documentSource: "= My Document\n\nThis is some selected text that the user wants to transform using AI.\n\n== Next Section\n\nMore content here.",
        onActionResult: { _ in },
        onDismiss: {}
    )
    .frame(width: 280, height: 500)
}
