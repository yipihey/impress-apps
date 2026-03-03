import Testing
import Foundation
import SwiftUI
@testable import ImpressSidebar

// MARK: - Test Node

/// Minimal SidebarTreeNode conformance for testing
@MainActor
struct TestNode: SidebarTreeNode {
    let id: UUID
    let displayName: String
    let iconName: String = "folder"
    let treeDepth: Int
    var children: [TestNode] = []

    // SidebarTreeNode defaults handle displayCount, starCount, parentID, childIDs, ancestorIDs, iconColor, hasTreeChildren
}

// MARK: - Tests

@Suite("Tree Flattener")
@MainActor
struct TreeFlattenerTests {

    // MARK: - Helpers

    private func makeNode(_ name: String, depth: Int = 0, children: [TestNode] = []) -> TestNode {
        TestNode(id: UUID(), displayName: name, treeDepth: depth, children: children)
    }

    // MARK: - Empty input

    @Test("Empty roots produces empty result")
    func emptyRoots() {
        let result = TreeFlattener.flatten(
            roots: [TestNode](),
            children: { $0.children },
            isExpanded: { _ in false }
        )
        #expect(result.isEmpty)
    }

    // MARK: - Single root

    @Test("Single root with no children produces one node")
    func singleRoot() {
        let root = makeNode("Root")
        let result = TreeFlattener.flatten(
            roots: [root],
            children: { $0.children },
            isExpanded: { _ in false }
        )
        #expect(result.count == 1)
        #expect(result[0].node.displayName == "Root")
        #expect(result[0].isLastChild == true)
        #expect(result[0].ancestorHasSiblingsBelow.isEmpty)
    }

    // MARK: - Multiple roots

    @Test("Two roots have correct isLastChild flags")
    func twoRoots() {
        let root1 = makeNode("First")
        let root2 = makeNode("Second")
        let result = TreeFlattener.flatten(
            roots: [root1, root2],
            children: { $0.children },
            isExpanded: { _ in false }
        )
        #expect(result.count == 2)
        #expect(result[0].isLastChild == false)
        #expect(result[1].isLastChild == true)
    }

    // MARK: - Expanded parent with children

    @Test("Expanded parent shows children")
    func expandedWithChildren() {
        let child1 = makeNode("Child 1", depth: 1)
        let child2 = makeNode("Child 2", depth: 1)
        let child3 = makeNode("Child 3", depth: 1)
        let parent = makeNode("Parent", children: [child1, child2, child3])

        let result = TreeFlattener.flatten(
            roots: [parent],
            children: { $0.children },
            isExpanded: { _ in true }
        )
        #expect(result.count == 4) // parent + 3 children
        #expect(result[0].node.displayName == "Parent")
        #expect(result[1].node.displayName == "Child 1")
        #expect(result[1].isLastChild == false)
        #expect(result[2].node.displayName == "Child 2")
        #expect(result[2].isLastChild == false)
        #expect(result[3].node.displayName == "Child 3")
        #expect(result[3].isLastChild == true)
    }

    // MARK: - Collapsed parent hides children

    @Test("Collapsed parent hides children")
    func collapsedHidesChildren() {
        let child = makeNode("Child", depth: 1)
        let parent = makeNode("Parent", children: [child])

        let result = TreeFlattener.flatten(
            roots: [parent],
            children: { $0.children },
            isExpanded: { _ in false }
        )
        #expect(result.count == 1)
        #expect(result[0].node.displayName == "Parent")
    }

    // MARK: - Nested tree (3 levels)

    @Test("Three-level nested tree has correct ancestorHasSiblingsBelow")
    func nestedTree() {
        let grandchild = makeNode("Grandchild", depth: 2)
        let child = makeNode("Child", depth: 1, children: [grandchild])
        let root = makeNode("Root", children: [child])

        let result = TreeFlattener.flatten(
            roots: [root],
            children: { $0.children },
            isExpanded: { _ in true }
        )
        #expect(result.count == 3)
        // Root: no ancestors
        #expect(result[0].ancestorHasSiblingsBelow.isEmpty)
        // Child: ancestor is Root (which is last child → no siblings below)
        #expect(result[1].ancestorHasSiblingsBelow == [false])
        // Grandchild: ancestors are [Root (no siblings), Child (no siblings)]
        #expect(result[2].ancestorHasSiblingsBelow == [false, false])
    }

    // MARK: - Mixed expanded/collapsed

    @Test("Mixed expansion shows correct subset")
    func mixedExpansion() {
        let childA1 = makeNode("A1", depth: 1)
        let childB1 = makeNode("B1", depth: 1)
        let parentA = makeNode("ParentA", children: [childA1])
        let parentB = makeNode("ParentB", children: [childB1])

        // Only expand ParentA
        let expandedIDs: Set<UUID> = [parentA.id]
        let result = TreeFlattener.flatten(
            roots: [parentA, parentB],
            children: { $0.children },
            isExpanded: { expandedIDs.contains($0.id) }
        )
        #expect(result.count == 3) // ParentA, A1, ParentB
        #expect(result[0].node.displayName == "ParentA")
        #expect(result[1].node.displayName == "A1")
        #expect(result[2].node.displayName == "ParentB")
    }

    // MARK: - Sibling info for tree lines

    @Test("ancestorHasSiblingsBelow is correct for sibling trees")
    func siblingTreeLines() {
        let childA = makeNode("A-child", depth: 1)
        let childB = makeNode("B-child", depth: 1)
        let rootA = makeNode("RootA", children: [childA])
        let rootB = makeNode("RootB", children: [childB])

        let result = TreeFlattener.flatten(
            roots: [rootA, rootB],
            children: { $0.children },
            isExpanded: { _ in true }
        )
        // RootA (not last) -> A-child -> RootB (last) -> B-child
        #expect(result.count == 4)
        // A-child's ancestor (RootA) has siblings below it
        #expect(result[1].ancestorHasSiblingsBelow == [true])
        // B-child's ancestor (RootB) does NOT have siblings below it
        #expect(result[3].ancestorHasSiblingsBelow == [false])
    }

    // MARK: - Array extension

    @Test("Array.flattened() extension matches TreeFlattener.flatten()")
    func arrayExtension() {
        let child = makeNode("Child", depth: 1)
        let root = makeNode("Root", children: [child])
        let roots = [root]

        let direct = TreeFlattener.flatten(
            roots: roots,
            children: { $0.children },
            isExpanded: { _ in true }
        )
        let extension_ = roots.flattened(
            children: { $0.children },
            isExpanded: { _ in true }
        )
        #expect(direct.count == extension_.count)
        for i in 0..<direct.count {
            #expect(direct[i].id == extension_[i].id)
            #expect(direct[i].isLastChild == extension_[i].isLastChild)
        }
    }
}
