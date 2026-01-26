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

    @Test("Change command produces delete and insert mode")
    func changeCommand() {
        let handler = HelixKeyHandler()
        let result = handler.handleKey("c", in: .normal)
        #expect(result == .commands([.delete, .enterInsertMode]))
    }
}
