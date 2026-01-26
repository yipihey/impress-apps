import Foundation

/// The editing mode in Helix-style modal editing.
public enum HelixMode: String, Sendable, CaseIterable {
    /// Normal mode for navigation and commands.
    case normal
    /// Insert mode for typing text.
    case insert
    /// Select mode for extending selections.
    case select

    /// Display name for the mode indicator.
    public var displayName: String {
        rawValue.uppercased()
    }
}
