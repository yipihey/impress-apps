import Testing
@testable import ImpressModalEditing

@MainActor
@Suite("HelixState Tests")
struct HelixStateTests {
    @Test("Initial state is normal mode")
    func initialState() {
        let state = HelixState()
        #expect(state.mode == .normal)
    }

    @Test("Enter insert mode with 'i'")
    func enterInsertMode() {
        let state = HelixState()
        let handled = state.handleKey("i")
        #expect(handled == true)
        #expect(state.mode == .insert)
    }

    @Test("Exit insert mode with Escape")
    func exitInsertMode() {
        let state = HelixState()
        state.setMode(.insert)
        let handled = state.handleKey("\u{1B}")
        #expect(handled == true)
        #expect(state.mode == .normal)
    }

    @Test("Enter select mode with 'v'")
    func enterSelectMode() {
        let state = HelixState()
        let handled = state.handleKey("v")
        #expect(handled == true)
        #expect(state.mode == .select)
    }

    @Test("Exit select mode with 'v'")
    func exitSelectMode() {
        let state = HelixState()
        state.setMode(.select)
        let handled = state.handleKey("v")
        #expect(handled == true)
        #expect(state.mode == .normal)
    }

    @Test("Movement keys are handled in normal mode")
    func movementKeys() {
        let state = HelixState()
        #expect(state.handleKey("h") == true)
        #expect(state.handleKey("j") == true)
        #expect(state.handleKey("k") == true)
        #expect(state.handleKey("l") == true)
    }

    @Test("Insert mode passes through regular keys")
    func insertModePassthrough() {
        let state = HelixState()
        state.setMode(.insert)
        #expect(state.handleKey("a") == false)
        #expect(state.handleKey("b") == false)
    }
}

@MainActor
@Suite("HelixKeyHandler Tests")
struct HelixKeyHandlerTests {
    @Test("gg goes to document start")
    func documentStart() {
        let handler = HelixKeyHandler()
        let first = handler.handleKey("g", in: .normal)
        #expect(first == .pending)
        let second = handler.handleKey("g", in: .normal)
        #expect(second == .command(.documentStart))
    }

    @Test("G goes to document end")
    func documentEnd() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("G", in: .normal)
        #expect(result == .command(.documentEnd))
    }

    @Test("Count prefix works")
    func countPrefix() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("3", in: .normal)
        let result = handler.handleKey("j", in: .normal)
        #expect(result == .command(.moveDown(count: 3)))
    }

    @Test("Change key waits for motion")
    func changeAwaitsMotion() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("c", in: .normal)
        #expect(result == .pending)
        #expect(handler.pendingOperator == .change)
    }

    @Test("cc produces change line command")
    func changeLine() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("c", in: .normal)
        let result = handler.handleKey("c", in: .normal)
        #expect(result == .command(.changeMotion(.line)))
    }

    @Test("cw produces change word command")
    func changeWord() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("c", in: .normal)
        let result = handler.handleKey("w", in: .normal)
        #expect(result == .command(.changeMotion(.wordForward(count: 1))))
    }

    @Test("f key awaits character input")
    func findCharacterAwaits() {
        let handler = HelixKeyHandler()
        let first = handler.handleKey("f", in: .normal)
        #expect(first == .awaitingCharacter)
        #expect(handler.pendingCharOp == .findForward)
    }

    @Test("f followed by character produces find command")
    func findCharacter() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("f", in: .normal)
        let result = handler.handleKey("x", in: .normal)
        #expect(result == .command(.findCharacter(char: "x", count: 1)))
    }

    @Test("t key produces till command")
    func tillCharacter() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("t", in: .normal)
        let result = handler.handleKey("y", in: .normal)
        #expect(result == .command(.tillCharacter(char: "y", count: 1)))
    }

    @Test("o produces open line below")
    func openLineBelow() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("o", in: .normal)
        #expect(result == .command(.openLineBelow))
    }

    @Test("O produces open line above")
    func openLineAbove() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("O", in: .normal)
        #expect(result == .command(.openLineAbove))
    }

    @Test("a produces append after cursor")
    func appendAfterCursor() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("a", in: .normal)
        #expect(result == .command(.appendAfterCursor))
    }

    @Test("A produces append at line end")
    func appendAtLineEnd() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("A", in: .normal)
        #expect(result == .command(.appendAtLineEnd))
    }

    @Test("I produces insert at line start")
    func insertAtLineStart() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("I", in: .normal)
        #expect(result == .command(.insertAtLineStart))
    }

    @Test("J produces join lines")
    func joinLines() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("J", in: .normal)
        #expect(result == .command(.joinLines))
    }

    @Test("~ produces toggle case")
    func toggleCase() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("~", in: .normal)
        #expect(result == .command(.toggleCase))
    }

    @Test("r key awaits replacement character")
    func replaceAwaits() {
        let handler = HelixKeyHandler()
        let first = handler.handleKey("r", in: .normal)
        #expect(first == .awaitingCharacter)
        #expect(handler.pendingCharOp == .replace)
    }

    @Test("r followed by character produces replace command")
    func replaceCharacter() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("r", in: .normal)
        let result = handler.handleKey("z", in: .normal)
        #expect(result == .command(.replaceCharacter(char: "z")))
    }

    @Test(". produces repeat last change")
    func repeatLastChange() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey(".", in: .normal)
        #expect(result == .command(.repeatLastChange))
    }

    @Test("; produces repeat find")
    func repeatFind() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey(";", in: .normal)
        #expect(result == .command(.repeatFind))
    }

    @Test(", produces repeat find reverse")
    func repeatFindReverse() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey(",", in: .normal)
        #expect(result == .command(.repeatFindReverse))
    }

    @Test("/ enters search mode")
    func forwardSearch() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("/", in: .normal)
        #expect(result == .enterSearch(backward: false))
    }

    @Test("? enters backward search mode")
    func backwardSearch() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("?", in: .normal)
        #expect(result == .enterSearch(backward: true))
    }

    @Test("n produces search next")
    func searchNext() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("n", in: .normal)
        #expect(result == .command(.searchNext(count: 1)))
    }

    @Test("N produces search previous")
    func searchPrevious() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("N", in: .normal)
        #expect(result == .command(.searchPrevious(count: 1)))
    }

    @Test("> waits for motion")
    func indentAwaitsMotion() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey(">", in: .normal)
        #expect(result == .pending)
        #expect(handler.pendingOperator == .indent)
    }

    @Test(">> produces indent line")
    func indentLine() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey(">", in: .normal)
        let result = handler.handleKey(">", in: .normal)
        #expect(result == .command(.indentMotion(.line)))
    }

    @Test("< waits for motion")
    func dedentAwaitsMotion() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("<", in: .normal)
        #expect(result == .pending)
        #expect(handler.pendingOperator == .dedent)
    }

    @Test("<< produces dedent line")
    func dedentLine() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("<", in: .normal)
        let result = handler.handleKey("<", in: .normal)
        #expect(result == .command(.dedentMotion(.line)))
    }

    @Test("e produces word end")
    func wordEnd() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("e", in: .normal)
        #expect(result == .command(.wordEnd(count: 1)))
    }

    @Test("^ produces line first non-blank")
    func lineFirstNonBlank() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("^", in: .normal)
        #expect(result == .command(.lineFirstNonBlank))
    }

    @Test("s produces substitute")
    func substitute() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("s", in: .normal)
        #expect(result == .command(.substitute))
    }

    @Test("d waits for motion")
    func deleteAwaitsMotion() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("d", in: .normal)
        #expect(result == .pending)
        #expect(handler.pendingOperator == .delete)
    }

    @Test("dd produces delete line")
    func deleteLine() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("d", in: .normal)
        let result = handler.handleKey("d", in: .normal)
        #expect(result == .command(.deleteMotion(.line)))
    }

    @Test("dw produces delete word")
    func deleteWord() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("d", in: .normal)
        let result = handler.handleKey("w", in: .normal)
        #expect(result == .command(.deleteMotion(.wordForward(count: 1))))
    }

    @Test("y waits for motion")
    func yankAwaitsMotion() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("y", in: .normal)
        #expect(result == .pending)
        #expect(handler.pendingOperator == .yank)
    }

    @Test("yy produces yank line")
    func yankLine() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("y", in: .normal)
        let result = handler.handleKey("y", in: .normal)
        #expect(result == .command(.yankMotion(.line)))
    }

    @Test("diw produces delete inner word")
    func deleteInnerWord() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("d", in: .normal)
        _ = handler.handleKey("i", in: .normal)
        let result = handler.handleKey("w", in: .normal)
        #expect(result == .command(.deleteTextObject(.innerWord)))
    }

    @Test("ci\" produces change inner quote")
    func changeInnerQuote() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("c", in: .normal)
        _ = handler.handleKey("i", in: .normal)
        let result = handler.handleKey("\"", in: .normal)
        #expect(result == .command(.changeTextObject(.innerDoubleQuote)))
    }

    @Test("da( produces delete around paren")
    func deleteAroundParen() {
        let handler = HelixKeyHandler()
        _ = handler.handleKey("d", in: .normal)
        _ = handler.handleKey("a", in: .normal)
        let result = handler.handleKey("(", in: .normal)
        #expect(result == .command(.deleteTextObject(.aroundParen)))
    }

    @Test("{ produces paragraph backward")
    func paragraphBackward() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("{", in: .normal)
        #expect(result == .command(.paragraphBackward(count: 1)))
    }

    @Test("} produces paragraph forward")
    func paragraphForward() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("}", in: .normal)
        #expect(result == .command(.paragraphForward(count: 1)))
    }

    @Test("m produces matching bracket")
    func matchingBracket() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("m", in: .normal)
        #expect(result == .command(.matchingBracket))
    }
}
