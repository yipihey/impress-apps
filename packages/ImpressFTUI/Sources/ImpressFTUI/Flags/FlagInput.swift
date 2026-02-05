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
public struct FlagInput: View {

    @Binding public var isPresented: Bool
    public var onCommit: (PublicationFlag) -> Void
    public var onCancel: (() -> Void)?

    @State private var text = ""
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
        HStack(spacing: 6) {
            ModeIndicator("FLAG", color: .orange)

            TextField("r, a-h, b.q...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 80)
                .focused($isFocused)
                .onSubmit {
                    if let flag = parseFlagCommand(text) {
                        onCommit(flag)
                    }
                    dismiss()
                }
                .onKeyPress(.escape) {
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            isFocused = true
        }
    }

    private func dismiss() {
        text = ""
        isPresented = false
        onCancel?()
    }
}
