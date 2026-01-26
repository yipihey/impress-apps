import Foundation
import Combine

/// The central state machine for Helix-style modal editing.
@MainActor
public final class HelixState: ObservableObject {
    /// The current editing mode.
    @Published public private(set) var mode: HelixMode = .normal

    /// Whether search mode is active (shows search UI).
    @Published public var isSearching: Bool = false

    /// Whether search is backward.
    @Published public var searchBackward: Bool = false

    /// Current search query.
    @Published public var searchQuery: String = ""

    /// Last repeatable command for `.` functionality.
    @Published public private(set) var lastRepeatableCommand: HelixCommand?

    /// Text inserted after last insert-mode-entering command (for repeat).
    @Published public private(set) var lastInsertedText: String = ""

    /// The key handler for translating key events to commands.
    public let keyHandler: HelixKeyHandler

    /// The register manager for yank/paste operations.
    public let registers: HelixRegisterManager

    /// Publisher for commands that should be executed on the text engine.
    public let commandPublisher: PassthroughSubject<HelixCommand, Never>

    /// Publisher for search events.
    public let searchPublisher: PassthroughSubject<SearchEvent, Never>

    /// Publisher for accessibility announcements.
    public let accessibilityPublisher: PassthroughSubject<String, Never>

    public init() {
        self.keyHandler = HelixKeyHandler()
        self.registers = HelixRegisterManager()
        self.commandPublisher = PassthroughSubject()
        self.searchPublisher = PassthroughSubject()
        self.accessibilityPublisher = PassthroughSubject()
    }

    /// Handle a key event and optionally execute commands on the given text engine.
    /// - Parameters:
    ///   - key: The character that was pressed.
    ///   - modifiers: Any modifier keys that were held.
    ///   - textEngine: Optional text engine to execute commands on directly.
    /// - Returns: Whether the key was handled (true) or should be passed through (false).
    @discardableResult
    public func handleKey(_ key: Character, modifiers: KeyModifiers = [], textEngine: (any HelixTextEngine)? = nil) -> Bool {
        let result = keyHandler.handleKey(key, in: mode, modifiers: modifiers)

        switch result {
        case .command(let command):
            executeCommand(command, textEngine: textEngine)
            return true

        case .commands(let commands):
            for command in commands {
                executeCommand(command, textEngine: textEngine)
            }
            return true

        case .passThrough:
            return false

        case .pending, .awaitingCharacter:
            return true

        case .consumed:
            return true

        case .enterSearch(let backward):
            isSearching = true
            searchBackward = backward
            searchQuery = ""
            searchPublisher.send(.beginSearch(backward: backward))
            return true
        }
    }

    /// Execute a search with the current query.
    public func executeSearch(textEngine: (any HelixTextEngine)? = nil) {
        guard !searchQuery.isEmpty else { return }
        isSearching = false

        if let engine = textEngine {
            engine.performSearch(query: searchQuery, backward: searchBackward)
        }
        searchPublisher.send(.searchExecuted(query: searchQuery, backward: searchBackward))
    }

    /// Cancel the current search.
    public func cancelSearch() {
        isSearching = false
        searchQuery = ""
        searchPublisher.send(.searchCancelled)
    }

    /// Set the mode directly (useful for programmatic mode changes).
    public func setMode(_ newMode: HelixMode) {
        let oldMode = mode
        mode = newMode
        keyHandler.reset()

        // Announce mode change for accessibility
        if oldMode != newMode {
            accessibilityPublisher.send("\(newMode.displayName) mode")
        }
    }

    /// Reset the state to normal mode and clear any pending keys.
    public func reset() {
        mode = .normal
        keyHandler.reset()
        isSearching = false
        searchQuery = ""
    }

    /// Record text inserted during insert mode (for repeat functionality).
    public func recordInsertedText(_ text: String) {
        lastInsertedText = text
    }

    // MARK: - Private

    private func executeCommand(_ command: HelixCommand, textEngine: (any HelixTextEngine)?) {
        // Track repeatable commands
        if command.isRepeatable {
            lastRepeatableCommand = command
            lastInsertedText = ""
        }

        // Handle mode-changing commands
        switch command {
        case .enterInsertMode:
            setMode(.insert)
        case .enterNormalMode:
            setMode(.normal)
        case .enterSelectMode:
            setMode(.select)
        case .enterSearchMode(let backward):
            isSearching = true
            searchBackward = backward
            searchQuery = ""
            searchPublisher.send(.beginSearch(backward: backward))
            return
        case .change:
            // Change command: execute delete, then switch to insert mode
            if let engine = textEngine {
                engine.execute(.delete, registers: registers, extendSelection: false)
            }
            commandPublisher.send(.delete)
            setMode(.insert)
            lastRepeatableCommand = .change
            return
        case .openLineBelow, .openLineAbove:
            // Open line and enter insert mode
            if let engine = textEngine {
                let extendSelection = mode == .select && command.extendsSelection
                engine.execute(command, registers: registers, extendSelection: extendSelection)
            }
            commandPublisher.send(command)
            setMode(.insert)
            return
        case .appendAfterCursor, .appendAtLineEnd, .insertAtLineStart:
            // These enter insert mode after positioning
            if let engine = textEngine {
                let extendSelection = mode == .select && command.extendsSelection
                engine.execute(command, registers: registers, extendSelection: extendSelection)
            }
            commandPublisher.send(command)
            setMode(.insert)
            return
        case .substitute:
            // Delete character and enter insert mode
            if let engine = textEngine {
                engine.execute(.delete, registers: registers, extendSelection: false)
            }
            commandPublisher.send(.delete)
            setMode(.insert)
            lastRepeatableCommand = .substitute
            return
        case .repeatLastChange:
            // Execute the last repeatable command
            if let lastCommand = lastRepeatableCommand {
                executeCommand(lastCommand, textEngine: textEngine)
                // If the last command entered insert mode, re-insert the text
                if !lastInsertedText.isEmpty {
                    textEngine?.replaceSelectedText(with: lastInsertedText)
                }
            }
            return
        case .repeatFind:
            // Repeat last find operation
            if let (char, op) = keyHandler.lastFindOp {
                let repeatCommand: HelixCommand
                switch op {
                case .findForward:
                    repeatCommand = .findCharacter(char: char, count: 1)
                case .findBackward:
                    repeatCommand = .findCharacterBackward(char: char, count: 1)
                case .tillForward:
                    repeatCommand = .tillCharacter(char: char, count: 1)
                case .tillBackward:
                    repeatCommand = .tillCharacterBackward(char: char, count: 1)
                case .replace:
                    return // Can't repeat replace with ;
                }
                executeCommand(repeatCommand, textEngine: textEngine)
            }
            return
        case .repeatFindReverse:
            // Repeat last find operation in reverse
            if let (char, op) = keyHandler.lastFindOp {
                let repeatCommand: HelixCommand
                switch op {
                case .findForward:
                    repeatCommand = .findCharacterBackward(char: char, count: 1)
                case .findBackward:
                    repeatCommand = .findCharacter(char: char, count: 1)
                case .tillForward:
                    repeatCommand = .tillCharacterBackward(char: char, count: 1)
                case .tillBackward:
                    repeatCommand = .tillCharacter(char: char, count: 1)
                case .replace:
                    return // Can't repeat replace with ,
                }
                executeCommand(repeatCommand, textEngine: textEngine)
            }
            return
        default:
            break
        }

        // Execute the command on the text engine if provided
        if let engine = textEngine {
            let extendSelection = mode == .select && command.extendsSelection
            engine.execute(command, registers: registers, extendSelection: extendSelection)
        }

        // Also publish the command for observers
        commandPublisher.send(command)
    }
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
