import Foundation

/// Identifier for selecting editor styles at runtime.
public enum EditorStyleIdentifier: String, Codable, CaseIterable, Sendable {
    case helix
    case vim
    case emacs

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .helix: return "Helix"
        case .vim: return "Vim"
        case .emacs: return "Emacs"
        }
    }

    /// Short description of the style.
    public var description: String {
        switch self {
        case .helix: return "Selection-first modal editing"
        case .vim: return "Classic modal editing"
        case .emacs: return "Chorded key combinations"
        }
    }
}

/// Protocol for a complete editing style implementation.
///
/// Editor styles define how key events are translated into editing commands
/// and how the editor state machine behaves.
public protocol EditorStyle: Sendable {
    /// The mode type used by this style.
    associatedtype Mode: EditorMode
    /// The command type used by this style.
    associatedtype Command: EditorCommand
    /// The state type used by this style.
    associatedtype State: EditorState where State.Mode == Mode, State.Command == Command
    /// The key handler type used by this style.
    associatedtype Handler: KeyHandler where Handler.Mode == Mode, Handler.Command == Command

    /// The identifier for this style.
    static var identifier: EditorStyleIdentifier { get }

    /// Create a new state machine instance.
    @MainActor func createState() -> State

    /// Create a new key handler instance.
    @MainActor func createKeyHandler() -> Handler
}

/// Type-erased wrapper for editor styles.
public struct AnyEditorStyle: Sendable {
    public let identifier: EditorStyleIdentifier
    private let _createState: @Sendable @MainActor () -> any EditorState
    private let _createKeyHandler: @Sendable @MainActor () -> any KeyHandler

    public init<S: EditorStyle>(_ style: S) {
        self.identifier = S.identifier
        self._createState = { style.createState() }
        self._createKeyHandler = { style.createKeyHandler() }
    }

    @MainActor
    public func createState() -> any EditorState {
        _createState()
    }

    @MainActor
    public func createKeyHandler() -> any KeyHandler {
        _createKeyHandler()
    }
}
