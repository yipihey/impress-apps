//
//  MailStyleRow.swift
//  ImpressMailStyle
//

import SwiftUI
import ImpressFTUI

/// A generic mail-style list row that renders any ``MailStyleItem``.
///
/// Handles visual rendering only. Domain-specific behavior (context menus,
/// swipe actions, drag/drop, triage) is applied by the consuming app as
/// view modifiers.
///
/// The `TrailingHeader` view builder lets apps inject custom content into
/// the header row (e.g., recommendation scores, citation counts).
///
/// ## Usage
///
/// ```swift
/// MailStyleRow(item: publication, configuration: settings.mailStyleConfiguration) {
///     // Optional trailing header content
///     Image(systemName: "sparkles")
/// }
/// ```
public struct MailStyleRow<Item: MailStyleItem, TrailingHeader: View>: View {

    @Environment(\.mailStyleColors) private var colors
    @Environment(\.mailStyleFontScale) private var fontScale

    public let item: Item
    public var configuration: MailStyleRowConfiguration
    private let trailingHeaderContent: () -> TrailingHeader

    public init(
        item: Item,
        configuration: MailStyleRowConfiguration = .default,
        @ViewBuilder trailingHeader: @escaping () -> TrailingHeader = { EmptyView() }
    ) {
        self.item = item
        self.configuration = configuration
        self.trailingHeaderContent = trailingHeader
    }

    private var isUnread: Bool { !item.isRead }

    public var body: some View {
        HStack(alignment: .top, spacing: MailStyleTokens.dotContentSpacing) {
            // Flag stripe (leading edge)
            if configuration.showFlagStripe {
                FlagStripe(flag: item.flag, rowHeight: 44)
            }

            // Indicators column: unread dot and star
            if configuration.showUnreadIndicator {
                VStack(spacing: 2) {
                    Circle()
                        .fill(isUnread ? MailStyleTokens.unreadDotColor(from: colors) : .clear)
                        .frame(
                            width: MailStyleTokens.unreadDotSize,
                            height: MailStyleTokens.unreadDotSize
                        )

                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10 * fontScale))
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.top, 6)
            }

            // Content
            VStack(alignment: .leading, spacing: configuration.density.contentSpacing) {
                // Row 1: Header text + Spacer + Date + Trailing badge + Trailing header
                HStack {
                    Text(item.headerText)
                        .font(isUnread ? MailStyleTokens.authorFontUnread(scale: fontScale) : MailStyleTokens.authorFont(scale: fontScale))
                        .foregroundStyle(MailStyleTokens.primaryTextColor(from: colors))
                        .lineLimit(MailStyleTokens.authorLineLimit)

                    Spacer()

                    if configuration.showDate {
                        Text(MailStyleTokens.formatRelativeDate(item.date))
                            .font(MailStyleTokens.dateFont(scale: fontScale))
                            .foregroundStyle(MailStyleTokens.secondaryTextColor(from: colors))
                    }

                    trailingHeaderContent()

                    if configuration.showTrailingBadge, let badge = item.trailingBadgeText {
                        Text(badge)
                            .font(MailStyleTokens.dateFont(scale: fontScale))
                            .foregroundStyle(MailStyleTokens.secondaryTextColor(from: colors))
                    }
                }

                // Row 2: Title
                if configuration.showTitle {
                    Text(item.titleText)
                        .font(MailStyleTokens.titleFont(scale: fontScale))
                        .fontWeight(isUnread ? .medium : .regular)
                        .foregroundStyle(MailStyleTokens.primaryTextColor(from: colors))
                        .lineLimit(configuration.titleLineLimit)
                }

                // Row 2.5: Subtitle
                if configuration.showSubtitle, let subtitle = item.subtitleText, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MailStyleTokens.abstractFont(scale: fontScale))
                        .foregroundStyle(MailStyleTokens.secondaryTextColor(from: colors))
                        .lineLimit(1)
                }

                // Row 2.7: Tags
                if !item.tagDisplays.isEmpty {
                    TagLine(tags: item.tagDisplays, style: configuration.tagDisplayStyle, pathStyle: configuration.tagPathStyle)
                }

                // Row 3: Attachment indicators + Preview text
                let hasAttachments = item.hasAttachment || item.hasSecondaryAttachment
                if (configuration.showAttachmentIndicator && hasAttachments) || configuration.previewLineLimit > 0 {
                    HStack(spacing: 4) {
                        if configuration.showAttachmentIndicator {
                            if item.hasAttachment {
                                Image(systemName: "paperclip")
                                    .font(MailStyleTokens.attachmentFont(scale: fontScale))
                                    .foregroundStyle(MailStyleTokens.tertiaryTextColor(from: colors))
                            }
                            if item.hasSecondaryAttachment {
                                Image(systemName: "doc.fill")
                                    .font(MailStyleTokens.attachmentFont(scale: fontScale))
                                    .foregroundStyle(MailStyleTokens.tertiaryTextColor(from: colors))
                            }
                        }

                        if configuration.previewLineLimit > 0, let preview = item.previewText, !preview.isEmpty {
                            Text(String(preview.prefix(300)))
                                .font(MailStyleTokens.abstractFont(scale: fontScale))
                                .foregroundStyle(MailStyleTokens.secondaryTextColor(from: colors))
                                .lineLimit(configuration.previewLineLimit)
                        }
                    }
                }
            }
        }
        .padding(.vertical, configuration.density.rowPadding)
        .contentShape(Rectangle())
    }
}

// MARK: - Equatable

extension MailStyleRow: Equatable where Item: Equatable, TrailingHeader == EmptyView {
    public static func == (lhs: MailStyleRow, rhs: MailStyleRow) -> Bool {
        lhs.item == rhs.item && lhs.configuration == rhs.configuration
    }
}
