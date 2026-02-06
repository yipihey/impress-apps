//
//  DraggableSectionHeader.swift
//  ImpressSidebar
//
//  Reusable section header with drag-reorder support.
//  Renders: [optional chevron] [title] [spacer] [extras]
//  Plus: draggable modifier, drop target, blue insertion line.
//

import SwiftUI
import UniformTypeIdentifiers

/// Reusable section header with drag-reorder support.
///
/// Covers:
/// - imprint's workspace/recentDocuments headers (no collapse chevron)
/// - imbib's standard collapsible headers (libraries, search, flagged, etc.)
/// - Any future impress app's sidebar section headers
///
/// **Usage (no collapse):**
/// ```swift
/// DraggableSectionHeader(
///     section: .workspace,
///     title: workspace?.name,
///     dragValue: SectionDragItem(type: .workspace),
///     dropUTTypes: [.mySectionID],
///     isDropTarget: dropTarget == .workspace,
///     onDrop: { providers in handleDrop(providers, .workspace) },
///     onDropTargetChanged: { targeted in dropTarget = targeted ? .workspace : nil }
/// ) {
///     Button { ... } label: { Image(systemName: "plus") }
/// }
/// ```
///
/// **Usage (with collapse):**
/// ```swift
/// DraggableSectionHeader(
///     section: .libraries,
///     dragValue: SectionDragItem(type: .libraries),
///     dropUTTypes: [.sidebarSectionID],
///     isDropTarget: dropTarget == .libraries,
///     isCollapsed: collapsedSections.contains(.libraries),
///     onCollapse: { toggleSection(.libraries) },
///     onDrop: { providers in handleDrop(providers, .libraries) },
///     onDropTargetChanged: { targeted in dropTarget = targeted ? .libraries : nil }
/// )
/// ```
public struct DraggableSectionHeader<
    Section: SidebarSection,
    DragValue: Transferable,
    Extras: View
>: View {
    let section: Section
    let title: String?
    let dragValue: DragValue
    let dropUTTypes: [UTType]
    let isDropTarget: Bool
    let isCollapsed: Bool?
    let onCollapse: (() -> Void)?
    let onDrop: ([NSItemProvider]) -> Bool
    let onDropTargetChanged: (Bool) -> Void
    let extras: () -> Extras

    /// Create a draggable section header.
    ///
    /// - Parameters:
    ///   - section: The section this header represents.
    ///   - title: Override for `section.displayName` (e.g., workspace name).
    ///   - dragValue: App-specific `Transferable` value for dragging (compile-time UTType).
    ///   - dropUTTypes: UTTypes to accept on drop.
    ///   - isDropTarget: Whether to show the blue insertion line.
    ///   - isCollapsed: If non-nil, shows a collapse chevron. `nil` = no chevron.
    ///   - onCollapse: Called when the chevron is tapped.
    ///   - onDrop: Drop handler returning whether the drop was accepted.
    ///   - onDropTargetChanged: Called when drop targeting state changes.
    ///   - extras: Additional views in the header (e.g., add button).
    public init(
        section: Section,
        title: String? = nil,
        dragValue: DragValue,
        dropUTTypes: [UTType],
        isDropTarget: Bool,
        isCollapsed: Bool? = nil,
        onCollapse: (() -> Void)? = nil,
        onDrop: @escaping ([NSItemProvider]) -> Bool,
        onDropTargetChanged: @escaping (Bool) -> Void,
        @ViewBuilder extras: @escaping () -> Extras = { EmptyView() }
    ) {
        self.section = section
        self.title = title
        self.dragValue = dragValue
        self.dropUTTypes = dropUTTypes
        self.isDropTarget = isDropTarget
        self.isCollapsed = isCollapsed
        self.onCollapse = onCollapse
        self.onDrop = onDrop
        self.onDropTargetChanged = onDropTargetChanged
        self.extras = extras
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Collapse/expand button (only if isCollapsed is non-nil)
            if let collapsed = isCollapsed {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onCollapse?()
                    }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }

            // Section title
            Text(title ?? section.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            // Additional header content
            extras()
        }
        .contentShape(Rectangle())
        .draggable(dragValue) {
            HStack {
                Image(systemName: section.icon)
                Text(section.displayName)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .onDrop(of: dropUTTypes, isTargeted: dropTargetBinding) { providers in
            onDrop(providers)
        }
        .overlay(alignment: .top) {
            if isDropTarget {
                SectionDropIndicatorLine()
            }
        }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTarget },
            set: { onDropTargetChanged($0) }
        )
    }
}

// MARK: - Convenience (No Extras)

extension DraggableSectionHeader where Extras == EmptyView {
    public init(
        section: Section,
        title: String? = nil,
        dragValue: DragValue,
        dropUTTypes: [UTType],
        isDropTarget: Bool,
        isCollapsed: Bool? = nil,
        onCollapse: (() -> Void)? = nil,
        onDrop: @escaping ([NSItemProvider]) -> Bool,
        onDropTargetChanged: @escaping (Bool) -> Void
    ) {
        self.init(
            section: section,
            title: title,
            dragValue: dragValue,
            dropUTTypes: dropUTTypes,
            isDropTarget: isDropTarget,
            isCollapsed: isCollapsed,
            onCollapse: onCollapse,
            onDrop: onDrop,
            onDropTargetChanged: onDropTargetChanged,
            extras: { EmptyView() }
        )
    }
}

// MARK: - Preview

private enum PreviewSection: String, CaseIterable, Hashable, Codable, Sendable, SidebarSection {
    case libraries, search, flagged

    var displayName: String {
        switch self {
        case .libraries: return "Libraries"
        case .search: return "Search"
        case .flagged: return "Flagged"
        }
    }

    var icon: String {
        switch self {
        case .libraries: return "books.vertical"
        case .search: return "magnifyingglass"
        case .flagged: return "flag.fill"
        }
    }
}

private struct PreviewDragItem: Transferable {
    let section: PreviewSection
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .plainText) { item in
            item.section.rawValue.data(using: .utf8) ?? Data()
        } importing: { data in
            let raw = String(data: data, encoding: .utf8) ?? ""
            return PreviewDragItem(section: PreviewSection(rawValue: raw) ?? .libraries)
        }
    }
}

#Preview("DraggableSectionHeader") {
    VStack(alignment: .leading, spacing: 0) {
        // With collapse chevron
        DraggableSectionHeader(
            section: PreviewSection.libraries,
            dragValue: PreviewDragItem(section: .libraries),
            dropUTTypes: [.plainText],
            isDropTarget: false,
            isCollapsed: false,
            onCollapse: {},
            onDrop: { _ in false },
            onDropTargetChanged: { _ in }
        ) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        // Drop target active
        DraggableSectionHeader(
            section: PreviewSection.search,
            dragValue: PreviewDragItem(section: .search),
            dropUTTypes: [.plainText],
            isDropTarget: true,
            isCollapsed: true,
            onCollapse: {},
            onDrop: { _ in false },
            onDropTargetChanged: { _ in }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        // No collapse (imprint style)
        DraggableSectionHeader(
            section: PreviewSection.flagged,
            title: "Custom Title Override",
            dragValue: PreviewDragItem(section: .flagged),
            dropUTTypes: [.plainText],
            isDropTarget: false,
            onDrop: { _ in false },
            onDropTargetChanged: { _ in }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    .frame(width: 250)
}
