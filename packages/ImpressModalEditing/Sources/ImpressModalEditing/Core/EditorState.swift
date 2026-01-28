import Foundation
import Combine

/// Protocol for editor state machines.
///
/// The state manages mode transitions, pending key sequences, and command execution.
@MainActor
public protocol EditorState: AnyObject, ObservableObject {
    associatedtype Mode: EditorMode
    associatedtype Command: EditorCommand

    /// The current editing mode.
    var mode: Mode { get }

    /// Whether search mode is active.
    var isSearching: Bool { get set }

    /// Current search query.
    var searchQuery: String { get set }

    /// Whether the search is backward.
    var searchBackward: Bool { get }

    /// Handle a key event.
    /// - Parameters:
    ///   - key: The character pressed.
    ///   - modifiers: Modifier keys held during the press.
    ///   - textEngine: Optional text engine to execute commands on.
    /// - Returns: Whether the key was handled.
    @discardableResult
    func handleKey(_ key: Character, modifiers: KeyModifiers, textEngine: (any TextEngine)?) -> Bool

    /// Set the mode programmatically.
    func setMode(_ mode: Mode)

    /// Reset to the default mode and clear pending state.
    func reset()

    /// Execute a search with the current query.
    func executeSearch(textEngine: (any TextEngine)?)

    /// Cancel the current search.
    func cancelSearch()

    /// Record text inserted during insert mode (for repeat functionality).
    func recordInsertedText(_ text: String)

    /// Publisher for search events.
    var searchPublisher: PassthroughSubject<SearchEvent, Never> { get }

    /// Publisher for accessibility announcements.
    var accessibilityPublisher: PassthroughSubject<String, Never> { get }
}

/// Events related to search functionality.
public enum SearchEvent: Sendable, Equatable {
    /// Search mode has begun.
    case beginSearch(backward: Bool)
    /// Search was executed with the given query.
    case searchExecuted(query: String, backward: Bool)
    /// Search was cancelled.
    case searchCancelled
}
