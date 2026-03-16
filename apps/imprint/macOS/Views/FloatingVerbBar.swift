//
//  FloatingVerbBar.swift
//  imprint
//
//  Compact floating toolbar that appears above the selected text when a selection
//  is active. Shows the 5-6 most scope-relevant AI verbs as chips, plus a "···"
//  button to open the full scope-aware AI palette.
//
//  Placement: anchored to the top of the selection rect in the text view,
//  centered horizontally on the selection. Auto-hides when selection is cleared.
//

import SwiftUI
import AppKit

// MARK: - Floating Verb Bar

/// A compact verb toolbar anchored above the selected text.
///
/// Shows scope-appropriate verb chips:
///   word → Define, Synonyms, Fix Grammar
///   sentence → Concise, Active Voice, Rewrite, Formalize
///   paragraph → Expand, Summarize, 3 Rewrites, Story Arc
///   section+ → Structure Critique, Argument Flow, Abstract
///   ···  → opens full ScopeAIPaletteView
struct FloatingVerbBar: View {
    let selectedText: String
    let selectedRange: NSRange?
    let scopeLevel: ScopeLevel?
    let documentSource: String
    let anchorRect: CGRect       // in window coordinates

    let onActionResult: (RewriteSuggestion) -> Void
    let onOpenFullPalette: () -> Void
    var onError: ((String) -> Void)? = nil

    @State private var isProcessing = false
    @State private var processingActionID: String?

    private var primaryVerbs: [AIAction] {
        AIAction.primaryVerbs(for: scopeLevel)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Scope badge
            if let level = scopeLevel {
                Text("⟨\(level.description)⟩")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                Divider()
                    .frame(height: 16)
            }

            // Primary verb chips
            ForEach(primaryVerbs) { verb in
                verbChip(verb)
            }

            // More button
            Button(action: onOpenFullPalette) {
                Text("···")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("More AI actions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
        )
        .fixedSize()
    }

    // MARK: - Verb Chip

    @ViewBuilder
    private func verbChip(_ action: AIAction) -> some View {
        Button {
            executeAction(action)
        } label: {
            Group {
                if isProcessing && processingActionID == action.id {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        Text(action.shortTitle)
                    }
                } else {
                    Text(action.shortTitle)
                }
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || selectedText.isEmpty)
        .help(action.title)
    }

    // MARK: - Action Execution

    private func executeAction(_ action: AIAction) {
        guard let range = selectedRange, !selectedText.isEmpty else { return }

        isProcessing = true
        processingActionID = action.id

        let service = AIContextMenuService.shared
        let stream = service.executeActionStreaming(action, selectedText: selectedText, range: range)

        Task { @MainActor in
            do {
                var lastSuggestion: RewriteSuggestion?
                for try await suggestion in stream {
                    lastSuggestion = suggestion
                    if suggestion.isStreaming {
                        onActionResult(suggestion)
                    }
                }
                if let final = lastSuggestion {
                    onActionResult(final)
                }
            } catch {
                onError?(error.localizedDescription)
            }
            isProcessing = false
            processingActionID = nil
        }
    }
}

// MARK: - Scope-Aware AI Palette

/// Full flat fuzzy-searchable AI verb palette, scope-aware.
///
/// Replaces the accordion AIContextMenuContent for power users.
/// Triggered by FloatingVerbBar's "···" button, `Cmd+.`, or `<Space>a` (future).
struct ScopeAIPaletteView: View {
    @Binding var selectedText: String
    @Binding var selectedRange: NSRange?
    let scopeLevel: ScopeLevel?
    let documentSource: String
    let onActionResult: (RewriteSuggestion) -> Void
    let onDismiss: () -> Void
    var onError: ((String) -> Void)? = nil

    @State private var query: String = ""
    @State private var focusedIndex: Int = 0
    @State private var isProcessing = false
    @State private var processingActionID: String?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    private var filteredActions: [AIAction] {
        AIAction.scopeRankedActions(for: scopeLevel, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: scope badge + search field
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.system(.body, weight: .semibold))

                if let level = scopeLevel {
                    Text("⟨\(level.description)⟩")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                }

                TextField("AI action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .focused($searchFocused)
                    .onSubmit {
                        if focusedIndex < filteredActions.count {
                            executeAction(filteredActions[focusedIndex])
                        }
                    }

                if isProcessing {
                    Button { AIContextMenuService.shared.cancelCurrentAction() } label: {
                        Text("Cancel").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            Divider()

            // Action list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { idx, action in
                            actionRow(action, index: idx, proxy: proxy)
                        }
                        if filteredActions.isEmpty {
                            Text("No matching actions")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onKeyPress(.upArrow) {
                    focusedIndex = max(0, focusedIndex - 1)
                    proxy.scrollTo(filteredActions[safe: focusedIndex]?.id)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    focusedIndex = min(filteredActions.count - 1, focusedIndex + 1)
                    proxy.scrollTo(filteredActions[safe: focusedIndex]?.id)
                    return .handled
                }
                .onKeyPress(.return) {
                    if focusedIndex < filteredActions.count {
                        executeAction(filteredActions[focusedIndex])
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
            }
        }
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(.rect(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .frame(width: 320)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in focusedIndex = 0 }
    }

    // MARK: - Action Row

    @ViewBuilder
    private func actionRow(_ action: AIAction, index: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            executeAction(action)
        } label: {
            HStack(spacing: 10) {
                if isProcessing && processingActionID == action.id {
                    ProgressView().controlSize(.small).frame(width: 18)
                } else {
                    Image(systemName: action.effectiveIcon)
                        .frame(width: 18)
                        .foregroundStyle(index == focusedIndex ? .white : .secondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                        .font(.callout)
                        .foregroundStyle(index == focusedIndex ? .white : .primary)
                    if let hint = action.hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(index == focusedIndex ? .white.opacity(0.7) : .secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(index == focusedIndex ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(action.id)
        .disabled((action.requiresSelection && selectedText.isEmpty) || isProcessing)
        .onHover { hovered in if hovered { focusedIndex = index } }
    }

    // MARK: - Action Execution

    private func executeAction(_ action: AIAction) {
        guard let range = selectedRange else { return }
        isProcessing = true
        processingActionID = action.id
        errorMessage = nil

        let service = AIContextMenuService.shared
        let capturedText = selectedText
        let stream = service.executeActionStreaming(action, selectedText: capturedText, range: range)

        Task { @MainActor in
            do {
                var lastSuggestion: RewriteSuggestion?
                for try await suggestion in stream {
                    lastSuggestion = suggestion
                    if suggestion.isStreaming { onActionResult(suggestion) }
                }
                if let final = lastSuggestion { onActionResult(final) }
                onDismiss()
            } catch AIContextMenuError.handledByImbib {
                onDismiss()
            } catch is CancellationError {
                // cancelled
            } catch {
                errorMessage = error.localizedDescription
                onError?(error.localizedDescription)
            }
            isProcessing = false
            processingActionID = nil
        }
    }
}

// MARK: - AIAction Extensions for Scope

extension AIAction {

    /// Short display label for floating verb chip.
    var shortTitle: String {
        switch id {
        case "rewrite.make_concise":   return "concise"
        case "rewrite.improve_clarity": return "clarity"
        case "rewrite.make_formal":    return "formal"
        case "rewrite.expand_detail":  return "expand"
        case "rewrite.fix_grammar":    return "grammar"
        case "rewrite.three_rewrites": return "3×rewrite"
        case "review.check_flow":      return "flow"
        case "review.active_voice":    return "active voice"
        case "structure.to_bullets":   return "bullets"
        case "citations.find_supporting": return "find cite"
        default: return title.split(separator: " ").prefix(2).joined(separator: " ")
        }
    }

    /// Short hint shown below the action title in the palette.
    var hint: String? {
        switch id {
        case "rewrite.three_rewrites": return "Shows 3 parallel alternatives"
        case "rewrite.expand_detail":  return "Adds depth and explanation"
        case "review.check_flow":      return "Logical progression analysis"
        case "review.active_voice":    return "Converts passive constructions"
        default: return nil
        }
    }

    /// The 5–6 primary verb chips shown for a given scope level.
    static func primaryVerbs(for level: ScopeLevel?) -> [AIAction] {
        guard let level = level else {
            return [.makeConcise, .improveClarity, .fixGrammar]
        }
        switch level {
        case .word:
            return [.defineTerms, .fixGrammar]
        case .sentence:
            return [.makeConcise, .improveClarity, .makeFormal, .fixGrammar]
        case .paragraph:
            return [.makeConcise, .expandWithDetail, .threeRewrites, .checkLogicalFlow]
        case .subsection, .section:
            return [.makeConcise, .checkLogicalFlow, .identifyWeakArguments, .suggestHeading]
        case .chapter, .document:
            return [.checkLogicalFlow, .identifyWeakArguments, .suggestImprovements]
        }
    }

    /// All actions ranked by relevance for a scope level, filtered by query.
    static func scopeRankedActions(for level: ScopeLevel?, query: String) -> [AIAction] {
        let primary = primaryVerbs(for: level).map(\.id)
        let all = allActions + [.threeRewrites, .activeVoice]

        var ranked = all.sorted { a, b in
            let aIsPrimary = primary.contains(a.id)
            let bIsPrimary = primary.contains(b.id)
            if aIsPrimary != bIsPrimary { return aIsPrimary }
            return a.title < b.title
        }

        if !query.isEmpty {
            let q = query.lowercased()
            ranked = ranked.filter { action in
                action.title.lowercased().contains(q)
                    || action.id.lowercased().contains(q)
                    || (action.hint?.lowercased().contains(q) ?? false)
            }
        }

        return ranked
    }

    // MARK: - Additional Actions

    public static let threeRewrites = AIAction(
        id: "rewrite.three_rewrites",
        category: .rewrite,
        title: "3 rewrites",
        systemPrompt: """
            Generate exactly 3 distinct rewrites of the following text. \
            Each rewrite should take a different approach (e.g., more concise, \
            more formal, more vivid). Separate each rewrite with the marker "---VARIANT---".
            Output only the three rewrites, no explanations.
            """,
        icon: "square.split.1x2"
    )

    public static let activeVoice = AIAction(
        id: "review.active_voice",
        category: .review,
        title: "Convert to active voice",
        systemPrompt: """
            Rewrite the following text, converting passive constructions to active voice \
            wherever it improves clarity. Preserve meaning and academic tone. \
            Output only the rewritten text.
            """,
        icon: "arrow.right.circle"
    )
}

// MARK: - Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
