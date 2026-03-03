import Testing
import SwiftUI
@testable import ImpressKeyboard

// MARK: - Test Pane Enums

enum ThreePane: String, PaneFocus {
    case sidebar, list, detail
    static let allPanes: [ThreePane] = [.sidebar, .list, .detail]
}

enum TwoPane: String, PaneFocus {
    case left, right
    static let allPanes: [TwoPane] = [.left, .right]
}

enum SinglePane: String, PaneFocus {
    case only
    static let allPanes: [SinglePane] = [.only]
}

// MARK: - Tests

@Suite("Pane Focus Cycler")
struct PaneFocusCyclerTests {

    // MARK: - Three-pane cycling

    @Test("next cycles forward through three panes")
    func nextThreePanes() {
        #expect(ThreePane.sidebar.next == .list)
        #expect(ThreePane.list.next == .detail)
        #expect(ThreePane.detail.next == .sidebar) // wraps around
    }

    @Test("previous cycles backward through three panes")
    func previousThreePanes() {
        #expect(ThreePane.detail.previous == .list)
        #expect(ThreePane.list.previous == .sidebar)
        #expect(ThreePane.sidebar.previous == .detail) // wraps around
    }

    // MARK: - Two-pane cycling

    @Test("Two panes toggle between each other")
    func twoPaneCycling() {
        #expect(TwoPane.left.next == .right)
        #expect(TwoPane.right.next == .left)
        #expect(TwoPane.left.previous == .right)
        #expect(TwoPane.right.previous == .left)
    }

    // MARK: - Single pane

    @Test("Single pane returns self for next and previous")
    func singlePane() {
        #expect(SinglePane.only.next == .only)
        #expect(SinglePane.only.previous == .only)
    }

    // MARK: - Full cycle

    @Test("Cycling next through all panes returns to start")
    func fullCycleNext() {
        var current = ThreePane.sidebar
        for _ in 0..<ThreePane.allPanes.count {
            current = current.next
        }
        #expect(current == .sidebar)
    }

    @Test("Cycling previous through all panes returns to start")
    func fullCyclePrevious() {
        var current = ThreePane.sidebar
        for _ in 0..<ThreePane.allPanes.count {
            current = current.previous
        }
        #expect(current == .sidebar)
    }
}
