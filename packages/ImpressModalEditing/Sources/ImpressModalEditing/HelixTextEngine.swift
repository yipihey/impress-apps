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

    /// Move cursor to the start of the current line.
    func moveToLineStart(extendSelection: Bool)

    /// Move cursor to the end of the current line.
    func moveToLineEnd(extendSelection: Bool)

    /// Move cursor to the start of the document.
    func moveToDocumentStart(extendSelection: Bool)

    /// Move cursor to the end of the document.
    func moveToDocumentEnd(extendSelection: Bool)
}

// MARK: - Default Implementations

public extension HelixTextEngine {
    /// Execute a Helix command on this text engine.
    func execute(_ command: HelixCommand, registers: HelixRegisterManager, extendSelection: Bool = false) {
        switch command {
        case .enterInsertMode, .enterNormalMode, .enterSelectMode:
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

        case .lineStart:
            moveToLineStart(extendSelection: extendSelection)

        case .lineEnd:
            moveToLineEnd(extendSelection: extendSelection)

        case .documentStart:
            moveToDocumentStart(extendSelection: extendSelection)

        case .documentEnd:
            moveToDocumentEnd(extendSelection: extendSelection)

        case .selectLine:
            selectCurrentLine()

        case .selectAll:
            selectAll()

        case .delete:
            if selectedRange.length > 0 {
                replaceSelectedText(with: "")
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

        case .undo:
            performUndo()

        case .redo:
            performRedo()
        }
    }
}
