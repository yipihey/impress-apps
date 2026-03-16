import Testing
@testable import ImpressUndoHistory

@MainActor
@Suite("UndoHistoryStore")
struct UndoHistoryStoreTests {

    @Test("records action and increments index")
    func recordAction() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "Star Paper"))
        #expect(store.entries.count == 1)
        #expect(store.currentIndex == 0)
        #expect(store.entries[0].actionName == "Star Paper")
    }

    @Test("didUndo moves index back")
    func didUndo() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "Star Paper"))
        store.recordAction(UndoHistoryEntry(actionName: "Add Tag"))
        #expect(store.currentIndex == 1)

        store.didUndo()
        #expect(store.currentIndex == 0)

        store.didUndo()
        #expect(store.currentIndex == -1)

        // Already at start — no-op
        store.didUndo()
        #expect(store.currentIndex == -1)
    }

    @Test("didRedo moves index forward")
    func didRedo() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "Star Paper"))
        store.recordAction(UndoHistoryEntry(actionName: "Add Tag"))
        store.didUndo()
        store.didUndo()
        #expect(store.currentIndex == -1)

        store.didRedo()
        #expect(store.currentIndex == 0)

        store.didRedo()
        #expect(store.currentIndex == 1)

        // Already at end — no-op
        store.didRedo()
        #expect(store.currentIndex == 1)
    }

    @Test("new action discards redo history")
    func discardRedoHistory() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "A"))
        store.recordAction(UndoHistoryEntry(actionName: "B"))
        store.recordAction(UndoHistoryEntry(actionName: "C"))
        store.didUndo() // at B
        store.didUndo() // at A

        store.recordAction(UndoHistoryEntry(actionName: "D"))
        #expect(store.entries.count == 2) // A, D — B and C discarded
        #expect(store.entries[1].actionName == "D")
        #expect(store.currentIndex == 1)
    }

    @Test("maxEntries trims old entries")
    func trimming() {
        let store = UndoHistoryStore.shared
        store.clear()
        store.maxEntries = 3

        store.recordAction(UndoHistoryEntry(actionName: "A"))
        store.recordAction(UndoHistoryEntry(actionName: "B"))
        store.recordAction(UndoHistoryEntry(actionName: "C"))
        store.recordAction(UndoHistoryEntry(actionName: "D"))

        #expect(store.entries.count == 3) // A trimmed
        #expect(store.entries[0].actionName == "B")
        #expect(store.currentIndex == 2)

        // Restore default
        store.maxEntries = 50
    }

    @Test("canUndo and canRedo")
    func canUndoRedo() {
        let store = UndoHistoryStore.shared
        store.clear()

        #expect(!store.canUndo)
        #expect(!store.canRedo)

        store.recordAction(UndoHistoryEntry(actionName: "A"))
        #expect(store.canUndo)
        #expect(!store.canRedo)

        store.didUndo()
        #expect(!store.canUndo)
        #expect(store.canRedo)
    }

    @Test("jumpToState performs correct number of steps")
    func jumpToState() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "A"))
        store.recordAction(UndoHistoryEntry(actionName: "B"))
        store.recordAction(UndoHistoryEntry(actionName: "C"))
        store.recordAction(UndoHistoryEntry(actionName: "D"))

        var undoCount = 0
        var redoCount = 0

        // Jump from D (index 3) to A (index 0) — 3 undos
        let steps = store.jumpToState(
            index: 0,
            performUndo: { undoCount += 1 },
            performRedo: { redoCount += 1 }
        )
        #expect(steps == 3)
        #expect(undoCount == 3)
        #expect(redoCount == 0)
    }

    @Test("clear resets everything")
    func clearResets() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "A"))
        store.recordAction(UndoHistoryEntry(actionName: "B"))

        store.clear()
        #expect(store.entries.isEmpty)
        #expect(store.currentIndex == -1)
    }

    @Test("reloadFromStore replaces entries")
    func reloadFromStore() {
        let store = UndoHistoryStore.shared
        store.clear()

        store.recordAction(UndoHistoryEntry(actionName: "local"))

        let storeEntries = [
            UndoHistoryEntry(actionName: "Star 3 Papers", operationCount: 3),
            UndoHistoryEntry(actionName: "Add Tag 'methods/sims'"),
        ]
        store.reloadFromStore(storeEntries)

        #expect(store.entries.count == 2)
        #expect(store.currentIndex == 1)
        #expect(store.entries[0].actionName == "Star 3 Papers")
    }
}
