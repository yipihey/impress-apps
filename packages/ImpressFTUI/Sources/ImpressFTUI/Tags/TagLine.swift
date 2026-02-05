//
//  TagLine.swift
//  ImpressFTUI
//

import SwiftUI

/// A horizontal row of tag indicators (dots, chips, or hybrid) with overflow count.
public struct TagLine: View {

    public let tags: [TagDisplayData]
    public var style: TagDisplayStyle = .default
    public var pathStyle: TagPathStyle = .leafOnly

    public init(tags: [TagDisplayData], style: TagDisplayStyle = .default, pathStyle: TagPathStyle = .leafOnly) {
        self.tags = tags
        self.style = style
        self.pathStyle = pathStyle
    }

    public var body: some View {
        switch style {
        case .hidden:
            EmptyView()

        case .dots(let maxVisible):
            dotsView(maxVisible: maxVisible)

        case .text:
            textView()

        case .hybrid(let maxVisible):
            hybridView(maxVisible: maxVisible)
        }
    }

    @ViewBuilder
    private func dotsView(maxVisible: Int) -> some View {
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags.prefix(maxVisible)) { tag in
                    TagDot(tag: tag)
                }
                if tags.count > maxVisible {
                    Text("+\(tags.count - maxVisible)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func textView() -> some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    TagChip(tag: tag, pathStyle: pathStyle)
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func hybridView(maxVisible: Int) -> some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                // Show first 2 tags as text labels
                ForEach(tags.prefix(2)) { tag in
                    TagChip(tag: tag, pathStyle: pathStyle)
                }
                // Show remaining as dots
                let remaining = Array(tags.dropFirst(2))
                if !remaining.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(remaining.prefix(maxVisible)) { tag in
                            TagDot(tag: tag)
                        }
                        let overflowCount = remaining.count - min(remaining.count, maxVisible)
                        if overflowCount > 0 {
                            Text("+\(overflowCount)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
