import Foundation

/// Protocol for editor mode types.
///
/// Each editor style defines its own mode enum that conforms to this protocol.
/// Modes represent the different states the editor can be in (e.g., normal, insert, visual).
public protocol EditorMode: Hashable, Sendable, CaseIterable {
    /// Display name shown in the mode indicator.
    var displayName: String { get }

    /// Whether this mode allows direct text input (like insert mode).
    var allowsTextInput: Bool { get }

    /// Whether this mode should show the mode indicator.
    /// Some modes (like Emacs default state) don't need an indicator.
    var showsIndicator: Bool { get }
}

/// Common mode behaviors shared across styles.
public extension EditorMode {
    /// Default: show indicator.
    var showsIndicator: Bool { true }
}
