import Foundation
import Combine

/// The central state machine for Vim-style modal editing.
@MainActor
public final class VimState: ObservableObject, EditorState {
    public typealias Mode = VimMode
    public typealias Command = VimCommand

    /// The current editing mode.
    @Published public private(set) var mode: VimMode = .normal

    /// Whether search mode is active.
    @Published public var isSearching: Bool = false

    /// Whether search is backward.
    @Published public private(set) var searchBackward: Bool = false

    /// Current search query.
    @Published public var searchQuery: String = ""

    /// Last repeatable command.
    @Published public private(set) var lastRepeatableCommand: VimCommand?

    /// Text inserted after last insert-mode-entering command.
    @Published public private(set) var lastInsertedText: String = ""

    /// The key handler.
    public let keyHandler: VimKeyHandler

    /// The register manager.
    public let registers: RegisterManager

    /// Publisher for commands.
    public let commandPublisher: PassthroughSubject<VimCommand, Never>

    /// Publisher for search events.
    public let searchPublisher: PassthroughSubject<SearchEvent, Never>

    /// Publisher for accessibility announcements.
    public let accessibilityPublisher: PassthroughSubject<String, Never>

    public init() {
        self.keyHandler = VimKeyHandler()
        self.registers = RegisterManager()
        self.commandPublisher = PassthroughSubject()
        self.searchPublisher = PassthroughSubject()
        self.accessibilityPublisher = PassthroughSubject()
    }

    @discardableResult
    public func handleKey(_ key: Character, modifiers: KeyModifiers, textEngine: (any TextEngine)?) -> Bool {
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

    public func executeSearch(textEngine: (any TextEngine)?) {
        guard !searchQuery.isEmpty else { return }
        isSearching = false

        textEngine?.performSearch(query: searchQuery, backward: searchBackward)
        searchPublisher.send(.searchExecuted(query: searchQuery, backward: searchBackward))
    }

    public func cancelSearch() {
        isSearching = false
        searchQuery = ""
        searchPublisher.send(.searchCancelled)
    }

    public func setMode(_ mode: VimMode) {
        let oldMode = self.mode
        self.mode = mode
        keyHandler.reset()

        if oldMode != mode {
            accessibilityPublisher.send("\(mode.displayName) mode")
        }
    }

    public func reset() {
        mode = .normal
        keyHandler.reset()
        isSearching = false
        searchQuery = ""
    }

    public func recordInsertedText(_ text: String) {
        lastInsertedText = text
    }

    // MARK: - Private

    private func executeCommand(_ command: VimCommand, textEngine: (any TextEngine)?) {
        // Track repeatable commands
        if command.isRepeatable {
            lastRepeatableCommand = command
            lastInsertedText = ""
        }

        // Handle mode-changing commands
        switch command {
        case .enterInsertMode:
            setMode(.insert)
            return

        case .enterInsertModeAfter:
            textEngine?.moveAfterCursor()
            setMode(.insert)
            return

        case .enterInsertModeAtLineStart:
            textEngine?.moveToLineFirstNonBlank(extendSelection: false)
            setMode(.insert)
            return

        case .enterInsertModeAtLineEnd:
            textEngine?.moveToLineEnd(extendSelection: false)
            setMode(.insert)
            return

        case .enterNormalMode:
            setMode(.normal)
            return

        case .enterVisualMode:
            setMode(.visual)
            return

        case .enterVisualLineMode:
            setMode(.visualLine)
            return

        case .openLineBelow:
            textEngine?.openLineBelow()
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .openLineAbove:
            textEngine?.openLineAbove()
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .change:
            if let engine = textEngine, engine.selectedRange.length > 0 {
                let deletedText = engine.text(in: engine.selectedRange) ?? ""
                registers.yank(deletedText)
                engine.replaceSelectedText(with: "")
            }
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .changeMotion(let motion):
            if let engine = textEngine, let range = engine.rangeForMotion(motion), range.length > 0 {
                let deletedText = engine.text(in: range) ?? ""
                registers.yank(deletedText, linewise: motion == .line)
                engine.selectedRange = range
                engine.replaceSelectedText(with: "")
            }
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .changeTextObject(let textObject):
            if let engine = textEngine, let range = engine.rangeForTextObject(textObject), range.length > 0 {
                let deletedText = engine.text(in: range) ?? ""
                registers.yank(deletedText)
                engine.selectedRange = range
                engine.replaceSelectedText(with: "")
            }
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .changeLine(let count):
            executeLinewiseOperation(count: count, delete: true, textEngine: textEngine)
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .changeToEndOfLine:
            if let engine = textEngine {
                let lineRange = (engine.text as NSString).lineRange(for: engine.selectedRange)
                var endPos = lineRange.location + lineRange.length
                if endPos > 0 && endPos <= engine.text.count {
                    let charAtEnd = (engine.text as NSString).character(at: endPos - 1)
                    if charAtEnd == 0x0A { endPos -= 1 }
                }
                let deleteRange = NSRange(location: engine.selectedRange.location, length: endPos - engine.selectedRange.location)
                if deleteRange.length > 0 {
                    let deletedText = engine.text(in: deleteRange) ?? ""
                    registers.yank(deletedText)
                    engine.selectedRange = deleteRange
                    engine.replaceSelectedText(with: "")
                }
            }
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .substitute:
            if let engine = textEngine {
                if engine.selectedRange.length == 0 {
                    let range = NSRange(location: engine.selectedRange.location, length: 1)
                    if range.location + range.length <= engine.text.count {
                        let deletedText = engine.text(in: range) ?? ""
                        registers.yank(deletedText)
                        engine.selectedRange = range
                        engine.replaceSelectedText(with: "")
                    }
                } else {
                    let deletedText = engine.text(in: engine.selectedRange) ?? ""
                    registers.yank(deletedText)
                    engine.replaceSelectedText(with: "")
                }
            }
            setMode(.insert)
            lastRepeatableCommand = command
            return

        case .repeatLastChange:
            if let lastCommand = lastRepeatableCommand {
                executeCommand(lastCommand, textEngine: textEngine)
                if !lastInsertedText.isEmpty {
                    textEngine?.replaceSelectedText(with: lastInsertedText)
                }
            }
            return

        case .repeatFind:
            if let (char, op) = keyHandler.lastFindOp {
                let repeatCommand: VimCommand
                switch op {
                case .findForward: repeatCommand = .findCharacter(char: char, count: 1)
                case .findBackward: repeatCommand = .findCharacterBackward(char: char, count: 1)
                case .tillForward: repeatCommand = .tillCharacter(char: char, count: 1)
                case .tillBackward: repeatCommand = .tillCharacterBackward(char: char, count: 1)
                case .replace: return
                }
                executeCommand(repeatCommand, textEngine: textEngine)
            }
            return

        case .repeatFindReverse:
            if let (char, op) = keyHandler.lastFindOp {
                let repeatCommand: VimCommand
                switch op {
                case .findForward: repeatCommand = .findCharacterBackward(char: char, count: 1)
                case .findBackward: repeatCommand = .findCharacter(char: char, count: 1)
                case .tillForward: repeatCommand = .tillCharacterBackward(char: char, count: 1)
                case .tillBackward: repeatCommand = .tillCharacter(char: char, count: 1)
                case .replace: return
                }
                executeCommand(repeatCommand, textEngine: textEngine)
            }
            return

        default:
            break
        }

        // Execute remaining commands on text engine
        executeOnTextEngine(command, textEngine: textEngine)

        commandPublisher.send(command)
    }

    private func executeOnTextEngine(_ command: VimCommand, textEngine: (any TextEngine)?) {
        guard let engine = textEngine else { return }

        let extendSelection = mode.isSelectionMode && command.extendsSelection

        switch command {
        case .moveLeft(let count):
            engine.moveLeft(count: count, extendSelection: extendSelection)

        case .moveRight(let count):
            engine.moveRight(count: count, extendSelection: extendSelection)

        case .moveUp(let count):
            engine.moveUp(count: count, extendSelection: extendSelection)

        case .moveDown(let count):
            engine.moveDown(count: count, extendSelection: extendSelection)

        case .wordForward(let count), .wordForwardWORD(let count):
            engine.moveWordForward(count: count, extendSelection: extendSelection)

        case .wordBackward(let count), .wordBackwardWORD(let count):
            engine.moveWordBackward(count: count, extendSelection: extendSelection)

        case .wordEnd(let count), .wordEndWORD(let count):
            engine.moveWordEnd(count: count, extendSelection: extendSelection)

        case .lineStart:
            engine.moveToLineStart(extendSelection: extendSelection)

        case .lineEnd:
            engine.moveToLineEnd(extendSelection: extendSelection)

        case .lineFirstNonBlank:
            engine.moveToLineFirstNonBlank(extendSelection: extendSelection)

        case .documentStart:
            engine.moveToDocumentStart(extendSelection: extendSelection)

        case .documentEnd:
            engine.moveToDocumentEnd(extendSelection: extendSelection)

        case .goToLine(let line):
            // Go to specific line number
            let nsText = engine.text as NSString
            var lineCount = 1
            var pos = 0
            while pos < nsText.length && lineCount < line {
                if nsText.character(at: pos) == 0x0A { lineCount += 1 }
                pos += 1
            }
            engine.moveCursor(to: pos, extendSelection: extendSelection)

        case .paragraphForward(let count):
            engine.moveToParagraphForward(count: count, extendSelection: extendSelection)

        case .paragraphBackward(let count):
            engine.moveToParagraphBackward(count: count, extendSelection: extendSelection)

        case .matchingBracket:
            engine.moveToMatchingBracket(extendSelection: extendSelection)

        case .findCharacter(let char, let count):
            engine.findCharacter(char, count: count, extendSelection: extendSelection)

        case .findCharacterBackward(let char, let count):
            engine.findCharacterBackward(char, count: count, extendSelection: extendSelection)

        case .tillCharacter(let char, let count):
            engine.tillCharacter(char, count: count, extendSelection: extendSelection)

        case .tillCharacterBackward(let char, let count):
            engine.tillCharacterBackward(char, count: count, extendSelection: extendSelection)

        case .searchNext(let count):
            engine.searchNext(count: count, extendSelection: extendSelection)

        case .searchPrevious(let count):
            engine.searchPrevious(count: count, extendSelection: extendSelection)

        case .delete:
            if engine.selectedRange.length > 0 {
                let deletedText = engine.text(in: engine.selectedRange) ?? ""
                registers.yank(deletedText)
                engine.replaceSelectedText(with: "")
            }

        case .deleteMotion(let motion):
            if let range = engine.rangeForMotion(motion), range.length > 0 {
                let deletedText = engine.text(in: range) ?? ""
                registers.yank(deletedText, linewise: motion == .line)
                engine.selectedRange = range
                engine.replaceSelectedText(with: "")
            }

        case .deleteTextObject(let textObject):
            if let range = engine.rangeForTextObject(textObject), range.length > 0 {
                let deletedText = engine.text(in: range) ?? ""
                registers.yank(deletedText)
                engine.selectedRange = range
                engine.replaceSelectedText(with: "")
            }

        case .deleteLine(let count):
            executeLinewiseOperation(count: count, delete: true, textEngine: engine)

        case .deleteToEndOfLine:
            let lineRange = (engine.text as NSString).lineRange(for: engine.selectedRange)
            var endPos = lineRange.location + lineRange.length
            if endPos > 0 && endPos <= engine.text.count {
                let charAtEnd = (engine.text as NSString).character(at: endPos - 1)
                if charAtEnd == 0x0A { endPos -= 1 }
            }
            let deleteRange = NSRange(location: engine.selectedRange.location, length: endPos - engine.selectedRange.location)
            if deleteRange.length > 0 {
                let deletedText = engine.text(in: deleteRange) ?? ""
                registers.yank(deletedText)
                engine.selectedRange = deleteRange
                engine.replaceSelectedText(with: "")
            }

        case .yank:
            if engine.selectedRange.length > 0 {
                if let text = engine.text(in: engine.selectedRange) {
                    registers.yank(text)
                }
            }

        case .yankMotion(let motion):
            if let range = engine.rangeForMotion(motion), range.length > 0 {
                if let text = engine.text(in: range) {
                    registers.yank(text, linewise: motion == .line)
                }
            }

        case .yankTextObject(let textObject):
            if let range = engine.rangeForTextObject(textObject), range.length > 0 {
                if let text = engine.text(in: range) {
                    registers.yank(text)
                }
            }

        case .yankLine(let count):
            executeLinewiseOperation(count: count, delete: false, textEngine: engine)

        case .pasteAfter:
            let register = registers.paste()
            if !register.content.isEmpty {
                if register.linewise {
                    // Paste on new line below
                    engine.moveToLineEnd(extendSelection: false)
                    engine.replaceSelectedText(with: "\n" + register.content)
                } else {
                    let insertPosition = engine.selectedRange.location + engine.selectedRange.length
                    engine.selectedRange = NSRange(location: insertPosition, length: 0)
                    engine.replaceSelectedText(with: register.content)
                }
            }

        case .pasteBefore:
            let register = registers.paste()
            if !register.content.isEmpty {
                if register.linewise {
                    engine.moveToLineStart(extendSelection: false)
                    let pos = engine.selectedRange.location
                    engine.replaceSelectedText(with: register.content + "\n")
                    engine.selectedRange = NSRange(location: pos, length: 0)
                } else {
                    engine.replaceSelectedText(with: register.content)
                }
            }

        case .replaceCharacter(let char):
            engine.replaceCharacter(with: char)

        case .joinLines:
            engine.joinLines()

        case .toggleCase:
            engine.toggleCase()

        case .indent:
            engine.indent()

        case .dedent:
            engine.dedent()

        case .indentMotion(let motion):
            if let range = engine.rangeForMotion(motion) {
                indentRange(range, textEngine: engine)
            }

        case .dedentMotion(let motion):
            if let range = engine.rangeForMotion(motion) {
                dedentRange(range, textEngine: engine)
            }

        case .scrollDown(let count):
            engine.scrollDown(count: count, extendSelection: extendSelection)

        case .scrollUp(let count):
            engine.scrollUp(count: count, extendSelection: extendSelection)

        case .pageDown(let count):
            engine.pageDown(count: count, extendSelection: extendSelection)

        case .pageUp(let count):
            engine.pageUp(count: count, extendSelection: extendSelection)

        case .undo:
            engine.performUndo()

        case .redo:
            engine.performRedo()

        case .selectLine:
            engine.selectCurrentLine()

        case .selectAll:
            engine.selectAll()

        default:
            break
        }
    }

    private func executeLinewiseOperation(count: Int, delete: Bool, textEngine: (any TextEngine)?) {
        guard let engine = textEngine else { return }

        let nsText = engine.text as NSString
        let startLineRange = nsText.lineRange(for: engine.selectedRange)

        // Extend to include count lines
        var endPos = startLineRange.location + startLineRange.length
        for _ in 1..<count {
            if endPos < nsText.length {
                let nextLineRange = nsText.lineRange(for: NSRange(location: endPos, length: 0))
                endPos = nextLineRange.location + nextLineRange.length
            }
        }

        let fullRange = NSRange(location: startLineRange.location, length: endPos - startLineRange.location)
        if let text = engine.text(in: fullRange) {
            registers.yank(text, linewise: true)
            if delete {
                engine.selectedRange = fullRange
                engine.replaceSelectedText(with: "")
            }
        }
    }

    private func indentRange(_ range: NSRange, textEngine: (any TextEngine)) {
        let nsText = textEngine.text as NSString
        let startLine = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let endLine = nsText.lineRange(for: NSRange(location: range.location + max(0, range.length - 1), length: 0))

        var currentPos = startLine.location
        var offset = 0

        while currentPos <= endLine.location {
            let lineRange = (textEngine.text as NSString).lineRange(for: NSRange(location: currentPos + offset, length: 0))
            textEngine.selectedRange = NSRange(location: lineRange.location, length: 0)
            textEngine.replaceSelectedText(with: "\t")
            offset += 1

            let nextLineStart = lineRange.location + lineRange.length + 1
            if nextLineStart > endLine.location + offset { break }
            currentPos = nextLineStart - offset
        }
    }

    private func dedentRange(_ range: NSRange, textEngine: (any TextEngine)) {
        let nsText = textEngine.text as NSString
        let startLine = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let endLine = nsText.lineRange(for: NSRange(location: range.location + max(0, range.length - 1), length: 0))

        var currentPos = startLine.location
        var offset = 0

        while currentPos <= endLine.location {
            let adjustedPos = currentPos + offset
            if adjustedPos >= (textEngine.text as NSString).length { break }

            let lineRange = (textEngine.text as NSString).lineRange(for: NSRange(location: adjustedPos, length: 0))
            let lineText = (textEngine.text as NSString).substring(with: lineRange)

            if lineText.hasPrefix("\t") {
                textEngine.selectedRange = NSRange(location: lineRange.location, length: 1)
                textEngine.replaceSelectedText(with: "")
                offset -= 1
            } else if lineText.hasPrefix("    ") {
                textEngine.selectedRange = NSRange(location: lineRange.location, length: 4)
                textEngine.replaceSelectedText(with: "")
                offset -= 4
            } else if lineText.hasPrefix(" ") {
                textEngine.selectedRange = NSRange(location: lineRange.location, length: 1)
                textEngine.replaceSelectedText(with: "")
                offset -= 1
            }

            let nextLineStart = lineRange.location + lineRange.length
            if nextLineStart - offset > endLine.location { break }
            currentPos = nextLineStart - offset
        }
    }
}
