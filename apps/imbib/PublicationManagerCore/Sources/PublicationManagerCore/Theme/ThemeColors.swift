//
//  ThemeColors.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI

// MARK: - Theme Colors

/// Resolved theme colors for the current color scheme.
///
/// This struct provides computed colors based on the current theme settings
/// and whether the system is in light or dark mode.
public struct ThemeColors: Sendable {

    // MARK: - Properties

    /// Primary accent color (buttons, links, selected items)
    public let accent: Color

    /// Unread indicator dot color
    public let unreadDot: Color

    /// Sidebar tint color (if applicable)
    public let sidebarTint: Color?

    /// Sidebar tint opacity
    public let sidebarTintOpacity: Double

    /// List background tint color (if applicable)
    public let listBackgroundTint: Color?

    /// List background tint opacity
    public let listBackgroundTintOpacity: Double

    /// Icon tint color for sidebar icons
    public let iconTint: Color

    /// Whether to use serif fonts for titles
    public let useSerifTitles: Bool

    /// The sidebar style
    public let sidebarStyle: SidebarStyle

    // MARK: - Text Colors

    /// Primary text color for titles and main content
    public let primaryText: Color

    /// Secondary text color for metadata, dates, abstracts
    public let secondaryText: Color

    /// Tertiary text color for subtle info (attachment icons)
    public let tertiaryText: Color

    // MARK: - Detail View Colors

    /// Background color for detail view sections (nil = system default)
    public let detailBackground: Color?

    /// Color for clickable links (DOI, arXiv, ADS)
    public let linkColor: Color

    // MARK: - Row Styling

    /// Color for list row separators (nil = system default)
    public let rowSeparator: Color?

    // MARK: - Initialization

    /// Initialize from ThemeSettings respecting current color scheme
    public init(from settings: ThemeSettings, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        let overrides = settings.darkModeOverrides

        // Accent color
        if isDark, let darkAccent = overrides?.accentColorHex {
            self.accent = Color(hex: darkAccent) ?? Color.accentColor
        } else {
            self.accent = Color(hex: settings.accentColorHex) ?? Color.accentColor
        }

        // Unread dot color
        if let dotHex = settings.unreadDotColorHex {
            self.unreadDot = Color(hex: dotHex) ?? self.accent
        } else {
            self.unreadDot = self.accent
        }

        // Sidebar tint
        self.sidebarStyle = settings.sidebarStyle

        if settings.sidebarStyle != .system {
            if isDark, let darkTint = overrides?.sidebarTintHex {
                self.sidebarTint = Color(hex: darkTint)
            } else if let tintHex = settings.sidebarTintHex {
                self.sidebarTint = Color(hex: tintHex)
            } else {
                self.sidebarTint = nil
            }
            self.sidebarTintOpacity = settings.sidebarStyle == .vibrant ? 0.15 : 0.08
        } else {
            self.sidebarTint = nil
            self.sidebarTintOpacity = 0
        }

        // List background tint
        if let listHex = isDark ? overrides?.listBackgroundTintHex ?? settings.listBackgroundTintHex : settings.listBackgroundTintHex {
            self.listBackgroundTint = Color(hex: listHex)
            self.listBackgroundTintOpacity = settings.listBackgroundTintOpacity
        } else {
            self.listBackgroundTint = nil
            self.listBackgroundTintOpacity = 0
        }

        // Icon tint
        if let iconHex = settings.iconColorHex {
            self.iconTint = Color(hex: iconHex) ?? self.accent
        } else {
            self.iconTint = self.accent
        }

        // Typography
        self.useSerifTitles = settings.useSerifTitles

        // Primary text color
        if isDark, let darkPrimary = overrides?.primaryTextColorHex {
            self.primaryText = Color(hex: darkPrimary) ?? ThemeColors.systemPrimaryLabel
        } else if let primaryHex = settings.primaryTextColorHex {
            self.primaryText = Color(hex: primaryHex) ?? ThemeColors.systemPrimaryLabel
        } else {
            self.primaryText = ThemeColors.systemPrimaryLabel
        }

        // Secondary text color
        if isDark, let darkSecondary = overrides?.secondaryTextColorHex {
            self.secondaryText = Color(hex: darkSecondary) ?? Color.secondary
        } else if let secondaryHex = settings.secondaryTextColorHex {
            self.secondaryText = Color(hex: secondaryHex) ?? Color.secondary
        } else {
            self.secondaryText = Color.secondary
        }

        // Tertiary text color
        if isDark, let darkTertiary = overrides?.tertiaryTextColorHex {
            self.tertiaryText = Color(hex: darkTertiary) ?? ThemeColors.systemTertiaryLabel
        } else if let tertiaryHex = settings.tertiaryTextColorHex {
            self.tertiaryText = Color(hex: tertiaryHex) ?? ThemeColors.systemTertiaryLabel
        } else {
            self.tertiaryText = ThemeColors.systemTertiaryLabel
        }

        // Detail background
        if isDark, let darkDetail = overrides?.detailBackgroundColorHex {
            self.detailBackground = Color(hex: darkDetail)
        } else if let detailHex = settings.detailBackgroundColorHex {
            self.detailBackground = Color(hex: detailHex)
        } else {
            self.detailBackground = nil
        }

        // Link color
        if isDark, let darkLink = overrides?.linkColorHex {
            self.linkColor = Color(hex: darkLink) ?? self.accent
        } else if let linkHex = settings.linkColorHex {
            self.linkColor = Color(hex: linkHex) ?? self.accent
        } else {
            self.linkColor = self.accent
        }

        // Row separator
        if let separatorHex = settings.rowSeparatorColorHex {
            self.rowSeparator = Color(hex: separatorHex)
        } else {
            self.rowSeparator = nil
        }
    }

    // MARK: - Platform Helpers

    /// System primary label color (platform-specific)
    private static var systemPrimaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }

    /// System tertiary label color (platform-specific)
    private static var systemTertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    // MARK: - Default

    /// Default theme colors (Mail theme)
    public static let `default` = ThemeColors(from: .mail, colorScheme: .light)
}

// MARK: - Semantic Colors

public extension ThemeColors {

    /// Selected row background with theme accent
    var selectedRowBackground: Color {
        accent.opacity(0.15)
    }

    /// Hover row background with theme accent
    var hoverRowBackground: Color {
        accent.opacity(0.08)
    }

    /// Badge background using theme accent
    var badgeBackground: Color {
        accent.opacity(0.12)
    }

    /// Badge text color
    var badgeText: Color {
        accent
    }

    /// Background color for content areas (notes panels, text editors, etc.)
    ///
    /// Falls back through: detailBackground → listBackgroundTint → system default
    /// Use this for consistent theming across content areas.
    var contentBackground: Color {
        if let detail = detailBackground {
            return detail
        }
        if let tint = listBackgroundTint {
            return tint.opacity(listBackgroundTintOpacity)
        }
        #if os(macOS)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }
}

// MARK: - Font Helpers

public extension ThemeColors {

    /// Title font respecting serif preference
    func titleFont(size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        if useSerifTitles {
            return .system(size: size, weight: weight, design: .serif)
        } else {
            return .system(size: size, weight: weight)
        }
    }

    /// Headline font respecting serif preference
    var headlineFont: Font {
        useSerifTitles ? .system(.headline, design: .serif) : .headline
    }

    /// Subheadline font respecting serif preference
    var subheadlineFont: Font {
        useSerifTitles ? .system(.subheadline, design: .serif) : .subheadline
    }
}
