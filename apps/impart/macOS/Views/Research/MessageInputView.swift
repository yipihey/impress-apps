//
//  MessageInputView.swift
//  impart (macOS)
//
//  Text input with send button for research conversations.
//

import SwiftUI

/// Message input field with send button.
struct MessageInputView: View {
    @Binding var messageInput: String
    let isSending: Bool
    let onSend: () -> Void
    var onAttachArtifact: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                // Attach button
                Button {
                    onAttachArtifact?()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Attach Reference (Cmd+Shift+A)")

                // Text editor
                TextEditor(text: $messageInput)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if messageInput.isEmpty {
                            Text("Ask a question or discuss research...")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }

                // Send button
                Button {
                    onSend()
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .help("Send Message (Cmd+Return)")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()

            // Hint text
            HStack {
                Text("Use @ to mention artifacts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Cmd+Return to send")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .onAppear {
            isFocused = true
        }
    }
}

#Preview {
    VStack {
        Spacer()
        MessageInputView(
            messageInput: .constant("Hello, let's discuss..."),
            isSending: false,
            onSend: {}
        )
    }
    .frame(width: 500, height: 200)
}
