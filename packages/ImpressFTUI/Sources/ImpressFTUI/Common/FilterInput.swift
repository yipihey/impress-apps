//
//  FilterInput.swift
//  ImpressFTUI
//

import SwiftUI

/// Inline text field for entering filter expressions with keyboard.
///
/// Filters interactively as you type via `onTextChanged`.
/// - Enter: dismiss the input (filter stays active)
/// - ESC: clear filter and dismiss
public struct FilterInput: View {

    @Binding public var isPresented: Bool
    public var currentText: String
    public var onTextChanged: ((String) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onCancel: (() -> Void)?

    @State private var text: String
    @FocusState private var isFocused: Bool

    public init(
        isPresented: Binding<Bool>,
        currentText: String = "",
        onTextChanged: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.currentText = currentText
        self.onTextChanged = onTextChanged
        self.onDismiss = onDismiss
        self.onCancel = onCancel
        self._text = State(initialValue: currentText)
    }

    public var body: some View {
        HStack(spacing: 6) {
            ModeIndicator("FILTER", color: .purple)

            TextField("flag:r-h tags:methods unread...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onSubmit {
                    // Enter: keep filter active, just dismiss the input
                    isPresented = false
                    onDismiss?()
                }
                .onKeyPress(.escape) {
                    // ESC: clear filter and dismiss
                    text = ""
                    onTextChanged?("")
                    isPresented = false
                    onCancel?()
                    return .handled
                }
                .onChange(of: text) { _, newValue in
                    onTextChanged?(newValue)
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    onTextChanged?("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .onAppear {
            isFocused = true
        }
    }
}
