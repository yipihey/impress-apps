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

    private var cancellables = Set<AnyCancellable>()

    public init(textView: NSTextView, helixState: HelixState) {
        self.textView = textView
        self.helixState = helixState
        super.init()
    }

    /// Handle a key event. Returns true if the event was handled.
    public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isEnabled, let textView else { return false }

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
        let engine = NSTextViewHelixEngine(textView: textView)

        return helixState.handleKey(char, modifiers: modifiers, textEngine: engine)
    }
}

/// Text engine implementation for NSTextView.
@MainActor
public final class NSTextViewHelixEngine: HelixTextEngine {
    private let textView: NSTextView

    public init(textView: NSTextView) {
        self.textView = textView
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
