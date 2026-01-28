import Foundation

/// Vim editor style implementation.
///
/// Vim is a classic modal editor with verb-object grammar.
/// Key differences from Helix:
/// - Operator-first grammar (type operator, then motion/object)
/// - Visual mode for selection
/// - Visual Line mode for line-wise selection
public struct VimStyle: EditorStyle {
    public typealias Mode = VimMode
    public typealias Command = VimCommand
    public typealias State = VimState
    public typealias Handler = VimKeyHandler

    public static let identifier: EditorStyleIdentifier = .vim

    public init() {}

    @MainActor
    public func createState() -> VimState {
        VimState()
    }

    @MainActor
    public func createKeyHandler() -> VimKeyHandler {
        VimKeyHandler()
    }
}
