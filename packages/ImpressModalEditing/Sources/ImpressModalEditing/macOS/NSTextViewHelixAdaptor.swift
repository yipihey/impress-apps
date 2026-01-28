#if canImport(AppKit)
import AppKit
import Combine

/// Adaptor that adds Helix-style modal editing to an NSTextView.
@MainActor
public final class NSTextViewHelixAdaptor: NSObject {
    /// The text view being adapted.
    public weak var textView: NSTextView?

    /// The Helix state machine.
    public let helixState: HelixState

    /// Whether Helix mode is enabled.
    @Published public var isEnabled: Bool = true

    /// Current search query (persists for n/N navigation).
    @Published public var currentSearchQuery: String = ""

    /// Whether search is backward.
    @Published public var searchBackward: Bool = false

    private var cancellables = Set<AnyCancellable>()

    public init(textView: NSTextView, helixState: HelixState) {
        self.textView = textView
        self.helixState = helixState
        super.init()

        // Subscribe to search events
        helixState.searchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSearchEvent(event)
            }
            .store(in: &cancellables)
    }

    /// Handle a key event. Returns true if the event was handled.
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        // Check the adaptor's enabled state - each app controls this independently
        guard isEnabled, let textView else { return false }

        // Handle search mode input
        if helixState.isSearching {
            return handleSearchInput(event)
        }

        // In insert mode, only handle Escape
        if helixState.mode == .insert {
            if event.keyCode == 53 { // Escape key
                helixState.setMode(.normal)
                return true
            }
            return false
        }

        // Get the character from the event
        guard let characters = event.charactersIgnoringModifiers,
              let char = characters.first else {
            return false
        }

        let modifiers = KeyModifiers(flags: event.modifierFlags)
        let engine = NSTextViewHelixEngine(textView: textView, searchQuery: currentSearchQuery, searchBackward: searchBackward)

        return helixState.handleKey(char, modifiers: modifiers, helixTextEngine: engine)
    }

    // MARK: - Search Handling

    private func handleSearchInput(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            helixState.cancelSearch()
            return true
        }

        if event.keyCode == 36 { // Return/Enter
            currentSearchQuery = helixState.searchQuery
            searchBackward = helixState.searchBackward
            if let textView {
                let engine = NSTextViewHelixEngine(textView: textView, searchQuery: currentSearchQuery, searchBackward: searchBackward)
                helixState.executeSearch(helixTextEngine: engine)
            }
            return true
        }

        if event.keyCode == 51 { // Backspace
            if !helixState.searchQuery.isEmpty {
                helixState.searchQuery.removeLast()
            }
            return true
        }

        // Regular character input
        if let characters = event.characters, !characters.isEmpty {
            helixState.searchQuery += characters
        }
        return true
    }

    private func handleSearchEvent(_ event: SearchEvent) {
        switch event {
        case .beginSearch:
            // Search UI will be shown by the view
            break
        case .searchExecuted(let query, let backward):
            currentSearchQuery = query
            searchBackward = backward
        case .searchCancelled:
            break
        }
    }
}

/// Text engine implementation for NSTextView.
@MainActor
public final class NSTextViewHelixEngine: HelixTextEngine {
    private let textView: NSTextView
    private let searchQuery: String
    private let searchBackward: Bool

    public init(textView: NSTextView, searchQuery: String = "", searchBackward: Bool = false) {
        self.textView = textView
        self.searchQuery = searchQuery
        self.searchBackward = searchBackward
    }

    public var text: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    public var selectedRange: NSRange {
        get { textView.selectedRange() }
        set { textView.setSelectedRange(newValue) }
    }

    public func performUndo() {
        textView.undoManager?.undo()
    }

    public func performRedo() {
        textView.undoManager?.redo()
    }

    public func replaceSelectedText(with text: String) {
        textView.insertText(text, replacementRange: selectedRange)
    }

    public func text(in range: NSRange) -> String? {
        guard let textStorage = textView.textStorage else { return nil }
        guard range.location >= 0,
              range.location + range.length <= textStorage.length else {
            return nil
        }
        return textStorage.attributedSubstring(from: range).string
    }

    public func moveCursor(to position: Int, extendSelection: Bool) {
        let clampedPosition = max(0, min(position, text.count))
        if extendSelection {
            let current = selectedRange
            let anchor = current.location
            if clampedPosition >= anchor {
                selectedRange = NSRange(location: anchor, length: clampedPosition - anchor)
            } else {
                selectedRange = NSRange(location: clampedPosition, length: anchor - clampedPosition)
            }
        } else {
            selectedRange = NSRange(location: clampedPosition, length: 0)
        }
    }

    public func selectCurrentLine() {
        let range = (text as NSString).lineRange(for: selectedRange)
        selectedRange = range
    }

    public func selectAll() {
        selectedRange = NSRange(location: 0, length: text.count)
    }

    public func moveLeft(count: Int, extendSelection: Bool) {
        let newPosition = max(0, selectedRange.location - count)
        moveCursor(to: newPosition, extendSelection: extendSelection)
    }

    public func moveRight(count: Int, extendSelection: Bool) {
        let currentEnd = selectedRange.location + selectedRange.length
        let newPosition = min(text.count, currentEnd + count)
        moveCursor(to: newPosition, extendSelection: extendSelection)
    }

    public func moveUp(count: Int, extendSelection: Bool) {
        // Use NSTextView's built-in functionality
        if extendSelection {
            for _ in 0..<count {
                textView.moveUpAndModifySelection(nil)
            }
        } else {
            for _ in 0..<count {
                textView.moveUp(nil)
            }
        }
    }

    public func moveDown(count: Int, extendSelection: Bool) {
        if extendSelection {
            for _ in 0..<count {
                textView.moveDownAndModifySelection(nil)
            }
        } else {
            for _ in 0..<count {
                textView.moveDown(nil)
            }
        }
    }

    public func moveWordForward(count: Int, extendSelection: Bool) {
        if extendSelection {
            for _ in 0..<count {
                textView.moveWordForwardAndModifySelection(nil)
            }
        } else {
            for _ in 0..<count {
                textView.moveWordForward(nil)
            }
        }
    }

    public func moveWordBackward(count: Int, extendSelection: Bool) {
        if extendSelection {
            for _ in 0..<count {
                textView.moveWordBackwardAndModifySelection(nil)
            }
        } else {
            for _ in 0..<count {
                textView.moveWordBackward(nil)
            }
        }
    }

    public func moveWordEnd(count: Int, extendSelection: Bool) {
        // Move to end of current/next word
        // NSTextView doesn't have a direct moveToEndOfWord, so we implement it
        for _ in 0..<count {
            // Move word forward then back to get to end of word
            if extendSelection {
                textView.moveWordForwardAndModifySelection(nil)
            } else {
                textView.moveWordForward(nil)
            }
        }
    }

    public func moveToLineStart(extendSelection: Bool) {
        if extendSelection {
            textView.moveToBeginningOfLineAndModifySelection(nil)
        } else {
            textView.moveToBeginningOfLine(nil)
        }
    }

    public func moveToLineEnd(extendSelection: Bool) {
        if extendSelection {
            textView.moveToEndOfLineAndModifySelection(nil)
        } else {
            textView.moveToEndOfLine(nil)
        }
    }

    public func moveToLineFirstNonBlank(extendSelection: Bool) {
        // Move to beginning, then skip whitespace
        moveToLineStart(extendSelection: false)
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

    public func moveToDocumentStart(extendSelection: Bool) {
        if extendSelection {
            textView.moveToBeginningOfDocumentAndModifySelection(nil)
        } else {
            textView.moveToBeginningOfDocument(nil)
        }
    }

    public func moveToDocumentEnd(extendSelection: Bool) {
        if extendSelection {
            textView.moveToEndOfDocumentAndModifySelection(nil)
        } else {
            textView.moveToEndOfDocument(nil)
        }
    }

    // MARK: - Search

    public func searchNext(count: Int, extendSelection: Bool) {
        guard !searchQuery.isEmpty else { return }

        for _ in 0..<count {
            let start = selectedRange.location + selectedRange.length
            let searchRange = NSRange(location: start, length: text.count - start)

            let range = (text as NSString).range(of: searchQuery, options: [], range: searchRange)
            if range.location != NSNotFound {
                if extendSelection {
                    let anchor = selectedRange.location
                    selectedRange = NSRange(location: anchor, length: range.location + range.length - anchor)
                } else {
                    selectedRange = range
                }
            } else {
                // Wrap around to beginning
                let wrapRange = NSRange(location: 0, length: start)
                let wrapResult = (text as NSString).range(of: searchQuery, options: [], range: wrapRange)
                if wrapResult.location != NSNotFound {
                    selectedRange = wrapResult
                }
            }
        }
        textView.scrollRangeToVisible(selectedRange)
    }

    public func searchPrevious(count: Int, extendSelection: Bool) {
        guard !searchQuery.isEmpty else { return }

        for _ in 0..<count {
            let searchRange = NSRange(location: 0, length: selectedRange.location)

            let range = (text as NSString).range(of: searchQuery, options: .backwards, range: searchRange)
            if range.location != NSNotFound {
                if extendSelection {
                    let end = selectedRange.location + selectedRange.length
                    selectedRange = NSRange(location: range.location, length: end - range.location)
                } else {
                    selectedRange = range
                }
            } else {
                // Wrap around to end
                let wrapRange = NSRange(location: selectedRange.location, length: text.count - selectedRange.location)
                let wrapResult = (text as NSString).range(of: searchQuery, options: .backwards, range: wrapRange)
                if wrapResult.location != NSNotFound {
                    selectedRange = wrapResult
                }
            }
        }
        textView.scrollRangeToVisible(selectedRange)
    }

    // MARK: - Line Operations

    public func openLineBelow() {
        moveToLineEnd(extendSelection: false)
        textView.insertText("\n", replacementRange: textView.selectedRange())
    }

    public func openLineAbove() {
        moveToLineStart(extendSelection: false)
        let pos = selectedRange.location
        textView.insertText("\n", replacementRange: NSRange(location: pos, length: 0))
        selectedRange = NSRange(location: pos, length: 0)
    }

    public func moveAfterCursor() {
        if selectedRange.location < text.count {
            selectedRange = NSRange(location: selectedRange.location + 1, length: 0)
        }
    }

    public func moveToEndForAppend() {
        moveToLineEnd(extendSelection: false)
    }

    public func moveToLineStartForInsert() {
        moveToLineFirstNonBlank(extendSelection: false)
    }

    public func joinLines() {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineEnd = lineRange.location + lineRange.length

        guard lineEnd <= text.count else { return }

        // Find where next line's content starts (skip whitespace)
        var contentStart = lineEnd
        let textNS = text as NSString
        while contentStart < textNS.length {
            let char = textNS.character(at: contentStart)
            if char != 0x20 && char != 0x09 && char != 0x0A { // space, tab, newline
                break
            }
            contentStart += 1
        }

        // Replace newline and leading whitespace with a single space
        if lineEnd > 0 {
            let rangeToReplace = NSRange(location: lineEnd - 1, length: contentStart - lineEnd + 1)
            textView.insertText(" ", replacementRange: rangeToReplace)
        }
    }

    public func toggleCase() {
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

        let cursorPos = selectedRange.location
        textView.insertText(toggled, replacementRange: range)
        // Move cursor to next character
        selectedRange = NSRange(location: min(cursorPos + 1, text.count), length: 0)
    }

    public func indent() {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        textView.insertText("\t", replacementRange: NSRange(location: lineRange.location, length: 0))
    }

    public func dedent() {
        let lineRange = (text as NSString).lineRange(for: selectedRange)
        let lineText = (text as NSString).substring(with: lineRange)

        if lineText.hasPrefix("\t") {
            textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: 1))
        } else if lineText.hasPrefix("    ") {
            textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: 4))
        } else if lineText.hasPrefix(" ") {
            textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: 1))
        }
    }

    public func replaceCharacter(with char: Character) {
        let range = NSRange(location: selectedRange.location, length: 1)
        if range.location + range.length <= text.count {
            textView.insertText(String(char), replacementRange: range)
            selectedRange = NSRange(location: range.location, length: 0)
        }
    }

    // MARK: - Scroll/Page Motions (NSTextView-specific implementations)

    public func scrollDown(count: Int, extendSelection: Bool) {
        // Use NSTextView's page down functionality for half-page scroll
        for _ in 0..<count {
            if extendSelection {
                textView.pageDownAndModifySelection(nil)
            } else {
                textView.pageDown(nil)
            }
        }
    }

    public func scrollUp(count: Int, extendSelection: Bool) {
        // Use NSTextView's page up functionality for half-page scroll
        for _ in 0..<count {
            if extendSelection {
                textView.pageUpAndModifySelection(nil)
            } else {
                textView.pageUp(nil)
            }
        }
    }

    public func pageDown(count: Int, extendSelection: Bool) {
        for _ in 0..<count {
            if extendSelection {
                textView.pageDownAndModifySelection(nil)
            } else {
                textView.pageDown(nil)
            }
        }
    }

    public func pageUp(count: Int, extendSelection: Bool) {
        for _ in 0..<count {
            if extendSelection {
                textView.pageUpAndModifySelection(nil)
            } else {
                textView.pageUp(nil)
            }
        }
    }
}

/// NSTextView subclass that supports Helix-style modal editing.
open class HelixTextView: NSTextView {
    /// The Helix adaptor managing this text view.
    public var helixAdaptor: NSTextViewHelixAdaptor?

    open override func keyDown(with event: NSEvent) {
        if let adaptor = helixAdaptor, adaptor.handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}
#endif
