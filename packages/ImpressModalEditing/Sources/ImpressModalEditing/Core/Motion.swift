import Foundation

/// Represents motions that can be combined with operators (d, c, y, etc.).
///
/// This is a shared type used across all editor styles. Motions define
/// how to calculate a range of text from a given position.
public enum Motion: Sendable, Equatable, Hashable {
    // MARK: - Character/Cursor Motions
    case left(count: Int = 1)
    case right(count: Int = 1)
    case up(count: Int = 1)
    case down(count: Int = 1)

    // MARK: - Word Motions
    case wordForward(count: Int = 1)
    case wordBackward(count: Int = 1)
    case wordEnd(count: Int = 1)
    case wordForwardWORD(count: Int = 1)
    case wordBackwardWORD(count: Int = 1)
    case wordEndWORD(count: Int = 1)

    // MARK: - Line Motions
    case lineStart
    case lineEnd
    case lineFirstNonBlank

    // MARK: - Document Motions
    case documentStart
    case documentEnd

    // MARK: - Paragraph Motions
    case paragraphForward(count: Int = 1)
    case paragraphBackward(count: Int = 1)

    // MARK: - Find Character Motions
    case findChar(char: Character, count: Int = 1)
    case findCharBackward(char: Character, count: Int = 1)
    case tillChar(char: Character, count: Int = 1)
    case tillCharBackward(char: Character, count: Int = 1)

    // MARK: - Special Motions
    case line
    case matchingBracket

    /// Returns the range this motion would cover from a given position in text.
    public func range(in text: String, from position: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        guard position >= 0 && position <= length else { return nil }

        switch self {
        case .left(let count):
            let newPos = max(0, position - count)
            return NSRange(location: newPos, length: position - newPos)

        case .right(let count):
            let newPos = min(length, position + count)
            return NSRange(location: position, length: newPos - position)

        case .up(let count):
            var pos = position
            for _ in 0..<count {
                let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
                if lineRange.location == 0 { break }
                pos = lineRange.location - 1
            }
            let startLineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
            return NSRange(location: startLineRange.location, length: position - startLineRange.location)

        case .down(let count):
            var pos = position
            for _ in 0..<count {
                let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
                let lineEnd = lineRange.location + lineRange.length
                if lineEnd >= length { break }
                pos = lineEnd
            }
            let endLineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
            return NSRange(location: position, length: endLineRange.location + endLineRange.length - position)

        case .wordForward(let count), .wordForwardWORD(let count):
            let isWORD = self == .wordForwardWORD(count: count)
            var pos = position
            for _ in 0..<count {
                pos = nextWordStart(in: text, from: pos, isWORD: isWORD)
            }
            return NSRange(location: position, length: pos - position)

        case .wordBackward(let count), .wordBackwardWORD(let count):
            let isWORD = self == .wordBackwardWORD(count: count)
            var pos = position
            for _ in 0..<count {
                pos = previousWordStart(in: text, from: pos, isWORD: isWORD)
            }
            return NSRange(location: pos, length: position - pos)

        case .wordEnd(let count), .wordEndWORD(let count):
            let isWORD = self == .wordEndWORD(count: count)
            var pos = position
            for _ in 0..<count {
                pos = nextWordEnd(in: text, from: pos, isWORD: isWORD)
            }
            return NSRange(location: position, length: pos - position + 1)

        case .lineStart:
            let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
            return NSRange(location: lineRange.location, length: position - lineRange.location)

        case .lineEnd:
            let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
            var endPos = lineRange.location + lineRange.length
            if endPos > 0 && endPos <= length {
                let charAtEnd = nsText.character(at: endPos - 1)
                if charAtEnd == 0x0A { endPos -= 1 }
            }
            return NSRange(location: position, length: endPos - position)

        case .lineFirstNonBlank:
            let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
            let lineText = nsText.substring(with: lineRange)
            var offset = 0
            for char in lineText {
                if char == " " || char == "\t" {
                    offset += 1
                } else {
                    break
                }
            }
            let targetPos = lineRange.location + offset
            if targetPos < position {
                return NSRange(location: targetPos, length: position - targetPos)
            } else {
                return NSRange(location: position, length: targetPos - position)
            }

        case .documentStart:
            return NSRange(location: 0, length: position)

        case .documentEnd:
            return NSRange(location: position, length: length - position)

        case .paragraphForward(let count):
            var pos = position
            for _ in 0..<count {
                pos = nextParagraph(in: text, from: pos)
            }
            return NSRange(location: position, length: pos - position)

        case .paragraphBackward(let count):
            var pos = position
            for _ in 0..<count {
                pos = previousParagraph(in: text, from: pos)
            }
            return NSRange(location: pos, length: position - pos)

        case .findChar(let char, let count):
            if let targetPos = findCharForward(char, in: text, from: position, count: count) {
                return NSRange(location: position, length: targetPos - position + 1)
            }
            return nil

        case .findCharBackward(let char, let count):
            if let targetPos = findCharBackward(char, in: text, from: position, count: count) {
                return NSRange(location: targetPos, length: position - targetPos)
            }
            return nil

        case .tillChar(let char, let count):
            if let targetPos = findCharForward(char, in: text, from: position, count: count) {
                return NSRange(location: position, length: targetPos - position)
            }
            return nil

        case .tillCharBackward(let char, let count):
            if let targetPos = findCharBackward(char, in: text, from: position, count: count) {
                return NSRange(location: targetPos + 1, length: position - targetPos - 1)
            }
            return nil

        case .line:
            let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
            return lineRange

        case .matchingBracket:
            if let targetPos = findMatchingBracket(in: text, from: position) {
                if targetPos > position {
                    return NSRange(location: position, length: targetPos - position + 1)
                } else {
                    return NSRange(location: targetPos, length: position - targetPos + 1)
                }
            }
            return nil
        }
    }

    // MARK: - Private Helpers

    private func nextWordStart(in text: String, from position: Int, isWORD: Bool) -> Int {
        let nsText = text as NSString
        let length = nsText.length
        guard position < length else { return length }

        var pos = position
        while pos < length {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if isWORD {
                if char.isWhitespace { break }
            } else {
                if !char.isLetter && !char.isNumber && char != "_" { break }
            }
            pos += 1
        }
        while pos < length {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if !char.isWhitespace { break }
            pos += 1
        }
        return pos
    }

    private func previousWordStart(in text: String, from position: Int, isWORD: Bool) -> Int {
        let nsText = text as NSString
        guard position > 0 else { return 0 }

        var pos = position - 1
        while pos > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if !char.isWhitespace { break }
            pos -= 1
        }
        while pos > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: pos - 1))!)
            if isWORD {
                if char.isWhitespace { break }
            } else {
                if !char.isLetter && !char.isNumber && char != "_" { break }
            }
            pos -= 1
        }
        return pos
    }

    private func nextWordEnd(in text: String, from position: Int, isWORD: Bool) -> Int {
        let nsText = text as NSString
        let length = nsText.length
        guard position < length - 1 else { return max(0, length - 1) }

        var pos = position + 1
        while pos < length {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if !char.isWhitespace { break }
            pos += 1
        }
        while pos < length - 1 {
            let nextChar = Character(UnicodeScalar(nsText.character(at: pos + 1))!)
            if isWORD {
                if nextChar.isWhitespace { break }
            } else {
                if !nextChar.isLetter && !nextChar.isNumber && nextChar != "_" { break }
            }
            pos += 1
        }
        return pos
    }

    private func nextParagraph(in text: String, from position: Int) -> Int {
        let nsText = text as NSString
        let length = nsText.length
        guard position < length else { return length }

        var pos = position
        var foundNonBlank = false

        while pos < length {
            let lineRange = nsText.lineRange(for: NSRange(location: pos, length: 0))
            let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if lineText.isEmpty {
                if foundNonBlank {
                    return lineRange.location
                }
            } else {
                foundNonBlank = true
            }

            pos = lineRange.location + lineRange.length
        }
        return length
    }

    private func previousParagraph(in text: String, from position: Int) -> Int {
        let nsText = text as NSString
        guard position > 0 else { return 0 }

        var pos = position
        var foundNonBlank = false

        while pos > 0 {
            let lineRange = nsText.lineRange(for: NSRange(location: pos - 1, length: 0))
            let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if lineText.isEmpty {
                if foundNonBlank {
                    return lineRange.location
                }
            } else {
                foundNonBlank = true
            }

            if lineRange.location == 0 { break }
            pos = lineRange.location
        }
        return 0
    }

    private func findCharForward(_ char: Character, in text: String, from position: Int, count: Int) -> Int? {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
        let lineEnd = lineRange.location + lineRange.length

        var found = 0
        for pos in (position + 1)..<lineEnd {
            let c = Character(UnicodeScalar(nsText.character(at: pos))!)
            if c == char {
                found += 1
                if found == count {
                    return pos
                }
            }
        }
        return nil
    }

    private func findCharBackward(_ char: Character, in text: String, from position: Int, count: Int) -> Int? {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))

        var found = 0
        for pos in stride(from: position - 1, through: lineRange.location, by: -1) {
            let c = Character(UnicodeScalar(nsText.character(at: pos))!)
            if c == char {
                found += 1
                if found == count {
                    return pos
                }
            }
        }
        return nil
    }

    private func findMatchingBracket(in text: String, from position: Int) -> Int? {
        let nsText = text as NSString
        let length = nsText.length
        guard position >= 0 && position < length else { return nil }

        let char = Character(UnicodeScalar(nsText.character(at: position))!)
        let pairs: [(Character, Character)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">")
        ]

        for (open, close) in pairs {
            if char == open {
                var depth = 1
                var pos = position + 1
                while pos < length && depth > 0 {
                    let c = Character(UnicodeScalar(nsText.character(at: pos))!)
                    if c == open { depth += 1 }
                    else if c == close { depth -= 1 }
                    if depth == 0 { return pos }
                    pos += 1
                }
            } else if char == close {
                var depth = 1
                var pos = position - 1
                while pos >= 0 && depth > 0 {
                    let c = Character(UnicodeScalar(nsText.character(at: pos))!)
                    if c == close { depth += 1 }
                    else if c == open { depth -= 1 }
                    if depth == 0 { return pos }
                    pos -= 1
                }
            }
        }
        return nil
    }
}
