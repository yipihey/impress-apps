//
//  FlagInput.swift
//  ImpressFTUI
//

import SwiftUI

/// Inline text field for entering flag commands with keyboard.
///
/// Shows a `ModeIndicator("FLAG")` badge followed by a single-line text field.
/// - Enter: commit the flag command
/// - ESC: cancel and dismiss
/// - ?: toggle syntax help
public struct FlagInput: View {

    @Binding public var isPresented: Bool
    public var onCommit: (PublicationFlag) -> Void
    public var onCancel: (() -> Void)?

    @State private var text = ""
    @State private var showHelp = false
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>,
        onCommit: @escaping (PublicationFlag) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showHelp {
                flagHelpView
            }

            HStack(spacing: 6) {
                ModeIndicator("FLAG", color: .orange)

                TextField("r, a-h, b.q... (? for help)", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 160)
                    .focused($isFocused)
                    .onSubmit {
                        if let flag = parseFlagCommand(text) {
                            onCommit(flag)
                        }
                        dismiss()
                    }
                    .onKeyPress(.escape) {
                        if showHelp {
                            showHelp = false
                            return .handled
                        }
                        dismiss()
                        return .handled
                    }

                // Live preview of the parsed flag
                if let flag = parseFlagCommand(text) {
                    FlagStripe(flag: flag, rowHeight: 16)
                        .frame(width: 4, height: 16)
                    Text(flag.color.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(showHelp ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Flag syntax help")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .task {
            // Delay focus request slightly so the view is in the responder chain
            // (immediate focus in .onAppear can fail during transition animations)
            try? await Task.sleep(for: .milliseconds(100))
            isFocused = true
        }
    }

    private var flagHelpView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Flag Syntax: [color][style][length]")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("Colors")
                        .foregroundStyle(.primary)
                    Text("r red · a amber · b blue · g gray")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Styles")
                        .foregroundStyle(.primary)
                    Text("s solid · - dashed · . dotted")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Lengths")
                        .foregroundStyle(.primary)
                    Text("f full · h half · q quarter")
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("r")
                        .foregroundStyle(.primary)
                    Text("red solid full")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("a-h")
                        .foregroundStyle(.primary)
                    Text("amber dashed half")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("b.q")
                        .foregroundStyle(.primary)
                    Text("blue dotted quarter")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
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

    private func dismiss() {
        text = ""
        isPresented = false
        onCancel?()
    }
}
