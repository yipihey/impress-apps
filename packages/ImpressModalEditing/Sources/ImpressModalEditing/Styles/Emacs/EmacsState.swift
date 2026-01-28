import Foundation
import Combine

/// State machine for Emacs-style editing.
///
/// Manages mode state, mark position, and kill ring for Emacs editing.
@MainActor
public final class EmacsState: ObservableObject, EditorState {
    public typealias Mode = EmacsMode
    public typealias Command = EmacsCommand

    /// Current editing mode.
    @Published public private(set) var mode: EmacsMode = .normal

    /// Whether search mode is active.
    @Published public var isSearching: Bool = false

    /// Current search query (for incremental search).
    @Published public var searchQuery: String = ""

    /// Whether the search is backward.
    @Published public private(set) var searchBackward: Bool = false

    /// Mark position (for region selection).
    @Published public private(set) var markPosition: Int?

    /// Kill ring for storing killed text.
    private var emacsKillRing: EmacsKillRing = EmacsKillRing()

    /// Last command for yank-pop tracking.
    private var lastCommand: EmacsCommand?

    /// Key handler for this state.
    private let keyHandler = EmacsKeyHandler()

    /// Publisher for search events.
    public let searchPublisher = PassthroughSubject<SearchEvent, Never>()

    /// Publisher for accessibility announcements.
    public let accessibilityPublisher = PassthroughSubject<String, Never>()

    public init() {}

    // MARK: - EditorState Protocol

    @discardableResult
    public func handleKey(_ key: Character, modifiers: KeyModifiers, textEngine: (any TextEngine)?) -> Bool {
        let result = keyHandler.handleKey(key, in: mode, modifiers: modifiers)

        switch result {
        case .command(let command):
            if let engine = textEngine {
                execute(command: command, on: engine)
            }
            return true

        case .commands(let commands):
            if let engine = textEngine {
                for command in commands {
                    execute(command: command, on: engine)
                }
            }
            return true

        case .pending:
            return true

        case .awaitingCharacter:
            return true

        case .enterSearch(let backward):
            isSearching = true
            searchBackward = backward
            searchQuery = ""
            searchPublisher.send(.beginSearch(backward: backward))
            return true

        case .passThrough:
            return false

        case .consumed:
            return true
        }
    }

    public func setMode(_ mode: EmacsMode) {
        self.mode = mode
    }

    public func reset() {
        mode = .normal
        markPosition = nil
        isSearching = false
        searchQuery = ""
        keyHandler.reset()
    }

    public func executeSearch(textEngine: (any TextEngine)?) {
        searchPublisher.send(.searchExecuted(query: searchQuery, backward: searchBackward))
        isSearching = false
    }

    public func cancelSearch() {
        searchPublisher.send(.searchCancelled)
        isSearching = false
        searchQuery = ""
    }

    public func recordInsertedText(_ text: String) {
        // Emacs doesn't have a separate insert mode tracking like Vim
    }

    // MARK: - Command Execution

    public func execute(command: EmacsCommand, on engine: any TextEngine) {
        defer { lastCommand = command }

        switch command {
        // MARK: - Movement (Character/Line)
        case .forwardChar(let count):
            engine.moveRight(count: count, extendSelection: mode == .markActive)

        case .backwardChar(let count):
            engine.moveLeft(count: count, extendSelection: mode == .markActive)

        case .nextLine(let count):
            engine.moveDown(count: count, extendSelection: mode == .markActive)

        case .previousLine(let count):
            engine.moveUp(count: count, extendSelection: mode == .markActive)

        case .beginningOfLine:
            engine.moveToLineStart(extendSelection: mode == .markActive)

        case .endOfLine:
            engine.moveToLineEnd(extendSelection: mode == .markActive)

        // MARK: - Movement (Word)
        case .forwardWord(let count):
            engine.moveWordForward(count: count, extendSelection: mode == .markActive)

        case .backwardWord(let count):
            engine.moveWordBackward(count: count, extendSelection: mode == .markActive)

        // MARK: - Movement (Sentence/Paragraph)
        case .beginningOfSentence:
            moveSentenceBackward(on: engine)

        case .endOfSentence:
            moveSentenceForward(on: engine)

        case .forwardParagraph(let count):
            engine.moveToParagraphForward(count: count, extendSelection: mode == .markActive)

        case .backwardParagraph(let count):
            engine.moveToParagraphBackward(count: count, extendSelection: mode == .markActive)

        // MARK: - Movement (Buffer)
        case .beginningOfBuffer:
            engine.moveToDocumentStart(extendSelection: mode == .markActive)

        case .endOfBuffer:
            engine.moveToDocumentEnd(extendSelection: mode == .markActive)

        case .gotoLine(let line):
            gotoLine(line, on: engine)

        // MARK: - Deletion
        case .deleteChar(let count):
            deleteForward(count: count, on: engine)

        case .deleteBackwardChar(let count):
            deleteBackward(count: count, on: engine)

        case .killWord(let count):
            killWordForward(count: count, on: engine)

        case .backwardKillWord(let count):
            killWordBackward(count: count, on: engine)

        case .killLine:
            killLine(on: engine)

        case .killWholeLine:
            killWholeLine(on: engine)

        case .killRegion:
            killRegion(on: engine)

        case .killRingSave:
            killRingSave(on: engine)

        // MARK: - Kill Ring / Yank
        case .yank:
            yank(on: engine)

        case .yankPop:
            yankPop(on: engine)

        // MARK: - Mark and Region
        case .setMark:
            setMark(on: engine)

        case .exchangePointAndMark:
            exchangePointAndMark(on: engine)

        case .markWholeBuffer:
            markWholeBuffer(on: engine)

        case .deactivateMark:
            deactivateMark(on: engine)

        // MARK: - Search
        case .isearchForward:
            mode = .isearch
            isSearching = true
            searchBackward = false
            searchQuery = ""
            searchPublisher.send(.beginSearch(backward: false))

        case .isearchBackward:
            mode = .isearchBackward
            isSearching = true
            searchBackward = true
            searchQuery = ""
            searchPublisher.send(.beginSearch(backward: true))

        case .isearchRepeatForward:
            searchPublisher.send(.searchExecuted(query: searchQuery, backward: false))

        case .isearchRepeatBackward:
            searchPublisher.send(.searchExecuted(query: searchQuery, backward: true))

        case .isearchExit:
            mode = .normal
            isSearching = false

        case .isearchAbort:
            mode = .normal
            isSearching = false
            searchPublisher.send(.searchCancelled)

        // MARK: - Undo
        case .undo:
            engine.performUndo()

        case .redo:
            engine.performRedo()

        // MARK: - Transpose
        case .transposeChars:
            transposeChars(on: engine)

        case .transposeWords:
            transposeWords(on: engine)

        case .transposeLines:
            transposeLines(on: engine)

        // MARK: - Case
        case .upcaseWord:
            transformWord(on: engine) { $0.uppercased() }

        case .downcaseWord:
            transformWord(on: engine) { $0.lowercased() }

        case .capitalizeWord:
            transformWord(on: engine) { $0.capitalized }

        // MARK: - Other
        case .keyboardQuit:
            deactivateMark(on: engine)

        case .newline:
            engine.replaceSelectedText(with: "\n")

        case .newlineAndIndent:
            engine.replaceSelectedText(with: "\n")

        case .openLine:
            openLine(on: engine)

        case .scrollUp:
            engine.scrollUp(count: 1, extendSelection: mode == .markActive)

        case .scrollDown:
            engine.scrollDown(count: 1, extendSelection: mode == .markActive)

        case .recenterTopBottom:
            // Recenter would be handled by the view
            break

        case .selfInsert(let char):
            engine.replaceSelectedText(with: String(char))
        }
    }

    // MARK: - Movement Helpers

    private func moveSentenceForward(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length
        var pos = engine.selectedRange.location

        // Find next sentence ending (.!?)
        while pos < length {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            pos += 1
            if char == "." || char == "!" || char == "?" {
                // Skip whitespace after sentence end
                while pos < length {
                    let nextChar = Character(UnicodeScalar(nsText.character(at: pos))!)
                    if !nextChar.isWhitespace { break }
                    pos += 1
                }
                break
            }
        }

        engine.moveCursor(to: pos, extendSelection: mode == .markActive)
    }

    private func moveSentenceBackward(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        var pos = engine.selectedRange.location

        if pos > 0 { pos -= 1 }

        // Skip whitespace backward
        while pos > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if !char.isWhitespace { break }
            pos -= 1
        }

        // Find previous sentence ending
        while pos > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: pos - 1))!)
            if char == "." || char == "!" || char == "?" {
                break
            }
            pos -= 1
        }

        engine.moveCursor(to: pos, extendSelection: mode == .markActive)
    }

    private func gotoLine(_ line: Int, on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length

        var currentLine = 1
        var pos = 0

        while pos < length && currentLine < line {
            let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
            pos = lineRange.location + lineRange.length
            currentLine += 1
        }

        engine.moveCursor(to: pos, extendSelection: false)
    }

    // MARK: - Deletion Helpers

    private func deleteForward(count: Int, on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length
        let pos = engine.selectedRange.location

        let deleteEnd = min(length, pos + count)
        if pos < deleteEnd {
            engine.selectedRange = NSRange(location: pos, length: deleteEnd - pos)
            engine.replaceSelectedText(with: "")
        }
    }

    private func deleteBackward(count: Int, on engine: any TextEngine) {
        let pos = engine.selectedRange.location
        let deleteStart = max(0, pos - count)

        if deleteStart < pos {
            engine.selectedRange = NSRange(location: deleteStart, length: pos - deleteStart)
            engine.replaceSelectedText(with: "")
        }
    }

    private func killWordForward(count: Int, on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length
        let startPos = engine.selectedRange.location
        var pos = startPos

        for _ in 0..<count {
            // Skip whitespace
            while pos < length {
                let char = Character(UnicodeScalar(nsText.character(at: pos))!)
                if !char.isWhitespace { break }
                pos += 1
            }
            // Skip word
            while pos < length {
                let char = Character(UnicodeScalar(nsText.character(at: pos))!)
                if !char.isLetter && !char.isNumber { break }
                pos += 1
            }
        }

        if startPos < pos {
            let killedText = nsText.substring(with: NSRange(location: startPos, length: pos - startPos))
            emacsKillRing.kill(killedText, appending: shouldAppendToKillRing())
            engine.selectedRange = NSRange(location: startPos, length: pos - startPos)
            engine.replaceSelectedText(with: "")
        }
    }

    private func killWordBackward(count: Int, on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let startPos = engine.selectedRange.location
        var pos = startPos

        for _ in 0..<count {
            // Skip whitespace backward
            while pos > 0 {
                let char = Character(UnicodeScalar(nsText.character(at: pos - 1))!)
                if !char.isWhitespace { break }
                pos -= 1
            }
            // Skip word backward
            while pos > 0 {
                let char = Character(UnicodeScalar(nsText.character(at: pos - 1))!)
                if !char.isLetter && !char.isNumber { break }
                pos -= 1
            }
        }

        if pos < startPos {
            let killedText = nsText.substring(with: NSRange(location: pos, length: startPos - pos))
            emacsKillRing.kill(killedText, appending: shouldAppendToKillRing())
            engine.selectedRange = NSRange(location: pos, length: startPos - pos)
            engine.replaceSelectedText(with: "")
        }
    }

    private func killLine(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length
        let pos = engine.selectedRange.location

        let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
        let lineEnd = lineRange.location + lineRange.length

        // If at end of line (just before newline or at end of text), kill the newline
        // Otherwise, kill to end of line
        var killEnd: Int
        if pos == lineEnd - 1 && lineEnd <= length {
            let char = nsText.character(at: pos)
            if char == 0x0A {
                killEnd = pos + 1
            } else {
                killEnd = lineEnd
            }
        } else if pos < lineEnd {
            // Kill to end of line (not including newline)
            killEnd = lineEnd
            if killEnd > 0 && killEnd <= length {
                let char = nsText.character(at: killEnd - 1)
                if char == 0x0A { killEnd -= 1 }
            }
        } else {
            return
        }

        if pos < killEnd {
            let killedText = nsText.substring(with: NSRange(location: pos, length: killEnd - pos))
            emacsKillRing.kill(killedText, appending: shouldAppendToKillRing())
            engine.selectedRange = NSRange(location: pos, length: killEnd - pos)
            engine.replaceSelectedText(with: "")
        }
    }

    private func killWholeLine(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let pos = engine.selectedRange.location
        let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))

        let killedText = nsText.substring(with: lineRange)
        emacsKillRing.kill(killedText, appending: shouldAppendToKillRing())
        engine.selectedRange = lineRange
        engine.replaceSelectedText(with: "")
    }

    private func killRegion(on engine: any TextEngine) {
        guard mode == .markActive, let mark = markPosition else { return }

        let pos = engine.selectedRange.location + engine.selectedRange.length
        let start = min(mark, pos)
        let end = max(mark, pos)

        if start < end {
            let nsText = engine.text as NSString
            let killedText = nsText.substring(with: NSRange(location: start, length: end - start))
            emacsKillRing.kill(killedText, appending: false)
            engine.selectedRange = NSRange(location: start, length: end - start)
            engine.replaceSelectedText(with: "")
        }

        deactivateMark(on: engine)
    }

    private func killRingSave(on engine: any TextEngine) {
        guard mode == .markActive, let mark = markPosition else { return }

        let pos = engine.selectedRange.location + engine.selectedRange.length
        let start = min(mark, pos)
        let end = max(mark, pos)

        if start < end {
            let nsText = engine.text as NSString
            let copiedText = nsText.substring(with: NSRange(location: start, length: end - start))
            emacsKillRing.kill(copiedText, appending: false)
        }

        deactivateMark(on: engine)
    }

    private func shouldAppendToKillRing() -> Bool {
        // Append to kill ring if the last command was also a kill command
        guard let last = lastCommand else { return false }
        switch last {
        case .killWord, .backwardKillWord, .killLine, .killWholeLine:
            return true
        default:
            return false
        }
    }

    // MARK: - Kill Ring / Yank

    private func yank(on engine: any TextEngine) {
        guard let text = emacsKillRing.yank() else { return }
        engine.replaceSelectedText(with: text)
    }

    private func yankPop(on engine: any TextEngine) {
        // Only works immediately after yank
        guard case .yank = lastCommand else { return }
        guard let text = emacsKillRing.yankPop() else { return }

        // Would need to track the last yanked range to replace it
        // For simplicity, just insert
        engine.replaceSelectedText(with: text)
    }

    // MARK: - Mark Helpers

    private func setMark(on engine: any TextEngine) {
        if mode == .markActive {
            // Toggle mark off if already active
            deactivateMark(on: engine)
        } else {
            markPosition = engine.selectedRange.location
            mode = .markActive
        }
    }

    private func exchangePointAndMark(on engine: any TextEngine) {
        guard let mark = markPosition else { return }

        let currentPos = engine.selectedRange.location
        markPosition = currentPos
        engine.selectedRange = NSRange(location: mark, length: 0)

        if mode == .markActive {
            updateSelection(on: engine)
        }
    }

    private func markWholeBuffer(on engine: any TextEngine) {
        engine.selectAll()
        markPosition = 0
        mode = .markActive
    }

    private func deactivateMark(on engine: any TextEngine) {
        markPosition = nil
        mode = .normal
        // Collapse selection to cursor
        let pos = engine.selectedRange.location
        engine.selectedRange = NSRange(location: pos, length: 0)
    }

    private func updateSelection(on engine: any TextEngine) {
        guard let mark = markPosition else { return }
        let point = engine.selectedRange.location + engine.selectedRange.length
        let start = min(mark, point)
        let end = max(mark, point)
        engine.selectedRange = NSRange(location: start, length: end - start)
    }

    // MARK: - Transpose

    private func transposeChars(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let length = nsText.length
        let pos = engine.selectedRange.location

        guard pos > 0 && pos < length else { return }

        let char1 = nsText.substring(with: NSRange(location: pos - 1, length: 1))
        let char2 = nsText.substring(with: NSRange(location: pos, length: 1))

        engine.selectedRange = NSRange(location: pos - 1, length: 2)
        engine.replaceSelectedText(with: char2 + char1)
        engine.selectedRange = NSRange(location: pos + 1, length: 0)
    }

    private func transposeWords(on engine: any TextEngine) {
        // Simplified implementation - would need proper word boundary detection
        // For now, skip
    }

    private func transposeLines(on engine: any TextEngine) {
        let nsText = engine.text as NSString
        let pos = engine.selectedRange.location
        let currentLineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))

        guard currentLineRange.location > 0 else { return }

        let prevLineRange = nsText.lineRange(for: NSRange(location: currentLineRange.location - 1, length: 0))

        let currentLine = nsText.substring(with: currentLineRange)
        let prevLine = nsText.substring(with: prevLineRange)

        let combinedRange = NSRange(location: prevLineRange.location, length: currentLineRange.length + prevLineRange.length)
        engine.selectedRange = combinedRange
        engine.replaceSelectedText(with: currentLine + prevLine)
    }

    // MARK: - Case Transform

    private func transformWord(on engine: any TextEngine, transform: (String) -> String) {
        let nsText = engine.text as NSString
        let length = nsText.length
        let startPos = engine.selectedRange.location

        // Find word boundaries
        var wordStart = startPos
        var wordEnd = startPos

        // Skip to start of word
        while wordStart < length {
            let char = Character(UnicodeScalar(nsText.character(at: wordStart))!)
            if char.isLetter || char.isNumber { break }
            wordStart += 1
        }

        wordEnd = wordStart
        while wordEnd < length {
            let char = Character(UnicodeScalar(nsText.character(at: wordEnd))!)
            if !char.isLetter && !char.isNumber { break }
            wordEnd += 1
        }

        if wordStart < wordEnd {
            let word = nsText.substring(with: NSRange(location: wordStart, length: wordEnd - wordStart))
            let transformed = transform(word)
            engine.selectedRange = NSRange(location: wordStart, length: wordEnd - wordStart)
            engine.replaceSelectedText(with: transformed)
            engine.selectedRange = NSRange(location: wordStart + transformed.count, length: 0)
        }
    }

    // MARK: - Other

    private func openLine(on engine: any TextEngine) {
        let pos = engine.selectedRange.location
        engine.replaceSelectedText(with: "\n")
        engine.selectedRange = NSRange(location: pos, length: 0)
    }
}

// MARK: - Emacs Kill Ring

/// Emacs-style kill ring for storing killed (cut) text.
private class EmacsKillRing {
    private var ring: [String] = []
    private var currentIndex: Int = 0
    private let maxSize = 60

    func kill(_ text: String, appending: Bool) {
        if appending && !ring.isEmpty {
            ring[0] += text
        } else {
            ring.insert(text, at: 0)
            if ring.count > maxSize {
                ring.removeLast()
            }
        }
        currentIndex = 0
    }

    func yank() -> String? {
        guard !ring.isEmpty else { return nil }
        return ring[currentIndex]
    }

    func yankPop() -> String? {
        guard ring.count > 1 else { return nil }
        currentIndex = (currentIndex + 1) % ring.count
        return ring[currentIndex]
    }
}
