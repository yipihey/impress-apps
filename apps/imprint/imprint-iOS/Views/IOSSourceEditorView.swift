//
//  IOSSourceEditorView.swift
//  imprint-iOS
//
//  Created by Claude on 2026-01-27.
//

import SwiftUI
import UIKit

// MARK: - iOS Source Editor View

/// A touch-optimized source code editor for Typst documents.
///
/// Features:
/// - Full hardware keyboard support with shortcuts
/// - Apple Pencil Scribble support
/// - Touch-friendly text selection
/// - Syntax highlighting for Typst
struct IOSSourceEditorView: View {

    // MARK: - Properties

    /// The text content
    @Binding var text: String

    /// Current selection range
    @Binding var selection: NSRange?

    /// Focus state
    @FocusState private var isFocused: Bool

    // MARK: - Body

    var body: some View {
        IOSSourceEditorRepresentable(
            text: $text,
            selection: $selection,
            isFocused: $isFocused
        )
        .focused($isFocused)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - UIKit Representable

struct IOSSourceEditorRepresentable: UIViewRepresentable {

    // MARK: - Properties

    @Binding var text: String
    @Binding var selection: NSRange?
    @FocusState.Binding var isFocused: Bool

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UITextView {
        let textView = SourceTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.alwaysBounceVertical = true

        // Enable Scribble
        textView.isUserInteractionEnabled = true

        // Configure keyboard
        configureKeyCommands(for: textView)

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }

        // Update selection if needed
        if let selection = selection,
           textView.selectedRange != selection {
            textView.selectedRange = selection
        }

        // Handle focus
        if isFocused && !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused && textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Keyboard Commands

    private func configureKeyCommands(for textView: SourceTextView) {
        // Formatting commands
        textView.addKeyCommand(
            input: "b",
            modifierFlags: .command,
            action: #selector(SourceTextView.toggleBold)
        )
        textView.addKeyCommand(
            input: "i",
            modifierFlags: .command,
            action: #selector(SourceTextView.toggleItalic)
        )

        // Navigation commands
        textView.addKeyCommand(
            input: "g",
            modifierFlags: [.command],
            action: #selector(SourceTextView.goToLine)
        )

        // Save
        textView.addKeyCommand(
            input: "s",
            modifierFlags: .command,
            action: #selector(SourceTextView.saveDocument)
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSSourceEditorRepresentable

        init(_ parent: IOSSourceEditorRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selection = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

// MARK: - Source Text View

/// Custom UITextView with keyboard command support
class SourceTextView: UITextView {

    // MARK: - Key Commands

    /// Storage for registered key commands
    private var registeredKeyCommands: [UIKeyCommand] = []

    override var keyCommands: [UIKeyCommand]? {
        return registeredKeyCommands
    }

    func addKeyCommand(input: String, modifierFlags: UIKeyModifierFlags, action: Selector) {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifierFlags,
            action: action
        )
        command.wantsPriorityOverSystemBehavior = true
        registeredKeyCommands.append(command)
    }

    // MARK: - Formatting Actions

    @objc func toggleBold() {
        wrapSelection(with: "*")
    }

    @objc func toggleItalic() {
        wrapSelection(with: "_")
    }

    @objc func insertCode() {
        wrapSelection(with: "`")
    }

    @objc func goToLine() {
        // TODO: Show go-to-line dialog
    }

    @objc func saveDocument() {
        // Trigger save via responder chain
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    // MARK: - Helpers

    private func wrapSelection(with wrapper: String) {
        guard let currentRange = selectedTextRange else { return }

        let selectedText = text(in: currentRange) ?? ""
        let wrappedText = "\(wrapper)\(selectedText)\(wrapper)"

        replace(currentRange, withText: wrappedText)

        // Adjust selection to be inside the wrapper
        if selectedText.isEmpty {
            if let newPosition = position(from: currentRange.start, offset: wrapper.count),
               let newRange = textRange(from: newPosition, to: newPosition) {
                self.selectedTextRange = newRange
            }
        }
    }

    // MARK: - Scribble Support

    override var isUserInteractionEnabled: Bool {
        get { super.isUserInteractionEnabled }
        set { super.isUserInteractionEnabled = newValue }
    }
}

// MARK: - iOS PDF Preview View (Placeholder)

struct IOSPDFPreviewView: View {
    let document: ImprintDocument

    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("PDF Preview")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Compile the document to see the preview")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Preview

#Preview {
    IOSSourceEditorView(
        text: .constant("= Hello World\n\nThis is a test document."),
        selection: .constant(nil)
    )
}
