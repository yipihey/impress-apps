import Foundation

/// Pending operator waiting for a motion or text object.
public enum VimPendingOperator: Sendable, Equatable {
    case delete     // d
    case change     // c
    case yank       // y
    case indent     // >
    case dedent     // <
}

/// Type of pending operation that expects a character.
public enum VimPendingCharOp: Sendable, Equatable {
    case findForward    // f
    case findBackward   // F
    case tillForward    // t
    case tillBackward   // T
    case replace        // r
}

/// Handles key events and translates them to Vim commands.
@MainActor
public final class VimKeyHandler: ObservableObject, KeyHandler {
    public typealias Mode = VimMode
    public typealias Command = VimCommand

    /// Pending key for multi-key sequences (e.g., "g" in "gg").
    @Published public private(set) var pendingKey: Character?

    /// Current count prefix for repeated commands.
    @Published public private(set) var countPrefix: Int?

    /// Pending operation waiting for a character input (f, t, r commands).
    @Published public private(set) var pendingCharOp: VimPendingCharOp?

    /// Last find character command for ; and , repeat.
    @Published public private(set) var lastFindOp: (Character, VimPendingCharOp)?

    /// Pending operator waiting for motion or text object.
    @Published public private(set) var pendingOperator: VimPendingOperator?

    /// Pending text object modifier (i for inner, a for around).
    @Published public private(set) var pendingTextObjectModifier: TextObjectModifier?

    /// Whether waiting for a character input.
    public var isAwaitingCharacter: Bool {
        pendingCharOp != nil
    }

    public init() {}

    public func handleKey(_ key: Character, in mode: VimMode, modifiers: KeyModifiers = []) -> KeyResult<VimCommand> {
        // In insert mode, only Escape returns to normal mode
        if mode == .insert {
            if key == "\u{1B}" { // Escape
                return .command(.enterNormalMode)
            }
            return .passThrough
        }

        // Handle pending character operation
        if let op = pendingCharOp {
            pendingCharOp = nil
            let count = countPrefix ?? 1
            countPrefix = nil
            return handleCharacterInput(key, operation: op, count: count)
        }

        // Handle pending text object modifier
        if let modifier = pendingTextObjectModifier {
            pendingTextObjectModifier = nil
            let count = countPrefix ?? 1
            countPrefix = nil
            return handleTextObjectInput(key, modifier: modifier, count: count)
        }

        // Handle pending operator
        if let op = pendingOperator {
            return handleOperatorMotion(key, operator: op, mode: mode, modifiers: modifiers)
        }

        // Handle numeric prefix
        if let digit = key.wholeNumberValue, digit > 0 || (countPrefix != nil && digit == 0) {
            countPrefix = (countPrefix ?? 0) * 10 + digit
            return .pending
        }

        let count = countPrefix ?? 1
        defer { countPrefix = nil }

        // Handle pending key sequences
        if let pending = pendingKey {
            pendingKey = nil
            return handlePendingSequence(first: pending, second: key, count: count, mode: mode)
        }

        // Handle single keys
        return handleSingleKey(key, count: count, mode: mode, modifiers: modifiers)
    }

    public func reset() {
        pendingKey = nil
        countPrefix = nil
        pendingCharOp = nil
        pendingOperator = nil
        pendingTextObjectModifier = nil
    }

    // MARK: - Private

    private func handleCharacterInput(_ char: Character, operation: VimPendingCharOp, count: Int) -> KeyResult<VimCommand> {
        lastFindOp = (char, operation)

        switch operation {
        case .findForward:
            return .command(.findCharacter(char: char, count: count))
        case .findBackward:
            return .command(.findCharacterBackward(char: char, count: count))
        case .tillForward:
            return .command(.tillCharacter(char: char, count: count))
        case .tillBackward:
            return .command(.tillCharacterBackward(char: char, count: count))
        case .replace:
            return .command(.replaceCharacter(char: char))
        }
    }

    private func handleSingleKey(_ key: Character, count: Int, mode: VimMode, modifiers: KeyModifiers) -> KeyResult<VimCommand> {
        switch key {
        // Mode changes
        case "i":
            return .command(.enterInsertMode)
        case "a":
            return .command(.enterInsertModeAfter)
        case "I":
            return .command(.enterInsertModeAtLineStart)
        case "A":
            return .command(.enterInsertModeAtLineEnd)
        case "\u{1B}": // Escape
            return .command(.enterNormalMode)
        case "v":
            return mode == .visual ? .command(.enterNormalMode) : .command(.enterVisualMode)
        case "V":
            return mode == .visualLine ? .command(.enterNormalMode) : .command(.enterVisualLineMode)

        // Open line
        case "o":
            return .command(.openLineBelow)
        case "O":
            return .command(.openLineAbove)

        // Movement
        case "h":
            return .command(.moveLeft(count: count))
        case "j":
            return .command(.moveDown(count: count))
        case "k":
            return .command(.moveUp(count: count))
        case "l":
            return .command(.moveRight(count: count))
        case "w":
            return .command(.wordForward(count: count))
        case "W":
            return .command(.wordForwardWORD(count: count))
        case "b":
            return .command(.wordBackward(count: count))
        case "B":
            return .command(.wordBackwardWORD(count: count))
        case "e":
            return .command(.wordEnd(count: count))
        case "E":
            return .command(.wordEndWORD(count: count))
        case "0":
            return .command(.lineStart)
        case "^":
            return .command(.lineFirstNonBlank)
        case "$":
            return .command(.lineEnd)
        case "G":
            if countPrefix != nil {
                return .command(.goToLine(count))
            }
            return .command(.documentEnd)

        // Find character
        case "f":
            pendingCharOp = .findForward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "F":
            pendingCharOp = .findBackward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "t":
            pendingCharOp = .tillForward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case "T":
            pendingCharOp = .tillBackward
            countPrefix = count > 1 ? count : nil
            return .awaitingCharacter
        case ";":
            return .command(.repeatFind)
        case ",":
            return .command(.repeatFindReverse)

        // Search
        case "/":
            return .enterSearch(backward: false)
        case "?":
            return .enterSearch(backward: true)
        case "n":
            return .command(.searchNext(count: count))
        case "N":
            return .command(.searchPrevious(count: count))

        // Multi-key sequences
        case "g":
            pendingKey = "g"
            return .pending
        case "r":
            pendingCharOp = .replace
            return .awaitingCharacter

        // Operators
        case "d":
            pendingOperator = .delete
            countPrefix = count > 1 ? count : nil
            return .pending
        case "c":
            pendingOperator = .change
            countPrefix = count > 1 ? count : nil
            return .pending
        case "y":
            pendingOperator = .yank
            countPrefix = count > 1 ? count : nil
            return .pending
        case ">":
            pendingOperator = .indent
            countPrefix = count > 1 ? count : nil
            return .pending
        case "<":
            pendingOperator = .dedent
            countPrefix = count > 1 ? count : nil
            return .pending

        // Direct commands
        case "x":
            // In normal mode, x deletes character under cursor
            // In visual mode, x deletes selection
            if mode.isSelectionMode {
                return .command(.delete)
            }
            return .command(.deleteMotion(.right(count: count)))
        case "X":
            return .command(.deleteMotion(.left(count: count)))
        case "s":
            return .command(.substitute)
        case "S":
            return .command(.changeLine(count: 1))
        case "C":
            return .command(.changeToEndOfLine)
        case "D":
            return .command(.deleteToEndOfLine)
        case "Y":
            return .command(.yankLine(count: count))

        // Paste
        case "p":
            return .command(.pasteAfter)
        case "P":
            return .command(.pasteBefore)

        // Other editing
        case "J":
            return .command(.joinLines)
        case "~":
            return .command(.toggleCase)

        // Repeat
        case ".":
            return .command(.repeatLastChange)

        // Undo/Redo
        case "u":
            return .command(.undo)

        // Paragraph motions
        case "{":
            return .command(.paragraphBackward(count: count))
        case "}":
            return .command(.paragraphForward(count: count))

        // Matching bracket
        case "%":
            return .command(.matchingBracket)

        default:
            // Control key combinations
            if modifiers.contains(.control) {
                switch key {
                case "d":
                    return .command(.scrollDown(count: count))
                case "u":
                    return .command(.scrollUp(count: count))
                case "f":
                    return .command(.pageDown(count: count))
                case "b":
                    return .command(.pageUp(count: count))
                case "r":
                    return .command(.redo)
                default:
                    break
                }
            }
            return .consumed
        }
    }

    private func handlePendingSequence(first: Character, second: Character, count: Int, mode: VimMode) -> KeyResult<VimCommand> {
        switch (first, second) {
        case ("g", "g"):
            return .command(.documentStart)
        case ("g", "e"):
            return .command(.wordBackward(count: count))
        case ("g", "E"):
            return .command(.wordBackwardWORD(count: count))
        default:
            return .consumed
        }
    }

    private func handleOperatorMotion(_ key: Character, operator op: VimPendingOperator, mode: VimMode, modifiers: KeyModifiers) -> KeyResult<VimCommand> {
        let count = countPrefix ?? 1
        countPrefix = nil

        // Same operator twice = line operation
        let sameKey: Character
        switch op {
        case .delete: sameKey = "d"
        case .change: sameKey = "c"
        case .yank: sameKey = "y"
        case .indent: sameKey = ">"
        case .dedent: sameKey = "<"
        }

        if key == sameKey {
            pendingOperator = nil
            switch op {
            case .delete: return .command(.deleteLine(count: count))
            case .change: return .command(.changeLine(count: count))
            case .yank: return .command(.yankLine(count: count))
            case .indent: return .command(.indentMotion(.line))
            case .dedent: return .command(.dedentMotion(.line))
            }
        }

        // Text object modifier
        if key == "i" {
            pendingTextObjectModifier = .inner
            return .pending
        }
        if key == "a" {
            pendingTextObjectModifier = .around
            return .pending
        }

        // Motion keys
        if let motion = motionForKey(key, count: count, modifiers: modifiers) {
            pendingOperator = nil
            return operatorCommand(op, motion: motion)
        }

        // Escape cancels
        if key == "\u{1B}" {
            pendingOperator = nil
            return .consumed
        }

        pendingOperator = nil
        return .consumed
    }

    private func handleTextObjectInput(_ key: Character, modifier: TextObjectModifier, count: Int) -> KeyResult<VimCommand> {
        guard let textObject = textObjectForKey(key, modifier: modifier) else {
            pendingOperator = nil
            return .consumed
        }

        guard let op = pendingOperator else {
            return .consumed
        }

        pendingOperator = nil
        return operatorTextObjectCommand(op, textObject: textObject)
    }

    private func motionForKey(_ key: Character, count: Int, modifiers: KeyModifiers) -> Motion? {
        switch key {
        case "h": return .left(count: count)
        case "j": return .down(count: count)
        case "k": return .up(count: count)
        case "l": return .right(count: count)
        case "w": return .wordForward(count: count)
        case "W": return .wordForwardWORD(count: count)
        case "b": return .wordBackward(count: count)
        case "B": return .wordBackwardWORD(count: count)
        case "e": return .wordEnd(count: count)
        case "E": return .wordEndWORD(count: count)
        case "0": return .lineStart
        case "^": return .lineFirstNonBlank
        case "$": return .lineEnd
        case "G": return .documentEnd
        case "{": return .paragraphBackward(count: count)
        case "}": return .paragraphForward(count: count)
        case "%": return .matchingBracket
        case "g":
            pendingKey = "g"
            return nil
        default:
            return nil
        }
    }

    private func textObjectForKey(_ key: Character, modifier: TextObjectModifier) -> TextObject? {
        let inner = modifier == .inner
        switch key {
        case "w": return inner ? .innerWord : .aroundWord
        case "W": return inner ? .innerWORD : .aroundWORD
        case "\"": return inner ? .innerDoubleQuote : .aroundDoubleQuote
        case "'": return inner ? .innerSingleQuote : .aroundSingleQuote
        case "`": return inner ? .innerBacktick : .aroundBacktick
        case "(", ")": return inner ? .innerParen : .aroundParen
        case "[", "]": return inner ? .innerBracket : .aroundBracket
        case "{", "}": return inner ? .innerBrace : .aroundBrace
        case "<", ">": return inner ? .innerAngle : .aroundAngle
        case "p": return inner ? .innerParagraph : .aroundParagraph
        default: return nil
        }
    }

    private func operatorCommand(_ op: VimPendingOperator, motion: Motion) -> KeyResult<VimCommand> {
        switch op {
        case .delete: return .command(.deleteMotion(motion))
        case .change: return .command(.changeMotion(motion))
        case .yank: return .command(.yankMotion(motion))
        case .indent: return .command(.indentMotion(motion))
        case .dedent: return .command(.dedentMotion(motion))
        }
    }

    private func operatorTextObjectCommand(_ op: VimPendingOperator, textObject: TextObject) -> KeyResult<VimCommand> {
        switch op {
        case .delete: return .command(.deleteTextObject(textObject))
        case .change: return .command(.changeTextObject(textObject))
        case .yank: return .command(.yankTextObject(textObject))
        case .indent: return .command(.indentMotion(.line))
        case .dedent: return .command(.dedentMotion(.line))
        }
    }
}
