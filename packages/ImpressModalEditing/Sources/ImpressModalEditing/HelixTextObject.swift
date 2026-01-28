import Foundation

/// Text objects that can be selected with operators (d, c, y) using modifiers (i, a).
public enum HelixTextObject: Sendable, Equatable, Hashable {
    // MARK: - Word Objects
    /// Inner word - just the word characters.
    case innerWord
    /// Around word - word plus surrounding whitespace.
    case aroundWord
    /// Inner WORD - non-whitespace characters.
    case innerWORD
    /// Around WORD - WORD plus surrounding whitespace.
    case aroundWORD

    // MARK: - Quote Objects
    /// Inner double quote - content between quotes.
    case innerDoubleQuote
    /// Around double quote - content including quotes.
    case aroundDoubleQuote
    /// Inner single quote - content between quotes.
    case innerSingleQuote
    /// Around single quote - content including quotes.
    case aroundSingleQuote
    /// Inner backtick - content between backticks.
    case innerBacktick
    /// Around backtick - content including backticks.
    case aroundBacktick

    // MARK: - Bracket Objects
    /// Inner parentheses - content between ().
    case innerParen
    /// Around parentheses - content including ().
    case aroundParen
    /// Inner brackets - content between [].
    case innerBracket
    /// Around brackets - content including [].
    case aroundBracket
    /// Inner braces - content between {}.
    case innerBrace
    /// Around braces - content including {}.
    case aroundBrace
    /// Inner angle brackets - content between <>.
    case innerAngle
    /// Around angle brackets - content including <>.
    case aroundAngle

    // MARK: - Block Objects
    /// Inner paragraph - lines of current paragraph.
    case innerParagraph
    /// Around paragraph - paragraph including surrounding blank lines.
    case aroundParagraph

    /// Returns the range for this text object in the given text from the cursor position.
    /// - Parameters:
    ///   - text: The full text content
    ///   - position: Current cursor position
    /// - Returns: The range of the text object, or nil if not found
    public func range(in text: String, from position: Int) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        guard position >= 0 && position < length else { return nil }

        switch self {
        case .innerWord:
            return wordRange(in: text, from: position, isWORD: false, inner: true)
        case .aroundWord:
            return wordRange(in: text, from: position, isWORD: false, inner: false)
        case .innerWORD:
            return wordRange(in: text, from: position, isWORD: true, inner: true)
        case .aroundWORD:
            return wordRange(in: text, from: position, isWORD: true, inner: false)

        case .innerDoubleQuote:
            return quotedRange(in: text, from: position, quote: "\"", inner: true)
        case .aroundDoubleQuote:
            return quotedRange(in: text, from: position, quote: "\"", inner: false)
        case .innerSingleQuote:
            return quotedRange(in: text, from: position, quote: "'", inner: true)
        case .aroundSingleQuote:
            return quotedRange(in: text, from: position, quote: "'", inner: false)
        case .innerBacktick:
            return quotedRange(in: text, from: position, quote: "`", inner: true)
        case .aroundBacktick:
            return quotedRange(in: text, from: position, quote: "`", inner: false)

        case .innerParen:
            return bracketRange(in: text, from: position, open: "(", close: ")", inner: true)
        case .aroundParen:
            return bracketRange(in: text, from: position, open: "(", close: ")", inner: false)
        case .innerBracket:
            return bracketRange(in: text, from: position, open: "[", close: "]", inner: true)
        case .aroundBracket:
            return bracketRange(in: text, from: position, open: "[", close: "]", inner: false)
        case .innerBrace:
            return bracketRange(in: text, from: position, open: "{", close: "}", inner: true)
        case .aroundBrace:
            return bracketRange(in: text, from: position, open: "{", close: "}", inner: false)
        case .innerAngle:
            return bracketRange(in: text, from: position, open: "<", close: ">", inner: true)
        case .aroundAngle:
            return bracketRange(in: text, from: position, open: "<", close: ">", inner: false)

        case .innerParagraph:
            return paragraphRange(in: text, from: position, inner: true)
        case .aroundParagraph:
            return paragraphRange(in: text, from: position, inner: false)
        }
    }

    // MARK: - Private Helpers

    private func wordRange(in text: String, from position: Int, isWORD: Bool, inner: Bool) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        guard position >= 0 && position < length else { return nil }

        let isWordChar: (Character) -> Bool = { char in
            if isWORD {
                return !char.isWhitespace
            } else {
                return char.isLetter || char.isNumber || char == "_"
            }
        }

        let currentChar = Character(UnicodeScalar(nsText.character(at: position))!)

        // If we're on whitespace, select the whitespace
        if currentChar.isWhitespace {
            var start = position
            var end = position

            while start > 0 {
                let char = Character(UnicodeScalar(nsText.character(at: start - 1))!)
                if !char.isWhitespace { break }
                start -= 1
            }

            while end < length - 1 {
                let char = Character(UnicodeScalar(nsText.character(at: end + 1))!)
                if !char.isWhitespace { break }
                end += 1
            }

            return NSRange(location: start, length: end - start + 1)
        }

        // Find word boundaries
        var start = position
        var end = position

        while start > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: start - 1))!)
            if !isWordChar(char) { break }
            start -= 1
        }

        while end < length - 1 {
            let char = Character(UnicodeScalar(nsText.character(at: end + 1))!)
            if !isWordChar(char) { break }
            end += 1
        }

        if inner {
            return NSRange(location: start, length: end - start + 1)
        }

        // For "around", include trailing whitespace (or leading if no trailing)
        var trailingEnd = end
        while trailingEnd < length - 1 {
            let char = Character(UnicodeScalar(nsText.character(at: trailingEnd + 1))!)
            if !char.isWhitespace || char == "\n" { break }
            trailingEnd += 1
        }

        if trailingEnd > end {
            return NSRange(location: start, length: trailingEnd - start + 1)
        }

        // No trailing whitespace, try leading
        var leadingStart = start
        while leadingStart > 0 {
            let char = Character(UnicodeScalar(nsText.character(at: leadingStart - 1))!)
            if !char.isWhitespace || char == "\n" { break }
            leadingStart -= 1
        }

        return NSRange(location: leadingStart, length: end - leadingStart + 1)
    }

    private func quotedRange(in text: String, from position: Int, quote: Character, inner: Bool) -> NSRange? {
        let nsText = text as NSString

        // Get current line range
        let lineRange = nsText.lineRange(for: NSRange(location: position, length: 0))
        let lineStart = lineRange.location
        let lineEnd = lineRange.location + lineRange.length

        // Find quote pairs on current line
        var quotePositions: [Int] = []
        for pos in lineStart..<lineEnd {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if char == quote {
                // Check if escaped
                if pos > 0 {
                    let prevChar = Character(UnicodeScalar(nsText.character(at: pos - 1))!)
                    if prevChar == "\\" { continue }
                }
                quotePositions.append(pos)
            }
        }

        // Find the pair that contains or is nearest to cursor
        var bestPair: (Int, Int)?
        var i = 0
        while i < quotePositions.count - 1 {
            let start = quotePositions[i]
            let end = quotePositions[i + 1]

            // Check if cursor is between or on the quotes
            if position >= start && position <= end {
                bestPair = (start, end)
                break
            }

            // Check if cursor is before this pair (use this pair)
            if position < start && bestPair == nil {
                bestPair = (start, end)
            }

            i += 2
        }

        guard let (openPos, closePos) = bestPair else { return nil }

        if inner {
            let innerStart = openPos + 1
            let innerLength = closePos - openPos - 1
            if innerLength >= 0 {
                return NSRange(location: innerStart, length: innerLength)
            }
            return nil
        } else {
            return NSRange(location: openPos, length: closePos - openPos + 1)
        }
    }

    private func bracketRange(in text: String, from position: Int, open: Character, close: Character, inner: Bool) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length

        // Find the opening bracket (search backward)
        var openPos: Int?
        var depth = 0

        for pos in stride(from: position, through: 0, by: -1) {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if char == close && pos != position {
                depth += 1
            } else if char == open {
                if depth == 0 {
                    openPos = pos
                    break
                }
                depth -= 1
            }
        }

        // If we're on the open bracket, start from there
        if openPos == nil {
            let char = Character(UnicodeScalar(nsText.character(at: position))!)
            if char == open {
                openPos = position
            }
        }

        guard let foundOpen = openPos else { return nil }

        // Find the closing bracket (search forward)
        depth = 0
        var closePos: Int?

        for pos in foundOpen..<length {
            let char = Character(UnicodeScalar(nsText.character(at: pos))!)
            if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 {
                    closePos = pos
                    break
                }
            }
        }

        guard let foundClose = closePos else { return nil }

        if inner {
            let innerStart = foundOpen + 1
            let innerLength = foundClose - foundOpen - 1
            if innerLength >= 0 {
                return NSRange(location: innerStart, length: innerLength)
            }
            return nil
        } else {
            return NSRange(location: foundOpen, length: foundClose - foundOpen + 1)
        }
    }

    private func paragraphRange(in text: String, from position: Int, inner: Bool) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        guard position >= 0 && position < length else { return nil }

        // Find start of paragraph (first non-blank line going backward)
        var start = position
        var foundContent = false

        while start > 0 {
            let lineRange = nsText.lineRange(for: NSRange(location: start, length: 0))
            let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if lineText.isEmpty {
                if foundContent {
                    start = lineRange.location + lineRange.length
                    break
                }
            } else {
                foundContent = true
            }

            if lineRange.location == 0 {
                start = 0
                break
            }
            start = lineRange.location - 1
        }

        // Find end of paragraph (first blank line going forward)
        var end = position
        foundContent = false

        while end < length {
            let lineRange = nsText.lineRange(for: NSRange(location: end, length: 0))
            let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            if lineText.isEmpty {
                if foundContent {
                    if inner {
                        end = lineRange.location
                    } else {
                        end = lineRange.location + lineRange.length
                    }
                    break
                }
            } else {
                foundContent = true
            }

            let lineEnd = lineRange.location + lineRange.length
            if lineEnd >= length {
                end = length
                break
            }
            end = lineEnd
        }

        if !inner {
            // Include trailing blank lines for "around"
            while end < length {
                let lineRange = nsText.lineRange(for: NSRange(location: end, length: 0))
                let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
                if !lineText.isEmpty { break }
                end = lineRange.location + lineRange.length
            }
        }

        return NSRange(location: start, length: end - start)
    }
}

/// Modifier that determines whether to select "inner" or "around" a text object.
public enum HelixTextObjectModifier: Sendable, Equatable {
    /// Select inside the delimiters (excludes them).
    case inner  // i
    /// Select around including delimiters.
    case around // a
}
