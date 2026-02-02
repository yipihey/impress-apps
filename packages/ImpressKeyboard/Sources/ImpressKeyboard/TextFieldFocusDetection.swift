import Foundation
#if os(macOS)
import AppKit
#endif

/// Unified text field focus detection for keyboard shortcut handling.
///
/// Use this to guard vim-style shortcuts from firing when the user is typing in a text field.
public enum TextFieldFocusDetection {
    /// Returns `true` if the current first responder is an editable text field.
    ///
    /// On macOS, checks if the key window's first responder is an editable `NSTextView` or `NSTextField`.
    /// On iOS, returns `false` as SwiftUI's `@FocusState` handles focus management.
    @MainActor
    public static func isTextFieldFocused() -> Bool {
        #if os(macOS)
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else {
            return false
        }

        // NSTextView is used by TextEditor, TextField, and other text controls
        if let textView = firstResponder as? NSTextView {
            return textView.isEditable
        }

        // Direct NSTextField check (less common but possible)
        if let textField = firstResponder as? NSTextField {
            return textField.isEditable
        }

        return false
        #else
        return false  // iOS uses SwiftUI focus management
        #endif
    }
}
