import Foundation

/// Protocol for text engines that can execute editing commands.
///
/// Implementations adapt different text view types (NSTextView, UITextView, etc.)
/// to provide a common interface for modal editing operations.
@MainActor
public protocol TextEngine: AnyObject {
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

    // MARK: - Movement

    func moveLeft(count: Int, extendSelection: Bool)
    func moveRight(count: Int, extendSelection: Bool)
    func moveUp(count: Int, extendSelection: Bool)
    func moveDown(count: Int, extendSelection: Bool)
    func moveWordForward(count: Int, extendSelection: Bool)
    func moveWordBackward(count: Int, extendSelection: Bool)
    func moveWordEnd(count: Int, extendSelection: Bool)
    func moveToLineStart(extendSelection: Bool)
    func moveToLineEnd(extendSelection: Bool)
    func moveToLineFirstNonBlank(extendSelection: Bool)
    func moveToDocumentStart(extendSelection: Bool)
    func moveToDocumentEnd(extendSelection: Bool)
    func moveToParagraphForward(count: Int, extendSelection: Bool)
    func moveToParagraphBackward(count: Int, extendSelection: Bool)

    // MARK: - Scroll/Page

    func scrollDown(count: Int, extendSelection: Bool)
    func scrollUp(count: Int, extendSelection: Bool)
    func pageDown(count: Int, extendSelection: Bool)
    func pageUp(count: Int, extendSelection: Bool)

    // MARK: - Find Character

    func findCharacter(_ char: Character, count: Int, extendSelection: Bool)
    func findCharacterBackward(_ char: Character, count: Int, extendSelection: Bool)
    func tillCharacter(_ char: Character, count: Int, extendSelection: Bool)
    func tillCharacterBackward(_ char: Character, count: Int, extendSelection: Bool)

    // MARK: - Search

    func performSearch(query: String, backward: Bool)
    func searchNext(count: Int, extendSelection: Bool)
    func searchPrevious(count: Int, extendSelection: Bool)

    // MARK: - Selection

    func selectCurrentLine()
    func selectAll()
    func selectWord()

    // MARK: - Editing

    func openLineBelow()
    func openLineAbove()
    func moveAfterCursor()
    func moveToEndForAppend()
    func moveToLineStartForInsert()
    func joinLines()
    func toggleCase()
    func indent()
    func dedent()
    func replaceCharacter(with char: Character)

    // MARK: - Kill Ring (Emacs)

    func killToEndOfLine()
    func killWord()
    func killWordBackward()

    // MARK: - Bracket Matching

    func moveToMatchingBracket(extendSelection: Bool)

    // MARK: - Text Objects and Motions

    func rangeForTextObject(_ textObject: TextObject) -> NSRange?
    func rangeForMotion(_ motion: Motion) -> NSRange?
    func selectTextObject(_ textObject: TextObject)
    func selectMotion(_ motion: Motion)
}

// MARK: - Default Implementations

public extension TextEngine {
    func moveWordEnd(count: Int, extendSelection: Bool) {
        moveWordForward(count: count, extendSelection: extendSelection)
    }

    func moveToLineFirstNonBlank(extendSelection: Bool) {
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
                    targetOffset = index - 1
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
                    targetOffset = index + 1
                    break
                }
            }
        }

        if found == count && targetOffset < cursorInLine {
            moveCursor(to: lineRange.location + targetOffset, extendSelection: extendSelection)
        }
    }

    func performSearch(query: String, backward: Bool) {
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
        moveToLineEnd(extendSelection: false)
        replaceSelectedText(with: "\n")
    }

    func openLineAbove() {
        moveToLineStart(extendSelection: false)
        let pos = selectedRange.location
        replaceSelectedText(with: "\n")
        selectedRange = NSRange(location: pos, length: 0)
    }

    func moveAfterCursor() {
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
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineEnd = lineRange.location + lineRange.length

        if lineEnd <= text.count {
            let nextLineStart = lineEnd
            var contentStart = nextLineStart
            let textNS = text as NSString
            while contentStart < textNS.length {
                let char = textNS.character(at: contentStart)
                if char != 0x20 && char != 0x09 {
                    break
                }
                contentStart += 1
            }

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
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        selectedRange = NSRange(location: lineRange.location, length: 0)
        replaceSelectedText(with: "\t")
    }

    func dedent() {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)

        if lineText.hasPrefix("\t") {
            selectedRange = NSRange(location: lineRange.location, length: 1)
            replaceSelectedText(with: "")
        } else if lineText.hasPrefix("    ") {
            selectedRange = NSRange(location: lineRange.location, length: 4)
            replaceSelectedText(with: "")
        } else if lineText.hasPrefix(" ") {
            selectedRange = NSRange(location: lineRange.location, length: 1)
            replaceSelectedText(with: "")
        }
    }

    func replaceCharacter(with char: Character) {
        let range = NSRange(location: selectedRange.location, length: 1)
        if range.location + range.length <= text.count {
            selectedRange = range
            replaceSelectedText(with: String(char))
            selectedRange = NSRange(location: range.location, length: 0)
        }
    }

    func killToEndOfLine() {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        var endPos = lineRange.location + lineRange.length
        if endPos > 0 && endPos <= text.count {
            let charAtEnd = (text as NSString).character(at: endPos - 1)
            if charAtEnd == 0x0A { endPos -= 1 }
        }
        let killRange = NSRange(location: selectedRange.location, length: endPos - selectedRange.location)
        selectedRange = killRange
        replaceSelectedText(with: "")
    }

    func killWord() {
        moveWordForward(count: 1, extendSelection: true)
        replaceSelectedText(with: "")
    }

    func killWordBackward() {
        moveWordBackward(count: 1, extendSelection: true)
        replaceSelectedText(with: "")
    }

    func selectWord() {
        if let range = rangeForTextObject(.innerWord) {
            selectedRange = range
        }
    }

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

    func scrollDown(count: Int, extendSelection: Bool) {
        moveDown(count: count * 20, extendSelection: extendSelection)
    }

    func scrollUp(count: Int, extendSelection: Bool) {
        moveUp(count: count * 20, extendSelection: extendSelection)
    }

    func pageDown(count: Int, extendSelection: Bool) {
        moveDown(count: count * 40, extendSelection: extendSelection)
    }

    func pageUp(count: Int, extendSelection: Bool) {
        moveUp(count: count * 40, extendSelection: extendSelection)
    }

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

    func rangeForTextObject(_ textObject: TextObject) -> NSRange? {
        return textObject.range(in: text, from: selectedRange.location)
    }

    func rangeForMotion(_ motion: Motion) -> NSRange? {
        return motion.range(in: text, from: selectedRange.location)
    }

    func selectTextObject(_ textObject: TextObject) {
        if let range = rangeForTextObject(textObject) {
            selectedRange = range
        }
    }

    func selectMotion(_ motion: Motion) {
        if let range = rangeForMotion(motion) {
            selectedRange = range
        }
    }
}
