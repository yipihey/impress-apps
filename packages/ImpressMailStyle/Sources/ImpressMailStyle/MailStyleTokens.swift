//
//  MailStyleTokens.swift
//  ImpressMailStyle
//

import SwiftUI

/// Design tokens for Apple Mail-style list rows.
///
/// Defines colors, spacing, fonts, line limits, and date formatting
/// following Apple Mail's visual language.
public enum MailStyleTokens {

    // MARK: - Default Colors

    /// Default blue dot color for unread items
    public static let unreadDotColor = Color.blue

    /// Secondary text color for dates, abstracts, etc.
    public static let secondaryTextColor = Color.secondary

    /// Tertiary text color for metadata like attachment icons
    #if os(macOS)
    public static let tertiaryTextColor = Color(nsColor: .tertiaryLabelColor)
    #else
    public static let tertiaryTextColor = Color(uiColor: .tertiaryLabel)
    #endif

    // MARK: - Theme-Aware Colors

    /// Get unread dot color from color scheme
    public static func unreadDotColor(from scheme: any MailStyleColorScheme) -> Color {
        scheme.unreadDot
    }

    /// Get accent color from color scheme
    public static func accentColor(from scheme: any MailStyleColorScheme) -> Color {
        scheme.accent
    }

    /// Get primary text color from color scheme
    public static func primaryTextColor(from scheme: any MailStyleColorScheme) -> Color {
        scheme.primaryText
    }

    /// Get secondary text color from color scheme
    public static func secondaryTextColor(from scheme: any MailStyleColorScheme) -> Color {
        scheme.secondaryText
    }

    /// Get tertiary text color from color scheme
    public static func tertiaryTextColor(from scheme: any MailStyleColorScheme) -> Color {
        scheme.tertiaryText
    }

    // MARK: - Spacing

    /// Vertical padding for each row
    public static let rowVerticalPadding: CGFloat = 8

    /// Horizontal padding for row content
    public static let rowHorizontalPadding: CGFloat = 12

    /// Size of the unread indicator dot
    public static let unreadDotSize: CGFloat = 10

    /// Spacing between content lines
    public static let contentSpacing: CGFloat = 2

    /// Spacing between dot and content
    public static let dotContentSpacing: CGFloat = 8

    // MARK: - Fonts (Default - use scaled versions with fontScale)

    /// Font for header text when read
    public static let authorFont = Font.system(.body, weight: .semibold)

    /// Font for header text when unread (bolder)
    public static let authorFontUnread = Font.system(.body, weight: .bold)

    /// Font for title
    public static let titleFont = Font.system(.body)

    /// Font for preview text
    public static let abstractFont = Font.system(.subheadline)

    /// Font for date
    public static let dateFont = Font.system(.caption)

    /// Font for attachment indicator
    public static let attachmentFont = Font.system(.caption)

    // MARK: - Scaled Fonts

    /// Base font sizes for scaling
    private static let bodySize: CGFloat = 17
    private static let subheadlineSize: CGFloat = 15
    private static let captionSize: CGFloat = 12

    /// Scaled font for header text when read
    public static func authorFont(scale: Double) -> Font {
        .system(size: bodySize * scale, weight: .semibold)
    }

    /// Scaled font for header text when unread (bolder)
    public static func authorFontUnread(scale: Double) -> Font {
        .system(size: bodySize * scale, weight: .bold)
    }

    /// Scaled font for title
    public static func titleFont(scale: Double) -> Font {
        .system(size: bodySize * scale)
    }

    /// Scaled font for title (serif variant)
    public static func titleFontSerif(scale: Double) -> Font {
        .system(size: bodySize * scale, design: .serif)
    }

    /// Scaled font for preview text
    public static func abstractFont(scale: Double) -> Font {
        .system(size: subheadlineSize * scale)
    }

    /// Scaled font for date
    public static func dateFont(scale: Double) -> Font {
        .system(size: captionSize * scale)
    }

    /// Scaled font for attachment indicator
    public static func attachmentFont(scale: Double) -> Font {
        .system(size: captionSize * scale)
    }

    /// Scaled font for metadata (year, citation count, etc.)
    public static func metadataFont(scale: Double) -> Font {
        .system(size: captionSize * scale)
    }

    // MARK: - Line Limits

    /// Maximum lines for title (nil = unlimited)
    public static let titleLineLimit: Int? = nil

    /// Maximum lines for preview text
    public static let abstractLineLimit = 2

    /// Maximum lines for header text
    public static let authorLineLimit = 1

    // MARK: - Date Formatting

    /// Format a date in Apple Mail style (time/yesterday/weekday/date).
    ///
    /// - Today: "10:30 AM"
    /// - Yesterday: "Yesterday"
    /// - Within past week: "Monday"
    /// - Older: "Jan 5"
    public static func formatRelativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if daysAgo < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }

        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
