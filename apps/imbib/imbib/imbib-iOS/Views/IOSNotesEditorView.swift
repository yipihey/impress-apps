//
//  IOSNotesEditorView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-28.
//

import SwiftUI
import UIKit

// MARK: - iOS Notes Editor View

/// A UITextView wrapper with hardware keyboard shortcut support for notes editing.
///
/// Features:
/// - Full hardware keyboard support with shortcuts
/// - Apple Pencil Scribble support (automatic)
/// - Touch-friendly text selection
/// - Markdown formatting shortcuts
struct IOSNotesEditorView: View {

    // MARK: - Properties

    /// The text content
    @Binding var text: String

    /// Callback when save is requested (Cmd+S)
    var onSave: (() -> Void)?

    /// Current selection range
    @Binding var selection: NSRange?

    /// Focus state
    @FocusState private var isFocused: Bool

    // MARK: - Initialization

    init(
        text: Binding<String>,
        selection: Binding<NSRange?> = .constant(nil),
        onSave: (() -> Void)? = nil
    ) {
        self._text = text
        self._selection = selection
        self.onSave = onSave
    }

    // MARK: - Body

    var body: some View {
        IOSNotesEditorRepresentable(
            text: $text,
            selection: $selection,
            isFocused: $isFocused,
            onSave: onSave
        )
        .focused($isFocused)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - UIKit Representable

struct IOSNotesEditorRepresentable: UIViewRepresentable {

    // MARK: - Properties

    @Binding var text: String
    @Binding var selection: NSRange?
    @FocusState.Binding var isFocused: Bool
    var onSave: (() -> Void)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> NotesTextView {
        let textView = NotesTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.spellCheckingType = .default
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.alwaysBounceVertical = true

        // Enable Scribble (automatic for UITextView)
        textView.isUserInteractionEnabled = true

        // Configure keyboard shortcuts
        textView.onSaveCallback = onSave
        configureKeyCommands(for: textView)

        return textView
    }

    func updateUIView(_ textView: NotesTextView, context: Context) {
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

        // Update callback
        textView.onSaveCallback = onSave
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Keyboard Commands

    private func configureKeyCommands(for textView: NotesTextView) {
        // Save - Cmd+S
        textView.addKeyCommand(
            input: "s",
            modifierFlags: .command,
            action: #selector(NotesTextView.saveDocument),
            title: "Save Notes"
        )

        // Bold - Cmd+B (wraps with **)
        textView.addKeyCommand(
            input: "b",
            modifierFlags: .command,
            action: #selector(NotesTextView.toggleBold),
            title: "Bold"
        )

        // Italic - Cmd+I (wraps with *)
        textView.addKeyCommand(
            input: "i",
            modifierFlags: .command,
            action: #selector(NotesTextView.toggleItalic),
            title: "Italic"
        )

        // Undo - Cmd+Z (system default, but we ensure it works)
        textView.addKeyCommand(
            input: "z",
            modifierFlags: .command,
            action: #selector(NotesTextView.performUndo),
            title: "Undo"
        )

        // Redo - Cmd+Shift+Z
        textView.addKeyCommand(
            input: "z",
            modifierFlags: [.command, .shift],
            action: #selector(NotesTextView.performRedo),
            title: "Redo"
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSNotesEditorRepresentable

        init(_ parent: IOSNotesEditorRepresentable) {
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

// MARK: - Notes Text View

/// Custom UITextView with keyboard command support for notes editing
class NotesTextView: UITextView {

    // MARK: - Properties

    /// Storage for registered key commands
    private var registeredKeyCommands: [UIKeyCommand] = []

    /// Callback for save action
    var onSaveCallback: (() -> Void)?

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        return registeredKeyCommands
    }

    func addKeyCommand(input: String, modifierFlags: UIKeyModifierFlags, action: Selector, title: String) {
        let command = UIKeyCommand(
            title: title,
            action: action,
            input: input,
            modifierFlags: modifierFlags
        )
        command.wantsPriorityOverSystemBehavior = true
        registeredKeyCommands.append(command)
    }

    // MARK: - Actions

    @objc func saveDocument() {
        onSaveCallback?()

        // Show brief visual feedback
        showSaveFeedback()
    }

    @objc func toggleBold() {
        wrapSelection(with: "**")
    }

    @objc func toggleItalic() {
        wrapSelection(with: "*")
    }

    @objc func performUndo() {
        undoManager?.undo()
    }

    @objc func performRedo() {
        undoManager?.redo()
    }

    // MARK: - Helpers

    private func wrapSelection(with wrapper: String) {
        guard let currentRange = selectedTextRange else { return }

        let selectedText = text(in: currentRange) ?? ""

        // Check if already wrapped (toggle off)
        if selectedText.hasPrefix(wrapper) && selectedText.hasSuffix(wrapper) && selectedText.count >= wrapper.count * 2 {
            let unwrapped = String(selectedText.dropFirst(wrapper.count).dropLast(wrapper.count))
            replace(currentRange, withText: unwrapped)
            return
        }

        // Wrap selection
        let wrappedText = "\(wrapper)\(selectedText)\(wrapper)"
        replace(currentRange, withText: wrappedText)

        // Adjust selection to be inside the wrapper if text was empty
        if selectedText.isEmpty {
            if let newPosition = position(from: currentRange.start, offset: wrapper.count),
               let newRange = textRange(from: newPosition, to: newPosition) {
                self.selectedTextRange = newRange
            }
        }
    }

    private func showSaveFeedback() {
        // Create a brief "Saved" indicator
        let label = UILabel()
        label.text = "Saved"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.sizeToFit()
        label.frame.size.width += 24
        label.frame.size.height += 8

        // Position at top-right of text view
        label.center = CGPoint(
            x: bounds.maxX - label.bounds.width / 2 - 16,
            y: safeAreaInsets.top + label.bounds.height / 2 + 8
        )
        label.alpha = 0

        addSubview(label)

        // Animate
        UIView.animate(withDuration: 0.2) {
            label.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.2, delay: 0.8) {
                label.alpha = 0
            } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    IOSNotesEditorView(
        text: .constant("# My Notes\n\nThis is a sample note with **bold** and *italic* text."),
        onSave: { print("Save requested") }
    )
    .padding()
}
