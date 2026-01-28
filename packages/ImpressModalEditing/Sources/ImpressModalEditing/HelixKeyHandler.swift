import Foundation

/// Result of handling a key event in Helix mode.
/// This is a type alias for the generic KeyResult specialized for HelixCommand.
public typealias HelixKeyResult = KeyResult<HelixCommand>

/// Type of pending operation that expects a character.
public enum PendingCharacterOperation: Sendable, Equatable {
    case findForward      // f
    case findBackward     // F
    case tillForward      // t
    case tillBackward     // T
    case replace          // r
}

/// Pending operator waiting for a motion or text object.
public enum PendingOperator: Sendable, Equatable {
    case delete           // d
    case change           // c
    case yank             // y
    case indent           // >
    case dedent           // <
}

/// Pending text object modifier (inner/around).
public enum PendingTextObjectModifier: Sendable, Equatable {
    case inner            // i
    case around           // a
}

/// Handles key events and translates them to Helix commands.
@MainActor
public final class HelixKeyHandler: ObservableObject, KeyHandler {
    public typealias Mode = HelixMode
    public typealias Command = HelixCommand

    /// Pending key for multi-key sequences (e.g., "g" in "gg").
    @Published public private(set) var pendingKey: Character?

    /// Current count prefix for repeated commands (e.g., "3j" for move down 3 lines).
    @Published public private(set) var countPrefix: Int?

    /// Pending operation waiting for a character input (f, t, r commands).
    @Published public private(set) var pendingCharOp: PendingCharacterOperation?

    /// Last find character command for ; and , repeat.
    @Published public private(set) var lastFindOp: (Character, PendingCharacterOperation)?

    /// Pending operator waiting for motion or text object (d, c, y, etc.).
    @Published public private(set) var pendingOperator: PendingOperator?

    /// Pending text object modifier (i for inner, a for around).
    @Published public private(set) var pendingTextObjectModifier: PendingTextObjectModifier?

    /// Selected register for next yank/paste (nil = default register).
    @Published public private(set) var selectedRegister: Character?

    /// Whether waiting for a character input (f/t/r commands).
    public var isAwaitingCharacter: Bool {
        pendingCharOp != nil
    }

    public init() {}

    /// Handle a key event in the given mode.
    public func handleKey(_ key: Character, in mode: HelixMode, modifiers: KeyModifiers = []) -> HelixKeyResult {
        // In insert mode, only Escape returns to normal mode
        if mode == .insert {
            if key == "\u{1B}" { // Escape
                return .command(.enterNormalMode)
            }
            return .passThrough
        }

        // Handle pending character operation (f, t, r waiting for character)
        if let op = pendingCharOp {
            pendingCharOp = nil
            let count = countPrefix ?? 1
            countPrefix = nil
            return handleCharacterInput(key, operation: op, count: count)
        }

        // Handle pending text object modifier (i/a waiting for object type)
        if let modifier = pendingTextObjectModifier {
            pendingTextObjectModifier = nil
            let count = countPrefix ?? 1
            countPrefix = nil
            return handleTextObjectInput(key, modifier: modifier, count: count)
        }

        // Handle pending operator waiting for motion or text object
        if let op = pendingOperator {
            return handleOperatorMotion(key, operator: op, mode: mode, modifiers: modifiers)
        }

        // Handle register selection (")
        if key == "\"" && selectedRegister == nil {
            pendingKey = "\""
            return .pending
        }

        // Handle numeric prefix for count
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

    /// Reset any pending state.
    public func reset() {
        pendingKey = nil
        countPrefix = nil
        pendingCharOp = nil
        pendingOperator = nil
        pendingTextObjectModifier = nil
        selectedRegister = nil
    }

    // MARK: - Private

    private func handleCharacterInput(_ char: Character, operation: PendingCharacterOperation, count: Int) -> HelixKeyResult {
        // Store for repeat
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

    private func handleSingleKey(_ key: Character, count: Int, mode: HelixMode, modifiers: KeyModifiers) -> HelixKeyResult {
        switch key {
        // Mode changes
        case "i":
            return .command(.enterInsertMode)
        case "\u{1B}": // Escape
            return .command(.enterNormalMode)
        case "v":
            return mode == .select ? .command(.enterNormalMode) : .command(.enterSelectMode)

        // Insert mode variants
        case "a":
            return .command(.appendAfterCursor)
        case "A":
            return .command(.appendAtLineEnd)
        case "I":
            return .command(.insertAtLineStart)
        case "o":
            return .command(.openLineBelow)
        case "O":
            return .command(.openLineAbove)
        case "s":
            return .command(.substitute)

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
        case "b":
            return .command(.wordBackward(count: count))
        case "e":
            return .command(.wordEnd(count: count))
        case "0":
            return .command(.lineStart)
        case "^":
            return .command(.lineFirstNonBlank)
        case "$":
            return .command(.lineEnd)

        // Find character (await next character)
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

        // Repeat find
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

        // Multi-key sequences (start)
        case "g":
            pendingKey = "g"
            return .pending
        case "r":
            pendingCharOp = .replace
            return .awaitingCharacter

        // Selection
        case "x":
            return .command(.selectLine)
        case "%":
            return .command(.selectAll)

        // Operators (wait for motion/text-object)
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
        case "U":
            return .command(.redo)

        // G for document end
        case "G":
            return .command(.documentEnd)

        // Paragraph motions
        case "{":
            return .command(.paragraphBackward(count: count))
        case "}":
            return .command(.paragraphForward(count: count))

        // Matching bracket
        case "m":
            // In Helix, m is the motion for matching bracket (like % in vim)
            return .command(.matchingBracket)

        default:
            // Handle control key combinations
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
                default:
                    break
                }
            }
            return .consumed
        }
    }

    private func handlePendingSequence(first: Character, second: Character, count: Int, mode: HelixMode) -> HelixKeyResult {
        switch (first, second) {
        case ("g", "g"):
            return .command(.documentStart)
        case ("g", "e"):
            // ge - go to end of previous word (backward word end)
            return .command(.wordBackward(count: count))
        case ("\"", _):
            // Register selection: "a, "b, etc.
            if second.isLetter || second == "+" || second == "*" || second == "\"" {
                selectedRegister = second
                return .pending
            }
            return .consumed
        default:
            // Invalid sequence, consume both keys
            return .consumed
        }
    }

    private func handleOperatorMotion(_ key: Character, operator op: PendingOperator, mode: HelixMode, modifiers: KeyModifiers) -> HelixKeyResult {
        let count = countPrefix ?? 1
        countPrefix = nil

        // Same operator twice = line operation (dd, cc, yy, >>, <<)
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
            let motion = HelixMotion.line
            return operatorCommand(op, motion: motion)
        }

        // Text object modifier (i/a)
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

        // Escape cancels pending operator
        if key == "\u{1B}" {
            pendingOperator = nil
            return .consumed
        }

        // Invalid key, cancel operator
        pendingOperator = nil
        return .consumed
    }

    private func handleTextObjectInput(_ key: Character, modifier: PendingTextObjectModifier, count: Int) -> HelixKeyResult {
        guard let textObject = textObjectForKey(key, modifier: modifier) else {
            // Invalid text object, cancel pending operator too
            pendingOperator = nil
            return .consumed
        }

        guard let op = pendingOperator else {
            // No operator, just consume
            return .consumed
        }

        pendingOperator = nil
        return operatorTextObjectCommand(op, textObject: textObject)
    }

    private func motionForKey(_ key: Character, count: Int, modifiers: KeyModifiers) -> HelixMotion? {
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
        case "m": return .matchingBracket
        default:
            // Handle gg through pending key mechanism
            if key == "g" {
                pendingKey = "g"
                return nil
            }
            return nil
        }
    }

    private func textObjectForKey(_ key: Character, modifier: PendingTextObjectModifier) -> HelixTextObject? {
        let inner = modifier == .inner
        switch key {
        case "w":
            return inner ? .innerWord : .aroundWord
        case "W":
            return inner ? .innerWORD : .aroundWORD
        case "\"":
            return inner ? .innerDoubleQuote : .aroundDoubleQuote
        case "'":
            return inner ? .innerSingleQuote : .aroundSingleQuote
        case "`":
            return inner ? .innerBacktick : .aroundBacktick
        case "(", ")":
            return inner ? .innerParen : .aroundParen
        case "[", "]":
            return inner ? .innerBracket : .aroundBracket
        case "{", "}":
            return inner ? .innerBrace : .aroundBrace
        case "<", ">":
            return inner ? .innerAngle : .aroundAngle
        case "p":
            return inner ? .innerParagraph : .aroundParagraph
        default:
            return nil
        }
    }

    private func operatorCommand(_ op: PendingOperator, motion: HelixMotion) -> HelixKeyResult {
        switch op {
        case .delete:
            return .command(.deleteMotion(motion))
        case .change:
            return .command(.changeMotion(motion))
        case .yank:
            return .command(.yankMotion(motion))
        case .indent:
            return .command(.indentMotion(motion))
        case .dedent:
            return .command(.dedentMotion(motion))
        }
    }

    private func operatorTextObjectCommand(_ op: PendingOperator, textObject: HelixTextObject) -> HelixKeyResult {
        switch op {
        case .delete:
            return .command(.deleteTextObject(textObject))
        case .change:
            return .command(.changeTextObject(textObject))
        case .yank:
            return .command(.yankTextObject(textObject))
        case .indent:
            return .command(.indentTextObject(textObject))
        case .dedent:
            return .command(.dedentTextObject(textObject))
        }
    }
}

// KeyModifiers is now defined in Core/KeyHandler.swift
