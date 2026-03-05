//
//  TagInput.swift
//  ImpressFTUI
//

import SwiftUI

/// Inline text field for entering tag paths with autocomplete.
///
/// - Type a tag path (e.g., "methods/hydro")
/// - Arrow keys navigate completions
/// - Tab accepts the highlighted completion
/// - Enter commits the tag
/// - ESC cancels
/// - ?: toggle syntax help
public struct TagInput: View {

    @Binding public var isPresented: Bool
    public var completions: [TagCompletion]
    public var onCommit: (String) -> Void
    public var onCancel: (() -> Void)?
    public var onTextChanged: ((String) -> Void)?

    @State private var text = ""
    @State private var showHelp = false
    @State private var selectedCompletionIndex = 0
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>,
        completions: [TagCompletion] = [],
        onCommit: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil,
        onTextChanged: ((String) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.completions = completions
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onTextChanged = onTextChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showHelp {
                tagHelpView
            }

            HStack(spacing: 6) {
                ModeIndicator("TAG", color: .green)

                TextField("methods/hydro... (? for help)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 160)
                    .focused($isFocused)
                    .onSubmit {
                        commitTag()
                    }
                    .onKeyPress(.escape) {
                        if showHelp {
                            showHelp = false
                            return .handled
                        }
                        dismiss()
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        acceptCompletion()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onChange(of: text) { _, newValue in
                        selectedCompletionIndex = 0
                        onTextChanged?(newValue)
                    }

                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(showHelp ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Tag syntax help")
            }

            // Completion dropdown
            if !completions.isEmpty && !text.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completions.prefix(8).enumerated()), id: \.element.id) { index, completion in
                        HStack(spacing: 4) {
                            TagDot(tag: TagDisplayData(
                                id: completion.id,
                                path: completion.path,
                                leaf: completion.leaf,
                                colorLight: completion.colorLight,
                                colorDark: completion.colorDark
                            ))
                            Text(completion.path)
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            if completion.useCount > 0 {
                                Text("\(completion.useCount)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(index == selectedCompletionIndex ? Color.accentColor.opacity(0.2) : .clear)
                        .onTapGesture {
                            text = completion.path
                            commitTag()
                        }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isFocused = true
        }
    }

    // MARK: - Help View

    private var tagHelpView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tag Syntax")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("methods/hydro")
                        .foregroundStyle(.primary)
                    Text("hierarchical path")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("theory/gravity")
                        .foregroundStyle(.primary)
                    Text("use / for nesting")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("review")
                        .foregroundStyle(.primary)
                    Text("single-level tag")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Text("Tab")
                    .fontWeight(.medium)
                Text("accept completion")
                Text("·")
                Text("↑/↓")
                    .fontWeight(.medium)
                Text("cycle")
                Text("·")
                Text("Enter")
                    .fontWeight(.medium)
                Text("commit")
                Text("·")
                Text("Esc")
                    .fontWeight(.medium)
                Text("cancel")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func commitTag() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        onCommit(trimmed)
        dismiss()
    }

    private func acceptCompletion() {
        guard !completions.isEmpty,
              selectedCompletionIndex < completions.count else { return }
        text = completions[selectedCompletionIndex].path
    }

    private func moveSelection(by offset: Int) {
        guard !completions.isEmpty else { return }
        let count = min(completions.count, 8)
        selectedCompletionIndex = (selectedCompletionIndex + offset + count) % count
    }

    private func dismiss() {
        text = ""
        isPresented = false
        onCancel?()
    }
}
