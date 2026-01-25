//
//  AnnotationToolbar.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI

// MARK: - Annotation Tool

/// Available annotation tools
public enum AnnotationTool: String, CaseIterable, Identifiable {
    case highlight
    case underline
    case strikethrough
    case textNote

    public var id: String { rawValue }

    /// SF Symbol name for this tool
    public var iconName: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .textNote: return "note.text"
        }
    }

    /// Display name for tooltips
    public var displayName: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .textNote: return "Add Note"
        }
    }

    /// Keyboard shortcut hint
    public var shortcutHint: String {
        switch self {
        case .highlight: return "H"
        case .underline: return "U"
        case .strikethrough: return "S"
        case .textNote: return "N"
        }
    }
}

// MARK: - Toolbar Position

/// Position where the annotation toolbar is docked
public enum AnnotationToolbarPosition: String, CaseIterable {
    case top
    case bottom
    case left
    case right

    /// Whether this position uses vertical layout
    var isVertical: Bool {
        self == .left || self == .right
    }

    /// Next position in cycle (for repositioning)
    var next: AnnotationToolbarPosition {
        switch self {
        case .top: return .right
        case .right: return .bottom
        case .bottom: return .left
        case .left: return .top
        }
    }

    /// Alignment for positioning within parent
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
}

// MARK: - Collapsible Annotation Toolbar

/// Collapsible, movable annotation toolbar for PDF viewing.
///
/// Features:
/// - Collapsed state shows only pencil icon
/// - Expanded state shows all annotation tools
/// - Can be positioned on any edge (top, bottom, left, right)
/// - Position persisted via UserDefaults
public struct AnnotationToolbar: View {

    // MARK: - Properties

    @Binding public var selectedTool: AnnotationTool?
    @Binding public var highlightColor: HighlightColor
    public var hasSelection: Bool
    public var onHighlight: () -> Void
    public var onUnderline: () -> Void
    public var onStrikethrough: () -> Void
    public var onAddNote: () -> Void

    // Persisted state
    @AppStorage("annotationToolbarExpanded") private var isExpanded: Bool = false
    @AppStorage("annotationToolbarPosition") private var positionRaw: String = AnnotationToolbarPosition.top.rawValue

    private var position: AnnotationToolbarPosition {
        get { AnnotationToolbarPosition(rawValue: positionRaw) ?? .top }
        set { positionRaw = newValue.rawValue }
    }

    // MARK: - Initialization

    public init(
        selectedTool: Binding<AnnotationTool?>,
        highlightColor: Binding<HighlightColor>,
        hasSelection: Bool,
        onHighlight: @escaping () -> Void,
        onUnderline: @escaping () -> Void,
        onStrikethrough: @escaping () -> Void,
        onAddNote: @escaping () -> Void
    ) {
        self._selectedTool = selectedTool
        self._highlightColor = highlightColor
        self.hasSelection = hasSelection
        self.onHighlight = onHighlight
        self.onUnderline = onUnderline
        self.onStrikethrough = onStrikethrough
        self.onAddNote = onAddNote
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if isExpanded {
                expandedToolbar
            } else {
                collapsedToolbar
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // MARK: - Collapsed Toolbar

    private var collapsedToolbar: some View {
        Button {
            withAnimation {
                isExpanded = true
            }
        } label: {
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        .help("Show annotation tools")
    }

    // MARK: - Expanded Toolbar

    private var expandedToolbar: some View {
        let isVertical = position.isVertical

        return Group {
            if isVertical {
                VStack(spacing: 8) {
                    toolbarContent(vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    toolbarContent(vertical: false)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }

    // MARK: - Toolbar Content

    @ViewBuilder
    private func toolbarContent(vertical: Bool) -> some View {
        // Collapse button
        Button {
            withAnimation {
                isExpanded = false
            }
        } label: {
            Image(systemName: "pencil.tip.crop.circle.fill")
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Hide annotation tools")

        divider(vertical: vertical)

        // Highlight with color menu
        highlightButton

        // Underline
        toolButton(tool: .underline, action: onUnderline)

        // Strikethrough
        toolButton(tool: .strikethrough, action: onStrikethrough)

        // Text note
        toolButton(tool: .textNote, action: onAddNote)

        divider(vertical: vertical)

        // Color picker
        colorPicker(vertical: vertical)

        divider(vertical: vertical)

        // Position button
        Button {
            withAnimation {
                positionRaw = position.next.rawValue
            }
        } label: {
            Image(systemName: positionIcon)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Move toolbar to \(position.next.rawValue) edge")
    }

    @ViewBuilder
    private func divider(vertical: Bool) -> some View {
        if vertical {
            Divider()
                .frame(width: 20)
        } else {
            Divider()
                .frame(height: 20)
        }
    }

    private var positionIcon: String {
        switch position {
        case .top: return "arrow.right"
        case .right: return "arrow.down"
        case .bottom: return "arrow.left"
        case .left: return "arrow.up"
        }
    }

    // MARK: - Highlight Button

    private var highlightButton: some View {
        Menu {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button {
                    highlightColor = color
                    onHighlight()
                } label: {
                    Label(color.displayName, systemImage: "circle.fill")
                }
            }
        } label: {
            Image(systemName: "highlighter")
                .font(.system(size: 16))
                .foregroundStyle(Color(highlightColor.platformColor))
                .frame(width: 28, height: 28)
        } primaryAction: {
            onHighlight()
        }
        .buttonStyle(.plain)
        .help("Highlight selection (\(AnnotationTool.highlight.shortcutHint))")
        .disabled(!hasSelection)
        .opacity(hasSelection ? 1.0 : 0.5)
    }

    // MARK: - Tool Button

    private func toolButton(tool: AnnotationTool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: tool.iconName)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("\(tool.displayName) (\(tool.shortcutHint))")
        .disabled(tool != .textNote && !hasSelection)
        .opacity((tool != .textNote && !hasSelection) ? 0.5 : 1.0)
    }

    // MARK: - Color Picker

    @ViewBuilder
    private func colorPicker(vertical: Bool) -> some View {
        let colors = HighlightColor.allCases

        if vertical {
            VStack(spacing: 4) {
                ForEach(colors, id: \.self) { color in
                    colorCircle(color)
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(colors, id: \.self) { color in
                    colorCircle(color)
                }
            }
        }
    }

    private func colorCircle(_ color: HighlightColor) -> some View {
        Circle()
            .fill(Color(color.platformColor))
            .frame(width: 16, height: 16)
            .overlay {
                if color == highlightColor {
                    Circle()
                        .stroke(Color.primary, lineWidth: 2)
                }
            }
            .onTapGesture {
                highlightColor = color
            }
    }
}

// MARK: - Selection Context Menu

/// Compact context menu that appears near text selections in the PDF viewer.
/// Provides quick access to annotation tools.
public struct SelectionContextMenu: View {

    // MARK: - Properties

    public var onHighlight: (HighlightColor) -> Void
    public var onUnderline: () -> Void
    public var onStrikethrough: () -> Void
    public var onAddNote: () -> Void
    public var onCopy: () -> Void

    // MARK: - Initialization

    public init(
        onHighlight: @escaping (HighlightColor) -> Void,
        onUnderline: @escaping () -> Void,
        onStrikethrough: @escaping () -> Void,
        onAddNote: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        self.onHighlight = onHighlight
        self.onUnderline = onUnderline
        self.onStrikethrough = onStrikethrough
        self.onAddNote = onAddNote
        self.onCopy = onCopy
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 8) {
            // Quick highlight buttons - most common colors
            ForEach([HighlightColor.yellow, .green, .blue], id: \.self) { color in
                Button {
                    onHighlight(color)
                } label: {
                    Circle()
                        .fill(Color(color.platformColor))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 24)

            // Underline
            Button(action: onUnderline) {
                Image(systemName: "underline")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            // Strikethrough
            Button(action: onStrikethrough) {
                Image(systemName: "strikethrough")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            // Add note
            Button(action: onAddNote) {
                Image(systemName: "note.text")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 24)

            // Copy
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Preview

#Preview("Annotation Toolbar") {
    VStack(spacing: 40) {
        AnnotationToolbar(
            selectedTool: .constant(nil),
            highlightColor: .constant(.yellow),
            hasSelection: true,
            onHighlight: {},
            onUnderline: {},
            onStrikethrough: {},
            onAddNote: {}
        )

        AnnotationToolbar(
            selectedTool: .constant(.highlight),
            highlightColor: .constant(.green),
            hasSelection: false,
            onHighlight: {},
            onUnderline: {},
            onStrikethrough: {},
            onAddNote: {}
        )

        SelectionContextMenu(
            onHighlight: { _ in },
            onUnderline: {},
            onStrikethrough: {},
            onAddNote: {},
            onCopy: {}
        )
    }
    .padding()
}
