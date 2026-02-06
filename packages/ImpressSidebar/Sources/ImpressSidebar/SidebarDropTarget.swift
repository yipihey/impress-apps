//
//  SidebarDropTarget.swift
//  ImpressSidebar
//
//  Visual feedback wrapper for drag-and-drop targets.
//  Shows accent-color background, border, and optional green plus badge.
//
//  Extracted from imbib's SidebarView to share across all impress apps.
//

import SwiftUI

/// Visual feedback wrapper for drag-and-drop targets in sidebar rows.
///
/// Wraps any content and applies accent-color highlighting when the drop target
/// is active. Optionally shows a green plus badge to indicate "add" semantics.
///
/// **Usage:**
/// ```swift
/// SidebarDropTarget(isTargeted: isDropping) {
///     Label(library.name, systemImage: "books.vertical")
/// }
/// ```
public struct SidebarDropTarget<Content: View>: View {
    let isTargeted: Bool
    let showPlusBadge: Bool
    @ViewBuilder let content: () -> Content

    public init(
        isTargeted: Bool,
        showPlusBadge: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isTargeted = isTargeted
        self.showPlusBadge = showPlusBadge
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 0) {
            content()

            Spacer()

            // Green plus badge when targeted
            if isTargeted && showPlusBadge {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview("SidebarDropTarget") {
    VStack(spacing: 12) {
        SidebarDropTarget(isTargeted: false) {
            Label("Not Targeted", systemImage: "folder")
        }

        SidebarDropTarget(isTargeted: true) {
            Label("Targeted", systemImage: "folder")
        }

        SidebarDropTarget(isTargeted: true, showPlusBadge: false) {
            Label("Targeted (no badge)", systemImage: "folder")
        }
    }
    .frame(width: 250)
    .padding()
}
