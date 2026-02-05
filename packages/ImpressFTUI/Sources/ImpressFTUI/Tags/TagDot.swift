//
//  TagDot.swift
//  ImpressFTUI
//

import SwiftUI

/// An 8pt colored circle representing a tag in compact display.
public struct TagDot: View {

    public let tag: TagDisplayData

    @Environment(\.colorScheme) private var colorScheme

    public init(tag: TagDisplayData) {
        self.tag = tag
    }

    public var body: some View {
        Circle()
            .fill(resolvedColor)
            .frame(width: 8, height: 8)
            .help(tag.path)
    }

    private var resolvedColor: Color {
        if let color = tag.resolvedColor(for: colorScheme) {
            return color
        }
        let defaults = defaultTagColor(for: tag.path)
        return Color(hex: colorScheme == .dark ? defaults.dark : defaults.light)
    }
}
