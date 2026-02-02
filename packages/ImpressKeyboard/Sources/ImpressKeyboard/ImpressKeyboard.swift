// ImpressKeyboard
//
// Unified keyboard handling infrastructure for Impress apps.
//
// This package provides:
// - `TextFieldFocusDetection`: Check if a text field is focused (to skip shortcuts)
// - `ShortcutKey`: Enum for keyboard keys (characters and special keys)
// - `ShortcutModifiers`: OptionSet for modifier keys (command, shift, option, control)
// - `.keyboardGuarded {}`: View modifier that auto-skips when text has focus

// Re-export all public types
@_exported import struct SwiftUI.KeyEquivalent
@_exported import struct SwiftUI.EventModifiers
