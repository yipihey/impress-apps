import Foundation

/// Protocol for text engines that can execute Helix commands.
/// Implementations adapt different text view types (NSTextView, UITextView, etc.)
@MainActor
public protocol HelixTextEngine: AnyObject {
    /// The full text content.
    var text: String { get set }

    /// The current selection range.
    var selectedRange: NSRange { get set }

    /// Execute an undo operation.
    func performUndo()

    /// Execute a redo operation.
    func performRedo()

    /// Replace the selected range with new text.
    func replaceSelectedText(with text: String)

    /// Get the text in the given range.
    func text(in range: NSRange) -> String?

    /// Move the cursor to a new position.
    func moveCursor(to position: Int, extendSelection: Bool)

    /// Select the line at the current cursor position.
    func selectCurrentLine()

    /// Select all text.
    func selectAll()

    /// Move cursor left by the given count.
    func moveLeft(count: Int, extendSelection: Bool)

    /// Move cursor right by the given count.
    func moveRight(count: Int, extendSelection: Bool)

    /// Move cursor up by the given count.
    func moveUp(count: Int, extendSelection: Bool)

    /// Move cursor down by the given count.
    func moveDown(count: Int, extendSelection: Bool)

    /// Move cursor to the next word.
    func moveWordForward(count: Int, extendSelection: Bool)

    /// Move cursor to the previous word.
    func moveWordBackward(count: Int, extendSelection: Bool)

    /// Move cursor to end of word.
    func moveWordEnd(count: Int, extendSelection: Bool)

    /// Move cursor to the start of the current line.
    func moveToLineStart(extendSelection: Bool)

    /// Move cursor to the end of the current line.
    func moveToLineEnd(extendSelection: Bool)

    /// Move cursor to first non-blank character on line.
    func moveToLineFirstNonBlank(extendSelection: Bool)

    /// Move cursor to the start of the document.
    func moveToDocumentStart(extendSelection: Bool)

    /// Move cursor to the end of the document.
    func moveToDocumentEnd(extendSelection: Bool)

    /// Find character on current line (forward).
    func findCharacter(_ char: Character, count: Int, extendSelection: Bool)

    /// Find character on current line (backward).
    func findCharacterBackward(_ char: Character, count: Int, extendSelection: Bool)

    /// Move to character on current line (forward, stops before).
    func tillCharacter(_ char: Character, count: Int, extendSelection: Bool)

    /// Move to character on current line (backward, stops after).
    func tillCharacterBackward(_ char: Character, count: Int, extendSelection: Bool)

    /// Perform a text search.
    func performSearch(query: String, backward: Bool)

    /// Move to next search result.
    func searchNext(count: Int, extendSelection: Bool)

    /// Move to previous search result.
    func searchPrevious(count: Int, extendSelection: Bool)

    /// Open a new line below the current line.
    func openLineBelow()

    /// Open a new line above the current line.
    func openLineAbove()

    /// Move cursor after current character (for append).
    func moveAfterCursor()

    /// Move cursor to end of line (for append at line end).
    func moveToEndForAppend()

    /// Move cursor to first non-blank and position for insert.
    func moveToLineStartForInsert()

    /// Join current line with the next line.
    func joinLines()

    /// Toggle case of character under cursor or selection.
    func toggleCase()

    /// Indent current line or selection.
    func indent()

    /// Dedent current line or selection.
    func dedent()

    /// Replace character under cursor.
    func replaceCharacter(with char: Character)

    // MARK: - Paragraph Motions

    /// Move to the start of the next paragraph.
    func moveToParagraphForward(count: Int, extendSelection: Bool)

    /// Move to the start of the previous paragraph.
    func moveToParagraphBackward(count: Int, extendSelection: Bool)

    // MARK: - Scroll/Page Motions

    /// Scroll down by half page.
    func scrollDown(count: Int, extendSelection: Bool)

    /// Scroll up by half page.
    func scrollUp(count: Int, extendSelection: Bool)

    /// Page down.
    func pageDown(count: Int, extendSelection: Bool)

    /// Page up.
    func pageUp(count: Int, extendSelection: Bool)

    // MARK: - Bracket Matching

    /// Move to matching bracket.
    func moveToMatchingBracket(extendSelection: Bool)

    // MARK: - Text Objects and Motions

    /// Get the range for a text object at the current position.
    func rangeForTextObject(_ textObject: HelixTextObject) -> NSRange?

    /// Get the range for a motion from the current position.
    func rangeForMotion(_ motion: HelixMotion) -> NSRange?

    /// Select text covered by a text object.
    func selectTextObject(_ textObject: HelixTextObject)

    /// Select text covered by a motion.
    func selectMotion(_ motion: HelixMotion)
}

// MARK: - Default Implementations

public extension HelixTextEngine {
    /// Execute a Helix command on this text engine.
    func execute(_ command: HelixCommand, registers: HelixRegisterManager, extendSelection: Bool = false) {
        switch command {
        case .enterInsertMode, .enterNormalMode, .enterSelectMode, .enterSearchMode:
            // Mode changes are handled by HelixState
            break

        case .moveLeft(let count):
            moveLeft(count: count, extendSelection: extendSelection)

        case .moveRight(let count):
            moveRight(count: count, extendSelection: extendSelection)

        case .moveUp(let count):
            moveUp(count: count, extendSelection: extendSelection)

        case .moveDown(let count):
            moveDown(count: count, extendSelection: extendSelection)

        case .wordForward(let count):
            moveWordForward(count: count, extendSelection: extendSelection)

        case .wordBackward(let count):
            moveWordBackward(count: count, extendSelection: extendSelection)

        case .wordEnd(let count):
            moveWordEnd(count: count, extendSelection: extendSelection)

        case .lineStart:
            moveToLineStart(extendSelection: extendSelection)

        case .lineEnd:
            moveToLineEnd(extendSelection: extendSelection)

        case .lineFirstNonBlank:
            moveToLineFirstNonBlank(extendSelection: extendSelection)

        case .documentStart:
            moveToDocumentStart(extendSelection: extendSelection)

        case .documentEnd:
            moveToDocumentEnd(extendSelection: extendSelection)

        case .findCharacter(let char, let count):
            findCharacter(char, count: count, extendSelection: extendSelection)

        case .findCharacterBackward(let char, let count):
            findCharacterBackward(char, count: count, extendSelection: extendSelection)

        case .tillCharacter(let char, let count):
            tillCharacter(char, count: count, extendSelection: extendSelection)

        case .tillCharacterBackward(let char, let count):
            tillCharacterBackward(char, count: count, extendSelection: extendSelection)

        case .repeatFind, .repeatFindReverse:
            // Handled by HelixState
            break

        case .searchNext(let count):
            searchNext(count: count, extendSelection: extendSelection)

        case .searchPrevious(let count):
            searchPrevious(count: count, extendSelection: extendSelection)

        case .selectLine:
            selectCurrentLine()

        case .selectAll:
            selectAll()

        case .delete:
            if selectedRange.length > 0 {
                replaceSelectedText(with: "")
            } else {
                // Delete character under cursor
                let range = NSRange(location: selectedRange.location, length: 1)
                if range.location + range.length <= text.count {
                    selectedRange = range
                    replaceSelectedText(with: "")
                }
            }

        case .yank:
            if let text = text(in: selectedRange), !text.isEmpty {
                registers.yank(text)
            }

        case .pasteAfter:
            let register = registers.paste()
            if !register.content.isEmpty {
                let insertPosition = selectedRange.location + selectedRange.length
                selectedRange = NSRange(location: insertPosition, length: 0)
                replaceSelectedText(with: register.content)
            }

        case .pasteBefore:
            let register = registers.paste()
            if !register.content.isEmpty {
                let insertPosition = selectedRange.location
                selectedRange = NSRange(location: insertPosition, length: 0)
                replaceSelectedText(with: register.content)
            }

        case .change:
            if selectedRange.length > 0 {
                replaceSelectedText(with: "")
            }
            // Mode change to insert is handled by HelixState

        case .openLineBelow:
            openLineBelow()

        case .openLineAbove:
            openLineAbove()

        case .appendAfterCursor:
            moveAfterCursor()

        case .appendAtLineEnd:
            moveToEndForAppend()

        case .insertAtLineStart:
            moveToLineStartForInsert()

        case .joinLines:
            joinLines()

        case .toggleCase:
            toggleCase()

        case .indent:
            indent()

        case .dedent:
            dedent()

        case .replaceCharacter(let char):
            replaceCharacter(with: char)

        case .substitute:
            // Delete character and enter insert mode - handled by HelixState
            if selectedRange.length == 0 {
                let range = NSRange(location: selectedRange.location, length: 1)
                if range.location + range.length <= text.count {
                    selectedRange = range
                    replaceSelectedText(with: "")
                }
            } else {
                replaceSelectedText(with: "")
            }

        case .repeatLastChange:
            // Handled by HelixState
            break

        case .undo:
            performUndo()

        case .redo:
            performRedo()

        // New movement commands
        case .paragraphForward(let count):
            moveToParagraphForward(count: count, extendSelection: extendSelection)

        case .paragraphBackward(let count):
            moveToParagraphBackward(count: count, extendSelection: extendSelection)

        case .matchingBracket:
            moveToMatchingBracket(extendSelection: extendSelection)

        case .scrollDown(let count):
            scrollDown(count: count, extendSelection: extendSelection)

        case .scrollUp(let count):
            scrollUp(count: count, extendSelection: extendSelection)

        case .pageDown(let count):
            pageDown(count: count, extendSelection: extendSelection)

        case .pageUp(let count):
            pageUp(count: count, extendSelection: extendSelection)

        // Operator + Motion commands
        case .deleteMotion(let motion):
            if let range = rangeForMotion(motion), range.length > 0 {
                let deletedText = text(in: range) ?? ""
                registers.yank(deletedText, linewise: motion == .line)
                selectedRange = range
                replaceSelectedText(with: "")
            }

        case .changeMotion(let motion):
            if let range = rangeForMotion(motion), range.length > 0 {
                let deletedText = text(in: range) ?? ""
                registers.yank(deletedText, linewise: motion == .line)
                selectedRange = range
                replaceSelectedText(with: "")
            }
            // Mode change to insert handled by HelixState

        case .yankMotion(let motion):
            if let range = rangeForMotion(motion), range.length > 0 {
                if let yankedText = text(in: range) {
                    registers.yank(yankedText, linewise: motion == .line)
                }
            }

        case .indentMotion(let motion):
            if let range = rangeForMotion(motion) {
                // Indent all lines in the range
                indentRange(range)
            }

        case .dedentMotion(let motion):
            if let range = rangeForMotion(motion) {
                // Dedent all lines in the range
                dedentRange(range)
            }

        // Operator + Text Object commands
        case .deleteTextObject(let textObject):
            if let range = rangeForTextObject(textObject), range.length > 0 {
                let deletedText = text(in: range) ?? ""
                registers.yank(deletedText)
                selectedRange = range
                replaceSelectedText(with: "")
            }

        case .changeTextObject(let textObject):
            if let range = rangeForTextObject(textObject), range.length > 0 {
                let deletedText = text(in: range) ?? ""
                registers.yank(deletedText)
                selectedRange = range
                replaceSelectedText(with: "")
            }
            // Mode change to insert handled by HelixState

        case .yankTextObject(let textObject):
            if let range = rangeForTextObject(textObject), range.length > 0 {
                if let yankedText = text(in: range) {
                    registers.yank(yankedText)
                }
            }

        case .indentTextObject(let textObject):
            if let range = rangeForTextObject(textObject) {
                indentRange(range)
            }

        case .dedentTextObject(let textObject):
            if let range = rangeForTextObject(textObject) {
                dedentRange(range)
            }
        }
    }

    // MARK: - Default Implementations for New Methods

    func moveWordEnd(count: Int, extendSelection: Bool) {
        // Default: move word forward (subclasses should override for proper word-end behavior)
        moveWordForward(count: count, extendSelection: extendSelection)
    }

    func moveToLineFirstNonBlank(extendSelection: Bool) {
        // Default: move to line start, then skip whitespace
        moveToLineStart(extendSelection: extendSelection)
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)
        var offset = 0
        for char in lineText {
            if char == " " || char == "\t" {
                offset += 1
            } else {
                break
            }
        }
        if offset > 0 {
            moveCursor(to: lineRange.location + offset, extendSelection: extendSelection)
        }
    }

    func findCharacter(_ char: Character, count: Int, extendSelection: Bool) {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)
        let cursorInLine = selectedRange.location - lineRange.location

        var found = 0
        var targetOffset = cursorInLine
        for (index, c) in lineText.enumerated() where index > cursorInLine {
            if c == char {
                found += 1
                if found == count {
                    targetOffset = index
                    break
                }
            }
        }

        if found == count {
            moveCursor(to: lineRange.location + targetOffset, extendSelection: extendSelection)
        }
    }

    func findCharacterBackward(_ char: Character, count: Int, extendSelection: Bool) {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)
        let cursorInLine = selectedRange.location - lineRange.location

        var found = 0
        var targetOffset = cursorInLine
        for index in stride(from: cursorInLine - 1, through: 0, by: -1) {
            let charIndex = lineText.index(lineText.startIndex, offsetBy: index)
            if lineText[charIndex] == char {
                found += 1
                if found == count {
                    targetOffset = index
                    break
                }
            }
        }

        if found == count {
            moveCursor(to: lineRange.location + targetOffset, extendSelection: extendSelection)
        }
    }

    func tillCharacter(_ char: Character, count: Int, extendSelection: Bool) {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)
        let cursorInLine = selectedRange.location - lineRange.location

        var found = 0
        var targetOffset = cursorInLine
        for (index, c) in lineText.enumerated() where index > cursorInLine {
            if c == char {
                found += 1
                if found == count {
                    targetOffset = index - 1  // Stop before the character
                    break
                }
            }
        }

        if found == count && targetOffset > cursorInLine {
            moveCursor(to: lineRange.location + targetOffset, extendSelection: extendSelection)
        }
    }

    func tillCharacterBackward(_ char: Character, count: Int, extendSelection: Bool) {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)
        let cursorInLine = selectedRange.location - lineRange.location

        var found = 0
        var targetOffset = cursorInLine
        for index in stride(from: cursorInLine - 1, through: 0, by: -1) {
            let charIndex = lineText.index(lineText.startIndex, offsetBy: index)
            if lineText[charIndex] == char {
                found += 1
                if found == count {
                    targetOffset = index + 1  // Stop after the character
                    break
                }
            }
        }

        if found == count && targetOffset < cursorInLine {
            moveCursor(to: lineRange.location + targetOffset, extendSelection: extendSelection)
        }
    }

    func performSearch(query: String, backward: Bool) {
        // Default implementation - find and select the next occurrence
        guard !query.isEmpty else { return }

        let searchRange: NSRange
        if backward {
            searchRange = NSRange(location: 0, length: selectedRange.location)
        } else {
            let start = selectedRange.location + selectedRange.length
            searchRange = NSRange(location: start, length: text.count - start)
        }

        let range = (text as NSString).range(of: query, options: backward ? .backwards : [], range: searchRange)
        if range.location != NSNotFound {
            selectedRange = range
        }
    }

    func searchNext(count: Int, extendSelection: Bool) {
        // Subclasses should implement proper search state tracking
    }

    func searchPrevious(count: Int, extendSelection: Bool) {
        // Subclasses should implement proper search state tracking
    }

    func openLineBelow() {
        // Move to end of line, insert newline
        moveToLineEnd(extendSelection: false)
        replaceSelectedText(with: "\n")
    }

    func openLineAbove() {
        // Move to start of line, insert newline, move up
        moveToLineStart(extendSelection: false)
        let pos = selectedRange.location
        replaceSelectedText(with: "\n")
        selectedRange = NSRange(location: pos, length: 0)
    }

    func moveAfterCursor() {
        // Move cursor one position to the right (for append)
        if selectedRange.location < text.count {
            selectedRange = NSRange(location: selectedRange.location + 1, length: 0)
        }
    }

    func moveToEndForAppend() {
        moveToLineEnd(extendSelection: false)
    }

    func moveToLineStartForInsert() {
        moveToLineFirstNonBlank(extendSelection: false)
    }

    func joinLines() {
        // Join current line with next
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineEnd = lineRange.location + lineRange.length

        // Find the newline at end of current line
        if lineEnd <= text.count {
            // Find where next line's content starts (skip whitespace)
            let nextLineStart = lineEnd
            var contentStart = nextLineStart
            let textNS = text as NSString
            while contentStart < textNS.length {
                let char = textNS.character(at: contentStart)
                if char != 0x20 && char != 0x09 { // space and tab
                    break
                }
                contentStart += 1
            }

            // Replace newline and leading whitespace with a single space
            let rangeToReplace = NSRange(location: lineEnd - 1, length: contentStart - lineEnd + 1)
            selectedRange = rangeToReplace
            replaceSelectedText(with: " ")
        }
    }

    func toggleCase() {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: selectedRange.location, length: 1)
        guard let selectedText = text(in: range) else { return }

        var toggled = ""
        for char in selectedText {
            if char.isUppercase {
                toggled += char.lowercased()
            } else if char.isLowercase {
                toggled += char.uppercased()
            } else {
                toggled += String(char)
            }
        }

        selectedRange = range
        replaceSelectedText(with: toggled)
    }

    func indent() {
        // Insert tab at beginning of line(s)
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        selectedRange = NSRange(location: lineRange.location, length: 0)
        replaceSelectedText(with: "\t")
    }

    func dedent() {
        // Remove leading whitespace from line(s)
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)

        if lineText.hasPrefix("\t") {
            selectedRange = NSRange(location: lineRange.location, length: 1)
            replaceSelectedText(with: "")
        } else if lineText.hasPrefix("    ") {
            selectedRange = NSRange(location: lineRange.location, length: 4)
            replaceSelectedText(with: "")
        } else if lineText.hasPrefix(" ") {
            // Remove single leading space
            selectedRange = NSRange(location: lineRange.location, length: 1)
            replaceSelectedText(with: "")
        }
    }

    func replaceCharacter(with char: Character) {
        let range = NSRange(location: selectedRange.location, length: 1)
        if range.location + range.length <= text.count {
            selectedRange = range
            replaceSelectedText(with: String(char))
            // Move cursor back to the replaced position
            selectedRange = NSRange(location: range.location, length: 0)
        }
    }

    // MARK: - Paragraph Motions

    func moveToParagraphForward(count: Int, extendSelection: Bool) {
        let nsText = text as NSString
        let length = nsText.length
        guard selectedRange.location < length else { return }

        var pos = selectedRange.location
        for _ in 0..<count {
            var foundNonBlank = false
            while pos < length {
                let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
                let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

                if lineText.isEmpty {
                    if foundNonBlank {
                        pos = lineRange.location
                        break
                    }
                } else {
                    foundNonBlank = true
                }

                pos = lineRange.location + lineRange.length
                if pos >= length {
                    pos = length
                    break
                }
            }
        }
        moveCursor(to: pos, extendSelection: extendSelection)
    }

    func moveToParagraphBackward(count: Int, extendSelection: Bool) {
        let nsText = text as NSString
        guard selectedRange.location > 0 else { return }

        var pos = selectedRange.location
        for _ in 0..<count {
            var foundNonBlank = false
            while pos > 0 {
                let lineRange = nsText.lineRange(for: NSRange(location: pos - 1, length: 0))
                let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

                if lineText.isEmpty {
                    if foundNonBlank {
                        pos = lineRange.location
                        break
                    }
                } else {
                    foundNonBlank = true
                }

                if lineRange.location == 0 {
                    pos = 0
                    break
                }
                pos = lineRange.location
            }
        }
        moveCursor(to: pos, extendSelection: extendSelection)
    }

    // MARK: - Scroll/Page Motions

    func scrollDown(count: Int, extendSelection: Bool) {
        // Default: move down ~20 lines (half page approximation)
        moveDown(count: count * 20, extendSelection: extendSelection)
    }

    func scrollUp(count: Int, extendSelection: Bool) {
        // Default: move up ~20 lines (half page approximation)
        moveUp(count: count * 20, extendSelection: extendSelection)
    }

    func pageDown(count: Int, extendSelection: Bool) {
        // Default: move down ~40 lines (full page approximation)
        moveDown(count: count * 40, extendSelection: extendSelection)
    }

    func pageUp(count: Int, extendSelection: Bool) {
        // Default: move up ~40 lines (full page approximation)
        moveUp(count: count * 40, extendSelection: extendSelection)
    }

    // MARK: - Bracket Matching

    func moveToMatchingBracket(extendSelection: Bool) {
        let nsText = text as NSString
        let length = nsText.length
        guard selectedRange.location < length else { return }

        let pos = selectedRange.location
        let char = Character(UnicodeScalar(nsText.character(at: pos))!)

        let pairs: [(Character, Character)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")
        ]

        for (open, close) in pairs {
            if char == open {
                // Search forward for matching close
                var depth = 1
                var searchPos = pos + 1
                while searchPos < length && depth > 0 {
                    let c = Character(UnicodeScalar(nsText.character(at: searchPos))!)
                    if c == open { depth += 1 }
                    else if c == close { depth -= 1 }
                    if depth == 0 {
                        moveCursor(to: searchPos, extendSelection: extendSelection)
                        return
                    }
                    searchPos += 1
                }
                return
            } else if char == close {
                // Search backward for matching open
                var depth = 1
                var searchPos = pos - 1
                while searchPos >= 0 && depth > 0 {
                    let c = Character(UnicodeScalar(nsText.character(at: searchPos))!)
                    if c == close { depth += 1 }
                    else if c == open { depth -= 1 }
                    if depth == 0 {
                        moveCursor(to: searchPos, extendSelection: extendSelection)
                        return
                    }
                    searchPos -= 1
                }
                return
            }
        }
    }

    // MARK: - Text Objects and Motions

    func rangeForTextObject(_ textObject: HelixTextObject) -> NSRange? {
        return textObject.range(in: text, from: selectedRange.location)
    }

    func rangeForMotion(_ motion: HelixMotion) -> NSRange? {
        return motion.range(in: text, from: selectedRange.location)
    }

    func selectTextObject(_ textObject: HelixTextObject) {
        if let range = rangeForTextObject(textObject) {
            selectedRange = range
        }
    }

    func selectMotion(_ motion: HelixMotion) {
        if let range = rangeForMotion(motion) {
            selectedRange = range
        }
    }

    // MARK: - Range Operations

    func indentRange(_ range: NSRange) {
        let nsText = text as NSString
        let startLine = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let endLine = nsText.lineRange(for: NSRange(location: range.location + max(0, range.length - 1), length: 0))

        var currentPos = startLine.location
        var offset = 0

        while currentPos <= endLine.location {
            let lineRange = nsText.lineRange(for: NSRange(location: currentPos + offset, length: 0))
            // Insert tab at the beginning of this line
            selectedRange = NSRange(location: lineRange.location, length: 0)
            replaceSelectedText(with: "\t")
            offset += 1

            let nextLineStart = lineRange.location + lineRange.length + 1
            if nextLineStart > endLine.location + offset {
                break
            }
            currentPos = nextLineStart - offset
        }
    }

    func dedentRange(_ range: NSRange) {
        let nsText = text as NSString
        let startLine = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let endLine = nsText.lineRange(for: NSRange(location: range.location + max(0, range.length - 1), length: 0))

        var currentPos = startLine.location
        var offset = 0

        while currentPos <= endLine.location {
            let adjustedPos = currentPos + offset
            if adjustedPos >= (text as NSString).length { break }

            let lineRange = (text as NSString).lineRange(for: NSRange(location: adjustedPos, length: 0))
            let lineText = (text as NSString).substring(with: lineRange)

            if lineText.hasPrefix("\t") {
                selectedRange = NSRange(location: lineRange.location, length: 1)
                replaceSelectedText(with: "")
                offset -= 1
            } else if lineText.hasPrefix("    ") {
                selectedRange = NSRange(location: lineRange.location, length: 4)
                replaceSelectedText(with: "")
                offset -= 4
            } else if lineText.hasPrefix(" ") {
                selectedRange = NSRange(location: lineRange.location, length: 1)
                replaceSelectedText(with: "")
                offset -= 1
            }

            let nextLineStart = lineRange.location + lineRange.length
            if nextLineStart - offset > endLine.location {
                break
            }
            currentPos = nextLineStart - offset
        }
    }
}
