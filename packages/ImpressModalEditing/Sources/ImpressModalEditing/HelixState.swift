import Foundation
import Combine

/// The central state machine for Helix-style modal editing.
@MainActor
public final class HelixState: ObservableObject {
    /// The current editing mode.
    @Published public private(set) var mode: HelixMode = .normal

    /// The key handler for translating key events to commands.
    public let keyHandler: HelixKeyHandler

    /// The register manager for yank/paste operations.
    public let registers: HelixRegisterManager

    /// Publisher for commands that should be executed on the text engine.
    public let commandPublisher: PassthroughSubject<HelixCommand, Never>

    public init() {
        self.keyHandler = HelixKeyHandler()
        self.registers = HelixRegisterManager()
        self.commandPublisher = PassthroughSubject()
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

        case .pending:
            return true

        case .consumed:
            return true
        }
    }

    /// Set the mode directly (useful for programmatic mode changes).
    public func setMode(_ newMode: HelixMode) {
        mode = newMode
        keyHandler.reset()
    }

    /// Reset the state to normal mode and clear any pending keys.
    public func reset() {
        mode = .normal
        keyHandler.reset()
    }

    // MARK: - Private

    private func executeCommand(_ command: HelixCommand, textEngine: (any HelixTextEngine)?) {
        // Handle mode-changing commands
        switch command {
        case .enterInsertMode:
            mode = .insert
        case .enterNormalMode:
            mode = .normal
            keyHandler.reset()
        case .enterSelectMode:
            mode = .select
        case .change:
            // Change command: execute delete, then switch to insert mode
            if let engine = textEngine {
                engine.execute(.delete, registers: registers, extendSelection: false)
            }
            commandPublisher.send(.delete)
            mode = .insert
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
