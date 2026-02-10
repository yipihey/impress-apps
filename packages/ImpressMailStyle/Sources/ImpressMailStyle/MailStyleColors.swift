//
//  MailStyleColors.swift
//  ImpressMailStyle
//

import SwiftUI

/// Protocol for the color palette used by ``MailStyleRow``.
///
/// Apps provide their own implementation to bridge their theme system.
/// For example, imbib bridges `ThemeColors` to this protocol.
public protocol MailStyleColorScheme: Sendable {
    /// Primary text color for titles and main content
    var primaryText: Color { get }

    /// Secondary text color for metadata, dates, previews
    var secondaryText: Color { get }

    /// Tertiary text color for subtle info (attachment icons)
    var tertiaryText: Color { get }

    /// Accent color for highlights and interactive elements
    var accent: Color { get }

    /// Unread indicator dot color
    var unreadDot: Color { get }
}

/// Default color scheme using system colors.
public struct DefaultMailStyleColors: MailStyleColorScheme, Sendable {
    public var primaryText: Color { .primary }
    public var secondaryText: Color { .secondary }
    public var tertiaryText: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }
    public var accent: Color { .accentColor }
    public var unreadDot: Color { .blue }

    public init() {}
}
