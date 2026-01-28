//
//  IOSBibTeXEditorView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-28.
//

import SwiftUI
import UIKit

// MARK: - iOS BibTeX Editor View

/// A UITextView wrapper with hardware keyboard shortcut support for BibTeX editing.
///
/// Features:
/// - Full hardware keyboard support with shortcuts
/// - Apple Pencil Scribble support (automatic)
/// - Monospaced font for code editing
/// - No autocorrection/autocapitalization for BibTeX
struct IOSBibTeXEditorView: View {

    // MARK: - Properties

    /// The text content
    @Binding var text: String

    /// Callback when save is requested (Cmd+S)
    var onSave: (() -> Void)?

    /// Callback when validation is requested
    var onValidate: ((String) -> Void)?

    /// Current selection range
    @Binding var selection: NSRange?

    /// Focus state
    @FocusState private var isFocused: Bool

    // MARK: - Initialization

    init(
        text: Binding<String>,
        selection: Binding<NSRange?> = .constant(nil),
        onSave: (() -> Void)? = nil,
        onValidate: ((String) -> Void)? = nil
    ) {
        self._text = text
        self._selection = selection
        self.onSave = onSave
        self.onValidate = onValidate
    }

    // MARK: - Body

    var body: some View {
        IOSBibTeXEditorRepresentable(
            text: $text,
            selection: $selection,
            isFocused: $isFocused,
            onSave: onSave,
            onValidate: onValidate
        )
        .focused($isFocused)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - UIKit Representable

struct IOSBibTeXEditorRepresentable: UIViewRepresentable {

    // MARK: - Properties

    @Binding var text: String
    @Binding var selection: NSRange?
    @FocusState.Binding var isFocused: Bool
    var onSave: (() -> Void)?
    var onValidate: ((String) -> Void)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> BibTeXTextView {
        let textView = BibTeXTextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.alwaysBounceVertical = true

        // Enable Scribble (automatic for UITextView)
        textView.isUserInteractionEnabled = true

        // Configure keyboard shortcuts
        textView.onSaveCallback = onSave
        textView.onValidateCallback = onValidate
        configureKeyCommands(for: textView)

        return textView
    }

    func updateUIView(_ textView: BibTeXTextView, context: Context) {
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

        // Update callbacks
        textView.onSaveCallback = onSave
        textView.onValidateCallback = onValidate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Keyboard Commands

    private func configureKeyCommands(for textView: BibTeXTextView) {
        // Save & Validate - Cmd+S
        textView.addKeyCommand(
            input: "s",
            modifierFlags: .command,
            action: #selector(BibTeXTextView.saveAndValidate),
            title: "Save & Validate"
        )

        // Select All - Cmd+A
        textView.addKeyCommand(
            input: "a",
            modifierFlags: .command,
            action: #selector(BibTeXTextView.selectAllText),
            title: "Select All"
        )

        // Copy - Cmd+C (system default, but we ensure it works)
        textView.addKeyCommand(
            input: "c",
            modifierFlags: .command,
            action: #selector(BibTeXTextView.copyText),
            title: "Copy"
        )

        // Undo - Cmd+Z
        textView.addKeyCommand(
            input: "z",
            modifierFlags: .command,
            action: #selector(BibTeXTextView.performUndo),
            title: "Undo"
        )

        // Redo - Cmd+Shift+Z
        textView.addKeyCommand(
            input: "z",
            modifierFlags: [.command, .shift],
            action: #selector(BibTeXTextView.performRedo),
            title: "Redo"
        )

        // Insert field template - Cmd+N
        textView.addKeyCommand(
            input: "n",
            modifierFlags: .command,
            action: #selector(BibTeXTextView.insertFieldTemplate),
            title: "Insert Field"
        )
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: IOSBibTeXEditorRepresentable

        init(_ parent: IOSBibTeXEditorRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            // Trigger validation on change
            parent.onValidate?(textView.text)
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

// MARK: - BibTeX Text View

/// Custom UITextView with keyboard command support for BibTeX editing
class BibTeXTextView: UITextView {

    // MARK: - Properties

    /// Storage for registered key commands
    private var registeredKeyCommands: [UIKeyCommand] = []

    /// Callback for save action
    var onSaveCallback: (() -> Void)?

    /// Callback for validation
    var onValidateCallback: ((String) -> Void)?

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

    @objc func saveAndValidate() {
        onValidateCallback?(text)
        onSaveCallback?()
        showSaveFeedback()
    }

    @objc func selectAllText() {
        selectAll(nil)
    }

    @objc func copyText() {
        if let selectedRange = selectedTextRange,
           let selectedText = text(in: selectedRange),
           !selectedText.isEmpty {
            UIPasteboard.general.string = selectedText
        } else {
            // Copy all if no selection
            UIPasteboard.general.string = text
        }
        showCopyFeedback()
    }

    @objc func performUndo() {
        undoManager?.undo()
    }

    @objc func performRedo() {
        undoManager?.redo()
    }

    @objc func insertFieldTemplate() {
        // Insert a BibTeX field template at cursor
        let template = "    fieldname = {},\n"
        insertText(template)

        // Position cursor inside the braces
        if let currentPosition = selectedTextRange?.start,
           let newPosition = position(from: currentPosition, offset: -3),
           let newRange = textRange(from: newPosition, to: newPosition) {
            selectedTextRange = newRange
        }
    }

    // MARK: - Feedback

    private func showSaveFeedback() {
        showFeedback(text: "Saved", color: .systemGreen)
    }

    private func showCopyFeedback() {
        showFeedback(text: "Copied", color: .systemBlue)
    }

    private func showFeedback(text: String, color: UIColor) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = color.withAlphaComponent(0.9)
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
    IOSBibTeXEditorView(
        text: .constant("""
        @article{Einstein1905,
            title = {On the Electrodynamics of Moving Bodies},
            author = {Einstein, Albert},
            journal = {Annalen der Physik},
            year = {1905},
            volume = {17},
            pages = {891--921}
        }
        """),
        onSave: { print("Save requested") },
        onValidate: { text in print("Validating: \(text.prefix(50))...") }
    )
    .padding()
}
