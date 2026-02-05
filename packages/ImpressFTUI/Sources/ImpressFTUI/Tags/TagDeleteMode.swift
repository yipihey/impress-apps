//
//  TagDeleteMode.swift
//  ImpressFTUI
//

import SwiftUI

/// Keyboard-navigable chip list for removing tags from a publication.
///
/// - ← / → to move selection
/// - d to delete the selected tag
/// - ESC to cancel
public struct TagDeleteMode: View {

    @Binding public var isPresented: Bool
    public let tags: [TagDisplayData]
    public var onRemoveTag: ((UUID) -> Void)?
    public var onCancel: (() -> Void)?

    @State private var selectedIndex: Int = 0

    public init(
        isPresented: Binding<Bool>,
        tags: [TagDisplayData],
        onRemoveTag: ((UUID) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.tags = tags
        self.onRemoveTag = onRemoveTag
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 6) {
            ModeIndicator("TAG DEL", color: .red)

            if tags.isEmpty {
                Text("No tags")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        TagChip(tag: tag, isSelected: index == selectedIndex)
                    }
                }
            }

            Text("←/→ move, d delete, ESC cancel")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .focusable()
        .onKeyPress(.leftArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.init("d")) {
            deleteSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func moveSelection(by offset: Int) {
        guard !tags.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + tags.count) % tags.count
    }

    private func deleteSelected() {
        guard !tags.isEmpty, selectedIndex < tags.count else { return }
        let tagID = tags[selectedIndex].id
        onRemoveTag?(tagID)
        if tags.count <= 1 {
            dismiss()
        } else if selectedIndex >= tags.count - 1 {
            selectedIndex = max(0, tags.count - 2)
        }
    }

    private func dismiss() {
        isPresented = false
        onCancel?()
    }
}
