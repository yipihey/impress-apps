import Foundation

/// Emacs editor style implementation.
///
/// Emacs uses a non-modal editing approach with chorded key combinations.
/// Key characteristics:
/// - Always in "insert mode" - text is inserted directly
/// - Control (C-) and Meta (M-) modifiers for commands
/// - Mark-based selection (set mark, then move to extend)
/// - Kill ring for clipboard history
public struct EmacsStyle: EditorStyle {
    public typealias Mode = EmacsMode
    public typealias Command = EmacsCommand
    public typealias State = EmacsState
    public typealias Handler = EmacsKeyHandler

    public static let identifier: EditorStyleIdentifier = .emacs

    public init() {}

    @MainActor
    public func createState() -> EmacsState {
        EmacsState()
    }

    @MainActor
    public func createKeyHandler() -> EmacsKeyHandler {
        EmacsKeyHandler()
    }
}
