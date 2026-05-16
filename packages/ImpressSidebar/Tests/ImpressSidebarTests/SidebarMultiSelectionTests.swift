//
//  SidebarMultiSelectionTests.swift
//  ImpressSidebar
//
//  Tests for SidebarMultiSelection state management.
//

import Foundation
import Testing
@testable import ImpressSidebar

@MainActor
@Suite("SidebarMultiSelection")
struct SidebarMultiSelectionTests {

    let ordered = ["a", "b", "c", "d", "e"]

    @Test("Initial state is empty")
    func testInitialState() {
        let selection = SidebarMultiSelection<String>()
        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.lastSelectedID == nil)
    }

    @Test("Clear resets all state")
    func testClear() {
        let selection = SidebarMultiSelection<String>()
        selection.selectedIDs = ["a", "b", "c"]
        selection.lastSelectedID = "b"

        selection.clear()

        #expect(selection.selectedIDs.isEmpty)
        #expect(selection.lastSelectedID == nil)
    }

    @Test("isSelected returns correct membership")
    func testIsSelected() {
        let selection = SidebarMultiSelection<String>()
        selection.selectedIDs = ["a", "c"]

        #expect(selection.isSelected("a") == true)
        #expect(selection.isSelected("b") == false)
        #expect(selection.isSelected("c") == true)
    }

    // MARK: - Plain Click

    @Test("Plain click replaces selection")
    func testPlainClick() {
        let selection = SidebarMultiSelection<String>()
        selection.selectedIDs = ["a", "b"]
        selection.lastSelectedID = "a"

        let action = selection.handleClick("c", orderedIDs: ordered, modifiers: [])

        #expect(selection.selectedIDs == ["c"])
        #expect(selection.lastSelectedID == "c")
        if case .single(let id) = action {
            #expect(id == "c")
        } else {
            Issue.record("Expected .single action")
        }
    }

    @Test("Multiple plain clicks replace each time")
    func testSequentialPlainClicks() {
        let selection = SidebarMultiSelection<String>()

        selection.handleClick("a", orderedIDs: ordered, modifiers: [])
        #expect(selection.selectedIDs == ["a"])

        selection.handleClick("c", orderedIDs: ordered, modifiers: [])
        #expect(selection.selectedIDs == ["c"])

        selection.handleClick("b", orderedIDs: ordered, modifiers: [])
        #expect(selection.selectedIDs == ["b"])
    }

    // MARK: - Option+Click (Toggle)

    @Test("Option+click toggles item into selection")
    func testOptionClickAdds() {
        let selection = SidebarMultiSelection<String>()
        selection.handleClick("a", orderedIDs: ordered, modifiers: [])

        let action = selection.handleClick("c", orderedIDs: ordered, modifiers: .option)

        #expect(selection.selectedIDs == ["a", "c"])
        #expect(selection.lastSelectedID == "c")
        if case .toggled(let id) = action {
            #expect(id == "c")
        } else {
            Issue.record("Expected .toggled action")
        }
    }

    @Test("Option+click toggles item out of selection")
    func testOptionClickRemoves() {
        let selection = SidebarMultiSelection<String>()
        selection.selectedIDs = ["a", "b", "c"]
        selection.lastSelectedID = "c"

        let action = selection.handleClick("b", orderedIDs: ordered, modifiers: .option)

        #expect(selection.selectedIDs == ["a", "c"])
        #expect(selection.lastSelectedID == "b")
        if case .toggled(let id) = action {
            #expect(id == "b")
        } else {
            Issue.record("Expected .toggled action")
        }
    }

    @Test("Multiple Option+clicks build up selection")
    func testMultipleOptionClicks() {
        let selection = SidebarMultiSelection<String>()

        selection.handleClick("a", orderedIDs: ordered, modifiers: [])
        selection.handleClick("c", orderedIDs: ordered, modifiers: .option)
        selection.handleClick("e", orderedIDs: ordered, modifiers: .option)

        #expect(selection.selectedIDs == ["a", "c", "e"])
    }

    // MARK: - Shift+Click (Range)

    @Test("Shift+click selects range forward")
    func testShiftClickForward() {
        let selection = SidebarMultiSelection<String>()
        selection.handleClick("b", orderedIDs: ordered, modifiers: [])

        let action = selection.handleClick("d", orderedIDs: ordered, modifiers: .shift)

        #expect(selection.selectedIDs == ["b", "c", "d"])
        if case .rangeSelected(let range) = action {
            #expect(range == 1...3)
        } else {
            Issue.record("Expected .rangeSelected action")
        }
    }

    @Test("Shift+click selects range backward")
    func testShiftClickBackward() {
        let selection = SidebarMultiSelection<String>()
        selection.handleClick("d", orderedIDs: ordered, modifiers: [])

        let action = selection.handleClick("b", orderedIDs: ordered, modifiers: .shift)

        #expect(selection.selectedIDs == ["b", "c", "d"])
        if case .rangeSelected(let range) = action {
            #expect(range == 1...3)
        } else {
            Issue.record("Expected .rangeSelected action")
        }
    }

    @Test("Shift+click with no anchor falls back to single")
    func testShiftClickNoAnchor() {
        let selection = SidebarMultiSelection<String>()
        // No previous click, so no anchor

        selection.handleClick("c", orderedIDs: ordered, modifiers: .shift)

        // With no anchor, rangeSelect adds the item and returns nil,
        // but the fallback in handleClick replaces selection
        #expect(selection.selectedIDs.contains("c"))
        #expect(selection.lastSelectedID == "c")
    }

    @Test("Shift+click adds to existing selection")
    func testShiftClickAddsToExisting() {
        let selection = SidebarMultiSelection<String>()
        // Select a, then option+click e, then shift from e back to c
        selection.handleClick("a", orderedIDs: ordered, modifiers: [])
        selection.handleClick("e", orderedIDs: ordered, modifiers: .option)
        selection.handleClick("c", orderedIDs: ordered, modifiers: .shift)

        // a was from initial, e from option, c-d-e from shift range
        #expect(selection.selectedIDs.contains("a"))
        #expect(selection.selectedIDs.contains("c"))
        #expect(selection.selectedIDs.contains("d"))
        #expect(selection.selectedIDs.contains("e"))
    }

    @Test("Shift+click same item as anchor")
    func testShiftClickSameAsAnchor() {
        let selection = SidebarMultiSelection<String>()
        selection.handleClick("c", orderedIDs: ordered, modifiers: [])

        let action = selection.handleClick("c", orderedIDs: ordered, modifiers: .shift)

        #expect(selection.selectedIDs == ["c"])
        if case .rangeSelected(let range) = action {
            #expect(range == 2...2)
        } else {
            Issue.record("Expected .rangeSelected action")
        }
    }

    // MARK: - UUID and Int ID Types

    @Test("Works with UUID IDs")
    func testUUIDIDs() {
        let selection = SidebarMultiSelection<UUID>()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        selection.handleClick(id1, orderedIDs: [id1, id2, id3], modifiers: [])
        #expect(selection.selectedIDs == [id1])

        selection.handleClick(id3, orderedIDs: [id1, id2, id3], modifiers: .option)
        #expect(selection.selectedIDs == [id1, id3])
    }

    @Test("Works with Int IDs")
    func testIntIDs() {
        let selection = SidebarMultiSelection<Int>()

        selection.handleClick(5, orderedIDs: [1, 2, 3, 4, 5], modifiers: [])
        #expect(selection.selectedIDs == [5])
        #expect(selection.lastSelectedID == 5)
    }
}
