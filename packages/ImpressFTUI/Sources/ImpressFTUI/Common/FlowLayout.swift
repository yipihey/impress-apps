//
//  FlowLayout.swift
//  ImpressFTUI
//
//  A layout that arranges views horizontally and wraps to new lines as needed.
//

import SwiftUI

/// A layout that arranges views horizontally and wraps to new lines as needed.
/// Useful for tag chips, badges, and other inline elements.
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = subviews.map { measured($0, containerWidth: width) }
        return layout(sizes: sizes.map(\.size), containerWidth: width).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { measured($0, containerWidth: bounds.width) }
        let offsets = layout(sizes: sizes.map(\.size), containerWidth: bounds.width).offsets

        for (index, (subview, offset)) in zip(subviews, offsets).enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: sizes[index].proposal
            )
        }
    }

    /// Wrapping only breaks BETWEEN subviews, so a single subview wider than
    /// the container would be placed at its ideal width and overflow the
    /// layout's bounds (seen live: one long oMLX model-name chip pushing its
    /// remove button past the sheet edge). Clamp such a subview to the
    /// container width and hand it that same proposal at placement, so its
    /// content truncates instead of escaping.
    private func measured(
        _ subview: LayoutSubviews.Element, containerWidth: CGFloat
    ) -> (size: CGSize, proposal: ProposedViewSize) {
        var size = subview.sizeThatFits(.unspecified)
        guard containerWidth.isFinite, size.width > containerWidth else {
            return (size, .unspecified)
        }
        let clamped = ProposedViewSize(width: containerWidth, height: nil)
        size = subview.sizeThatFits(clamped)
        size.width = min(size.width, containerWidth)
        return (size, clamped)
    }

    private func layout(sizes: [CGSize], containerWidth: CGFloat) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for size in sizes {
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return (offsets, CGSize(width: maxWidth, height: currentY + lineHeight))
    }
}
