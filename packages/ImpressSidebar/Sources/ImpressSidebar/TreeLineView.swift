//
//  TreeLineView.swift
//  ImpressSidebar
//
//  Shared tree line visualization for hierarchical sidebar displays.
//

import SwiftUI

/// A view that renders tree lines (└ ├ │) for hierarchical list displays.
///
/// This component provides consistent tree visualization across the impress app suite,
/// showing the hierarchical relationship between items in a tree structure.
public struct TreeLineView: View {
    /// The current depth level to render
    let level: Int

    /// The total depth of this item
    let depth: Int

    /// Whether this item is the last child of its parent
    let isLastChild: Bool

    /// Whether an ancestor at this level has siblings below it
    let hasAncestorSiblingBelow: Bool

    public init(
        level: Int,
        depth: Int,
        isLastChild: Bool,
        hasAncestorSiblingBelow: Bool
    ) {
        self.level = level
        self.depth = depth
        self.isLastChild = isLastChild
        self.hasAncestorSiblingBelow = hasAncestorSiblingBelow
    }

    public var body: some View {
        if level == depth - 1 {
            // Final level: draw └ or ├
            Text(isLastChild ? "└" : "├")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 12)
        } else {
            // Parent levels: draw │ if siblings below, else space
            if hasAncestorSiblingBelow {
                Text("│")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
        }
    }
}

// MARK: - Preview

#Preview("Tree Lines") {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 0) {
            TreeLineView(level: 0, depth: 1, isLastChild: false, hasAncestorSiblingBelow: true)
            Text("First child")
        }
        HStack(spacing: 0) {
            TreeLineView(level: 0, depth: 1, isLastChild: true, hasAncestorSiblingBelow: false)
            Text("Last child")
        }
        HStack(spacing: 0) {
            TreeLineView(level: 0, depth: 2, isLastChild: false, hasAncestorSiblingBelow: true)
            TreeLineView(level: 1, depth: 2, isLastChild: false, hasAncestorSiblingBelow: true)
            Text("Nested child")
        }
    }
    .padding()
}
