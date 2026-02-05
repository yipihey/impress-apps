//
//  TagChip.swift
//  ImpressFTUI
//

import SwiftUI

/// A tag rendered as a label with colored background.
///
/// Used in tag delete mode for selectable chip display and in text/hybrid tag display.
public struct TagChip: View {

    public let tag: TagDisplayData
    public var isSelected: Bool = false
    public var pathStyle: TagPathStyle = .leafOnly

    @Environment(\.colorScheme) private var colorScheme

    public init(tag: TagDisplayData, isSelected: Bool = false, pathStyle: TagPathStyle = .leafOnly) {
        self.tag = tag
        self.isSelected = isSelected
        self.pathStyle = pathStyle
    }

    public var body: some View {
        Text(displayText)
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(resolvedColor, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white, lineWidth: 2)
                }
            }
    }

    private var displayText: String {
        switch pathStyle {
        case .full:
            return tag.path
        case .leafOnly:
            return tag.leaf
        case .truncated:
            let segments = tag.path.components(separatedBy: "/")
            if segments.count <= 2 {
                return tag.path
            }
            return ".../" + segments.suffix(2).joined(separator: "/")
        }
    }

    private var resolvedColor: Color {
        if let color = tag.resolvedColor(for: colorScheme) {
            return color
        }
        let defaults = defaultTagColor(for: tag.path)
        return Color(hex: colorScheme == .dark ? defaults.dark : defaults.light)
    }
}
