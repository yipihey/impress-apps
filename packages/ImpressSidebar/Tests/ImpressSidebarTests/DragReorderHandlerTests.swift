//
//  DragReorderHandlerTests.swift
//  ImpressSidebar
//
//  Tests for DragReorderHandler index calculations.
//

import Foundation
import Testing
@testable import ImpressSidebar

@Suite("DragReorderHandler")
struct DragReorderHandlerTests {

    @Test("Source before target adjusts down by 1")
    func testSourceBeforeTarget() {
        // Moving item at index 1 to target index 3
        // After removing at 1, target 3 becomes 2
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 1, targetIndex: 3, count: 5)
        #expect(result == 2)
    }

    @Test("Source after target keeps target unchanged")
    func testSourceAfterTarget() {
        // Moving item at index 3 to target index 1
        // No adjustment needed
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 3, targetIndex: 1, count: 5)
        #expect(result == 1)
    }

    @Test("Source equals target keeps position")
    func testSourceEqualsTarget() {
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 2, targetIndex: 2, count: 5)
        #expect(result == 2)
    }

    @Test("Clamps to zero when target is negative")
    func testClampsToZero() {
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 0, targetIndex: 0, count: 5)
        #expect(result == 0)
    }

    @Test("Clamps to last valid index")
    func testClampsToEnd() {
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 0, targetIndex: 10, count: 5)
        #expect(result == 4)
    }

    @Test("Moving first to last in 3 items")
    func testMoveFirstToLast() {
        // [A, B, C] → move A (0) to target 3 → adjusted = 2 → [B, C, A]
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 0, targetIndex: 3, count: 3)
        #expect(result == 2)
    }

    @Test("Moving last to first in 3 items")
    func testMoveLastToFirst() {
        // [A, B, C] → move C (2) to target 0 → adjusted = 0 → [C, A, B]
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 2, targetIndex: 0, count: 3)
        #expect(result == 0)
    }

    @Test("Single item array")
    func testSingleItem() {
        let result = DragReorderHandler.adjustedDestination(sourceIndex: 0, targetIndex: 0, count: 1)
        #expect(result == 0)
    }
}
