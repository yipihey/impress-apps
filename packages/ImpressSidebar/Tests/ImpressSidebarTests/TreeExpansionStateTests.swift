import Testing
import Foundation
@testable import ImpressSidebar

@Suite("Tree Expansion State")
@MainActor
struct TreeExpansionStateTests {

    @Test("New state has all nodes collapsed")
    func initialStateEmpty() {
        let state = TreeExpansionState()
        let id = UUID()
        #expect(!state.isExpanded(id))
        #expect(state.expandedIDs.isEmpty)
    }

    @Test("Initializer with pre-expanded IDs")
    func initiallyExpanded() {
        let id1 = UUID()
        let id2 = UUID()
        let state = TreeExpansionState(initiallyExpanded: [id1, id2])
        #expect(state.isExpanded(id1))
        #expect(state.isExpanded(id2))
        #expect(!state.isExpanded(UUID()))
    }

    @Test("expand() makes node expanded")
    func expand() {
        let state = TreeExpansionState()
        let id = UUID()
        state.expand(id)
        #expect(state.isExpanded(id))
    }

    @Test("collapse() makes node collapsed")
    func collapse() {
        let id = UUID()
        let state = TreeExpansionState(initiallyExpanded: [id])
        state.collapse(id)
        #expect(!state.isExpanded(id))
    }

    @Test("toggle() flips expansion state")
    func toggle() {
        let state = TreeExpansionState()
        let id = UUID()
        #expect(!state.isExpanded(id))
        state.toggle(id)
        #expect(state.isExpanded(id))
        state.toggle(id)
        #expect(!state.isExpanded(id))
    }

    @Test("expandAll() expands multiple nodes at once")
    func expandAll() {
        let state = TreeExpansionState()
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        state.expandAll(ids)
        for id in ids {
            #expect(state.isExpanded(id))
        }
    }

    @Test("collapseAll() clears all expansion")
    func collapseAll() {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        let state = TreeExpansionState(initiallyExpanded: ids)
        #expect(state.expandedIDs.count == 3)
        state.collapseAll()
        #expect(state.expandedIDs.isEmpty)
    }

    @Test("expandAncestors() expands all ancestor IDs")
    func expandAncestors() {
        let state = TreeExpansionState()
        let root = UUID()
        let parent = UUID()
        let grandparent = UUID()
        state.expandAncestors([grandparent, parent, root])
        #expect(state.isExpanded(root))
        #expect(state.isExpanded(parent))
        #expect(state.isExpanded(grandparent))
    }

    @Test("expand is idempotent")
    func expandIdempotent() {
        let state = TreeExpansionState()
        let id = UUID()
        state.expand(id)
        state.expand(id)
        #expect(state.expandedIDs.count == 1)
    }

    @Test("collapse on non-expanded node is no-op")
    func collapseNonExpanded() {
        let state = TreeExpansionState()
        let id = UUID()
        state.collapse(id) // should not crash
        #expect(!state.isExpanded(id))
    }
}
