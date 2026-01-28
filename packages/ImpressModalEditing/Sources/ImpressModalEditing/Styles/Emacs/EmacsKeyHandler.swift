import Foundation

/// Pending prefix key for multi-key sequences (C-x, M-g, etc.).
public enum EmacsPendingPrefix: Sendable, Equatable {
    case controlX    // C-x prefix
    case metaG       // M-g prefix (goto)
}

/// Handles key events and translates them to Emacs commands.
@MainActor
public final class EmacsKeyHandler: ObservableObject, KeyHandler {
    public typealias Mode = EmacsMode
    public typealias Command = EmacsCommand

    /// Pending prefix key for multi-key sequences.
    @Published public private(set) var pendingPrefix: EmacsPendingPrefix?

    /// Current universal argument (C-u prefix).
    @Published public private(set) var universalArgument: Int?

    /// Pending key for multi-key sequences (KeyHandler protocol).
    @Published public private(set) var pendingKey: Character?

    /// Current count prefix (KeyHandler protocol).
    @Published public private(set) var countPrefix: Int?

    /// Whether waiting for a character input.
    public var isAwaitingCharacter: Bool {
        false
    }

    public init() {}

    public func handleKey(_ key: Character, in mode: EmacsMode, modifiers: KeyModifiers = []) -> KeyResult<EmacsCommand> {
        // Handle isearch modes specially
        if mode == .isearch || mode == .isearchBackward {
            return handleIsearchKey(key, mode: mode, modifiers: modifiers)
        }

        // Handle pending prefix sequences
        if let prefix = pendingPrefix {
            pendingPrefix = nil
            return handlePrefixSequence(prefix: prefix, key: key, modifiers: modifiers)
        }

        // Handle C-x prefix start
        if modifiers.contains(.control) && key == "x" {
            pendingPrefix = .controlX
            return .pending
        }

        // Handle M-g prefix start
        if modifiers.contains(.meta) && key == "g" {
            pendingPrefix = .metaG
            return .pending
        }

        // Handle Control key combinations
        if modifiers.contains(.control) {
            return handleControlKey(key, mode: mode)
        }

        // Handle Meta key combinations
        if modifiers.contains(.meta) {
            return handleMetaKey(key, mode: mode)
        }

        // Regular key - self insert
        if !modifiers.contains(.control) && !modifiers.contains(.meta) {
            // Special keys
            switch key {
            case "\u{1B}":  // Escape - acts as Meta prefix or cancels
                if mode == .markActive {
                    return .command(.deactivateMark)
                }
                return .command(.keyboardQuit)

            case "\r", "\n":  // Return/Enter
                return .command(.newline)

            case "\u{7F}":  // Backspace/DEL
                return .command(.deleteBackwardChar())

            default:
                // Pass through for regular text input
                return .passThrough
            }
        }

        return .passThrough
    }

    public func reset() {
        pendingPrefix = nil
        universalArgument = nil
    }

    // MARK: - Private Handlers

    private func handleControlKey(_ key: Character, mode: EmacsMode) -> KeyResult<EmacsCommand> {
        switch key {
        // Movement
        case "f":
            return .command(.forwardChar())
        case "b":
            return .command(.backwardChar())
        case "n":
            return .command(.nextLine())
        case "p":
            return .command(.previousLine())
        case "a":
            return .command(.beginningOfLine)
        case "e":
            return .command(.endOfLine)

        // Deletion
        case "d":
            return .command(.deleteChar())
        case "k":
            return .command(.killLine)
        case "w":
            return .command(.killRegion)

        // Yank
        case "y":
            return .command(.yank)

        // Mark
        case " ", "@":  // C-Space or C-@
            return .command(.setMark)

        // Search
        case "s":
            return .command(.isearchForward)
        case "r":
            return .command(.isearchBackward)

        // Undo
        case "/", "_":
            return .command(.undo)

        // Other
        case "g":
            if mode == .markActive {
                return .command(.deactivateMark)
            }
            return .command(.keyboardQuit)

        case "t":
            return .command(.transposeChars)

        case "o":
            return .command(.openLine)

        case "v":
            return .command(.scrollUp())

        case "l":
            return .command(.recenterTopBottom)

        default:
            return .consumed
        }
    }

    private func handleMetaKey(_ key: Character, mode: EmacsMode) -> KeyResult<EmacsCommand> {
        switch key {
        // Word movement
        case "f":
            return .command(.forwardWord())
        case "b":
            return .command(.backwardWord())

        // Sentence movement
        case "a":
            return .command(.beginningOfSentence)
        case "e":
            return .command(.endOfSentence)

        // Paragraph movement
        case "}":
            return .command(.forwardParagraph())
        case "{":
            return .command(.backwardParagraph())

        // Buffer movement
        case "<":
            return .command(.beginningOfBuffer)
        case ">":
            return .command(.endOfBuffer)

        // Deletion
        case "d":
            return .command(.killWord())
        case "\u{7F}":  // M-Backspace
            return .command(.backwardKillWord())

        // Kill ring
        case "w":
            return .command(.killRingSave)
        case "y":
            return .command(.yankPop)

        // Transpose
        case "t":
            return .command(.transposeWords)

        // Case
        case "u":
            return .command(.upcaseWord)
        case "l":
            return .command(.downcaseWord)
        case "c":
            return .command(.capitalizeWord)

        // Scroll
        case "v":
            return .command(.scrollDown())

        default:
            return .consumed
        }
    }

    private func handlePrefixSequence(prefix: EmacsPendingPrefix, key: Character, modifiers: KeyModifiers) -> KeyResult<EmacsCommand> {
        switch prefix {
        case .controlX:
            return handleControlXSequence(key: key, modifiers: modifiers)
        case .metaG:
            return handleMetaGSequence(key: key, modifiers: modifiers)
        }
    }

    private func handleControlXSequence(key: Character, modifiers: KeyModifiers) -> KeyResult<EmacsCommand> {
        // C-x followed by...
        if modifiers.contains(.control) {
            switch key {
            case "x":  // C-x C-x
                return .command(.exchangePointAndMark)
            case "t":  // C-x C-t
                return .command(.transposeLines)
            default:
                return .consumed
            }
        }

        switch key {
        case "h":  // C-x h
            return .command(.markWholeBuffer)
        case "u":  // C-x u
            return .command(.undo)
        default:
            return .consumed
        }
    }

    private func handleMetaGSequence(key: Character, modifiers: KeyModifiers) -> KeyResult<EmacsCommand> {
        // M-g followed by...
        switch key {
        case "g":  // M-g g or M-g M-g
            // This would normally prompt for line number
            // For now, just go to line 1
            return .command(.gotoLine(1))
        default:
            return .consumed
        }
    }

    private func handleIsearchKey(_ key: Character, mode: EmacsMode, modifiers: KeyModifiers) -> KeyResult<EmacsCommand> {
        if modifiers.contains(.control) {
            switch key {
            case "s":
                return .command(.isearchRepeatForward)
            case "r":
                return .command(.isearchRepeatBackward)
            case "g":
                return .command(.isearchAbort)
            default:
                break
            }
        }

        // Return/Enter exits search
        if key == "\r" || key == "\n" {
            return .command(.isearchExit)
        }

        // Escape exits search
        if key == "\u{1B}" {
            return .command(.isearchExit)
        }

        // Other characters are part of the search pattern
        return .passThrough
    }
}
