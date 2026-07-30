//
//  PublicationFlagAndTagsSection.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the ONE Flag & Tags section of the publication Info
//  tab.
//
//  This is the clearest "one surface written twice" in the detail pane: macOS
//  `InfoTab.flagAndTagsSection` and `IOSInfoTab.flagAndTagsSection` were the
//  same `FlagStripe` + the same interpolated
//  "colour · style · length" caption + the same `FlowLayout` of `TagChip`s.
//  They had drifted in exactly the two ways an un-shared view drifts:
//
//  * macOS sorted the tags by path, iOS rendered them in store order (so the
//    same paper listed its tags in a different order on each platform);
//  * macOS showed the FULL tag path (`.full`) and made each chip a filter
//    gesture, iOS showed leaf names only and the chips were inert.
//
//  The shared view keeps macOS's rendering verbatim (it is the frozen surface)
//  and lets the host decide whether a chip is a gesture, because "tapping a tag
//  activates the filter bar" is a capability of the LIST pane the host owns,
//  not of the tag.
//

import SwiftUI
import ImpressFTUI

/// Flag stripe + tag chips for one publication. Renders NOTHING when the paper
/// has neither (no header, no divider) — the behaviour both copies had.
public struct PublicationFlagAndTagsSection: View {

    private let flag: PublicationFlag?
    private let tags: [TagDisplayData]
    private let tagPathStyle: TagPathStyle
    private let onTagTap: ((String) -> Void)?

    /// - Parameters:
    ///   - onTagTap: called with the tag PATH when a chip is tapped. `nil`
    ///     (the default) renders inert chips — the `RecordTriageNewTagPrompt`
    ///     rule: omit the affordance rather than ship a dead one.
    public init(
        flag: PublicationFlag?,
        tags: [TagDisplayData],
        tagPathStyle: TagPathStyle = .full,
        onTagTap: ((String) -> Void)? = nil
    ) {
        self.flag = flag
        self.tags = tags
        self.tagPathStyle = tagPathStyle
        self.onTagTap = onTagTap
    }

    public init(
        publication: PublicationModel,
        tagPathStyle: TagPathStyle = .full,
        onTagTap: ((String) -> Void)? = nil
    ) {
        self.init(
            flag: publication.flag, tags: publication.tags,
            tagPathStyle: tagPathStyle, onTagTap: onTagTap)
    }

    /// Sorted by path — one ordering for both platforms.
    private var sortedTags: [TagDisplayData] {
        tags.sorted { $0.path < $1.path }
    }

    public var body: some View {
        let hasFlag = flag != nil
        let hasTags = !tags.isEmpty

        if hasFlag || hasTags {
            VStack(alignment: .leading, spacing: 8) {
                if let flag {
                    HStack(spacing: 6) {
                        FlagStripe(flag: flag, rowHeight: 16)
                        Text("\(flag.color.displayName) · \(flag.style.displayName) · \(flag.length.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasTags {
                    FlowLayout(spacing: 4) {
                        ForEach(sortedTags, id: \.id) { tag in
                            tagChip(tag)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tagChip(_ tag: TagDisplayData) -> some View {
        if let onTagTap {
            TagChip(tag: tag, pathStyle: tagPathStyle)
                .contentShape(Rectangle())
                .onTapGesture { onTagTap(tag.path) }
                .help("Click to filter by tags:\(tag.path)")
        } else {
            TagChip(tag: tag, pathStyle: tagPathStyle)
        }
    }
}
