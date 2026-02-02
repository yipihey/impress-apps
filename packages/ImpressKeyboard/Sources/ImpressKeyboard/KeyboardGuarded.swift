import SwiftUI

/// A view modifier that guards keyboard shortcuts from firing when a text field has focus.
///
/// Use this to wrap vim-style navigation handlers so they don't interfere with typing.
///
/// Example:
/// ```swift
/// .keyboardGuarded { press in
///     guard press.modifiers.isEmpty else { return .ignored }
///     switch press.characters {
///     case "j": navigateNext(); return .handled
///     case "k": navigatePrevious(); return .handled
///     default: return .ignored
///     }
/// }
/// ```
public struct KeyboardGuardedModifier: ViewModifier {
    let handler: (KeyPress) -> KeyPress.Result

    public init(handler: @escaping (KeyPress) -> KeyPress.Result) {
        self.handler = handler
    }

    public func body(content: Content) -> some View {
        content.onKeyPress { press in
            guard !TextFieldFocusDetection.isTextFieldFocused() else {
                return .ignored
            }
            return handler(press)
        }
    }
}

extension View {
    /// Adds a keyboard handler that automatically ignores key presses when a text field has focus.
    ///
    /// This prevents vim-style navigation shortcuts (j, k, h, l, etc.) from interfering
    /// with normal text input.
    ///
    /// - Parameter handler: A closure that receives key press events and returns whether they were handled.
    /// - Returns: A view with guarded keyboard handling.
    public func keyboardGuarded(
        handler: @escaping (KeyPress) -> KeyPress.Result
    ) -> some View {
        modifier(KeyboardGuardedModifier(handler: handler))
    }
}
