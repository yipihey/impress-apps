//
//  ThemeSettings.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import Foundation
import SwiftUI

// MARK: - Appearance Mode

/// User preference for color scheme
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system     // Follow system settings
    case light      // Always light mode
    case dark       // Always dark mode

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Convert to SwiftUI ColorScheme (nil = system)
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Theme ID

/// Identifier for predefined themes
public enum ThemeID: String, Codable, CaseIterable, Sendable {
    case mail           // Default (Apple Mail-like)
    case academicBlue   // Deep scholarly blue
    case scholarGreen   // Library/academic green
    case journalGray    // Neutral professional
    case arXivRed       // arXiv-inspired burgundy
    case citation       // Warm amber/gold
    case custom         // User-defined

    public var displayName: String {
        switch self {
        case .mail: return "Mail"
        case .academicBlue: return "Academic Blue"
        case .scholarGreen: return "Scholar Green"
        case .journalGray: return "Journal Gray"
        case .arXivRed: return "arXiv Red"
        case .citation: return "Citation"
        case .custom: return "Custom"
        }
    }

    public var description: String {
        switch self {
        case .mail: return "Familiar system appearance"
        case .academicBlue: return "Deep scholarly blue"
        case .scholarGreen: return "Calm library green"
        case .journalGray: return "Focused and neutral"
        case .arXivRed: return "Bold preprint style"
        case .citation: return "Warm classic amber"
        case .custom: return "Your custom colors"
        }
    }
}

// MARK: - Sidebar Style

/// Sidebar appearance style
public enum SidebarStyle: String, Codable, CaseIterable, Sendable {
    case system     // Default macOS/iOS sidebar
    case tinted     // Custom tint color
    case vibrant    // More prominent tint

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .tinted: return "Tinted"
        case .vibrant: return "Vibrant"
        }
    }
}

// MARK: - Dark Mode Overrides

/// Optional color overrides for dark mode
public struct DarkModeOverrides: Codable, Equatable, Sendable {
    public var accentColorHex: String?
    public var sidebarTintHex: String?
    public var listBackgroundTintHex: String?
    public var primaryTextColorHex: String?
    public var secondaryTextColorHex: String?
    public var tertiaryTextColorHex: String?
    public var detailBackgroundColorHex: String?
    public var linkColorHex: String?

    public init(
        accentColorHex: String? = nil,
        sidebarTintHex: String? = nil,
        listBackgroundTintHex: String? = nil,
        primaryTextColorHex: String? = nil,
        secondaryTextColorHex: String? = nil,
        tertiaryTextColorHex: String? = nil,
        detailBackgroundColorHex: String? = nil,
        linkColorHex: String? = nil
    ) {
        self.accentColorHex = accentColorHex
        self.sidebarTintHex = sidebarTintHex
        self.listBackgroundTintHex = listBackgroundTintHex
        self.primaryTextColorHex = primaryTextColorHex
        self.secondaryTextColorHex = secondaryTextColorHex
        self.tertiaryTextColorHex = tertiaryTextColorHex
        self.detailBackgroundColorHex = detailBackgroundColorHex
        self.linkColorHex = linkColorHex
    }
}

// MARK: - Theme Settings

/// Complete theme configuration
public struct ThemeSettings: Codable, Equatable, Sendable {

    // MARK: - Theme Identity

    /// Unique identifier for the theme
    public var themeID: ThemeID

    /// Whether using a custom theme vs predefined
    public var isCustom: Bool

    // MARK: - Accent Colors

    /// Primary accent color (buttons, links, selected items)
    public var accentColorHex: String

    /// Unread indicator dot color (defaults to accent if not set)
    public var unreadDotColorHex: String?

    // MARK: - Sidebar Appearance

    /// Sidebar tint/background style
    public var sidebarStyle: SidebarStyle

    /// Custom sidebar tint color (only used when sidebarStyle == .tinted or .vibrant)
    public var sidebarTintHex: String?

    // MARK: - List Appearance

    /// Subtle background tint for the publication list
    public var listBackgroundTintHex: String?

    /// Opacity of list background tint (0.0-0.1 range)
    public var listBackgroundTintOpacity: Double

    // MARK: - Text Colors

    /// Primary text color for titles and main content
    public var primaryTextColorHex: String?

    /// Secondary text color for metadata, dates, abstracts
    public var secondaryTextColorHex: String?

    /// Tertiary text color for subtle info (attachment icons)
    public var tertiaryTextColorHex: String?

    // MARK: - Detail View Colors

    /// Background color for detail view sections
    public var detailBackgroundColorHex: String?

    /// Color for clickable links (DOI, arXiv, ADS)
    public var linkColorHex: String?

    // MARK: - Row Styling

    /// Color for list row separators/dividers
    public var rowSeparatorColorHex: String?

    // MARK: - Typography

    /// Use serif fonts for titles (academic feel)
    public var useSerifTitles: Bool

    /// Font size scale factor (0.85 = smaller, 1.0 = default, 1.15 = larger)
    /// Valid range: 0.7 to 1.4
    public var fontScale: Double

    // MARK: - Icon Style

    /// Icon accent color for sidebar icons
    public var iconColorHex: String?

    // MARK: - Light/Dark Mode Handling

    /// Separate color overrides for dark mode (nil = auto-adjust)
    public var darkModeOverrides: DarkModeOverrides?

    /// User's preferred color scheme (system/light/dark)
    public var appearanceMode: AppearanceMode

    // MARK: - Initialization

    public init(
        themeID: ThemeID,
        isCustom: Bool = false,
        accentColorHex: String,
        unreadDotColorHex: String? = nil,
        sidebarStyle: SidebarStyle = .system,
        sidebarTintHex: String? = nil,
        listBackgroundTintHex: String? = nil,
        listBackgroundTintOpacity: Double = 0,
        primaryTextColorHex: String? = nil,
        secondaryTextColorHex: String? = nil,
        tertiaryTextColorHex: String? = nil,
        detailBackgroundColorHex: String? = nil,
        linkColorHex: String? = nil,
        rowSeparatorColorHex: String? = nil,
        useSerifTitles: Bool = false,
        fontScale: Double = 1.0,
        iconColorHex: String? = nil,
        darkModeOverrides: DarkModeOverrides? = nil,
        appearanceMode: AppearanceMode = .system
    ) {
        self.themeID = themeID
        self.isCustom = isCustom
        self.accentColorHex = accentColorHex
        self.unreadDotColorHex = unreadDotColorHex
        self.sidebarStyle = sidebarStyle
        self.sidebarTintHex = sidebarTintHex
        self.listBackgroundTintHex = listBackgroundTintHex
        self.listBackgroundTintOpacity = listBackgroundTintOpacity
        self.primaryTextColorHex = primaryTextColorHex
        self.secondaryTextColorHex = secondaryTextColorHex
        self.tertiaryTextColorHex = tertiaryTextColorHex
        self.detailBackgroundColorHex = detailBackgroundColorHex
        self.linkColorHex = linkColorHex
        self.rowSeparatorColorHex = rowSeparatorColorHex
        self.useSerifTitles = useSerifTitles
        self.fontScale = max(0.7, min(1.4, fontScale))  // Clamp to valid range
        self.iconColorHex = iconColorHex
        self.darkModeOverrides = darkModeOverrides
        self.appearanceMode = appearanceMode
    }

    public static let `default` = ThemeSettings.mail
}

// MARK: - Predefined Themes

public extension ThemeSettings {

    /// Get predefined theme by ID
    static func predefined(_ id: ThemeID) -> ThemeSettings {
        switch id {
        case .mail: return .mail
        case .academicBlue: return .academicBlue
        case .scholarGreen: return .scholarGreen
        case .journalGray: return .journalGray
        case .arXivRed: return .arXivRed
        case .citation: return .citation
        case .custom: return .mail  // Start from mail for custom
        }
    }

    // MARK: - Mail (Default)

    /// Default theme - familiar Apple Mail-like appearance
    static let mail = ThemeSettings(
        themeID: .mail,
        isCustom: false,
        accentColorHex: "#007AFF",  // System blue
        unreadDotColorHex: nil,      // Uses accent
        sidebarStyle: .system,
        sidebarTintHex: nil,
        listBackgroundTintHex: nil,
        listBackgroundTintOpacity: 0,
        secondaryTextColorHex: nil,  // System default
        tertiaryTextColorHex: nil,   // System default
        detailBackgroundColorHex: nil,
        linkColorHex: nil,           // Uses accent
        rowSeparatorColorHex: nil,
        useSerifTitles: false,
        iconColorHex: nil,
        darkModeOverrides: nil
    )

    // MARK: - Academic Blue

    /// Deep scholarly blue, reminiscent of university crests
    static let academicBlue = ThemeSettings(
        themeID: .academicBlue,
        isCustom: false,
        accentColorHex: "#1E4B8E",  // Deep academic blue
        unreadDotColorHex: "#2563EB", // Brighter blue dot
        sidebarStyle: .tinted,
        sidebarTintHex: "#1E4B8E",
        listBackgroundTintHex: "#E8F0FE",
        listBackgroundTintOpacity: 0.05,
        secondaryTextColorHex: "#374151",  // Slate gray
        tertiaryTextColorHex: "#6B7280",   // Medium gray
        detailBackgroundColorHex: "#F0F4F8",
        linkColorHex: "#1E4B8E",
        rowSeparatorColorHex: "#CBD5E1",
        useSerifTitles: true,
        iconColorHex: "#1E4B8E",
        darkModeOverrides: DarkModeOverrides(
            accentColorHex: "#5B9AFF",
            sidebarTintHex: "#1E3A5F",
            listBackgroundTintHex: "#1E3A5F",
            secondaryTextColorHex: "#9CA3AF",
            tertiaryTextColorHex: "#6B7280",
            detailBackgroundColorHex: "#1E293B",
            linkColorHex: "#5B9AFF"
        )
    )

    // MARK: - Scholar Green

    /// Library/research green, professional and calming
    static let scholarGreen = ThemeSettings(
        themeID: .scholarGreen,
        isCustom: false,
        accentColorHex: "#166534",  // Deep forest green
        unreadDotColorHex: "#22C55E", // Bright green dot
        sidebarStyle: .tinted,
        sidebarTintHex: "#166534",
        listBackgroundTintHex: "#DCFCE7",
        listBackgroundTintOpacity: 0.04,
        secondaryTextColorHex: "#374151",  // Slate gray
        tertiaryTextColorHex: "#6B7280",   // Medium gray
        detailBackgroundColorHex: "#F0FDF4",
        linkColorHex: "#166534",
        rowSeparatorColorHex: "#BBF7D0",
        useSerifTitles: true,
        iconColorHex: "#166534",
        darkModeOverrides: DarkModeOverrides(
            accentColorHex: "#4ADE80",
            sidebarTintHex: "#14432A",
            listBackgroundTintHex: "#14432A",
            secondaryTextColorHex: "#9CA3AF",
            tertiaryTextColorHex: "#6B7280",
            detailBackgroundColorHex: "#14532D",
            linkColorHex: "#4ADE80"
        )
    )

    // MARK: - Journal Gray

    /// Neutral, sophisticated, distraction-free
    static let journalGray = ThemeSettings(
        themeID: .journalGray,
        isCustom: false,
        accentColorHex: "#4B5563",  // Warm gray
        unreadDotColorHex: "#6366F1", // Subtle indigo dot
        sidebarStyle: .system,
        sidebarTintHex: nil,
        listBackgroundTintHex: "#F9FAFB",
        listBackgroundTintOpacity: 0.03,
        secondaryTextColorHex: "#6B7280",  // Medium gray
        tertiaryTextColorHex: "#9CA3AF",   // Light gray
        detailBackgroundColorHex: "#F9FAFB",
        linkColorHex: "#4B5563",
        rowSeparatorColorHex: "#E5E7EB",
        useSerifTitles: false,
        iconColorHex: "#6B7280",
        darkModeOverrides: DarkModeOverrides(
            accentColorHex: "#9CA3AF",
            sidebarTintHex: nil,
            listBackgroundTintHex: "#1F2937",
            secondaryTextColorHex: "#9CA3AF",
            tertiaryTextColorHex: "#6B7280",
            detailBackgroundColorHex: "#111827",
            linkColorHex: "#9CA3AF"
        )
    )

    // MARK: - arXiv Red

    /// Inspired by arXiv's burgundy, for preprint enthusiasts
    static let arXivRed = ThemeSettings(
        themeID: .arXivRed,
        isCustom: false,
        accentColorHex: "#9D174D",  // Burgundy/maroon
        unreadDotColorHex: "#EC4899", // Pink dot
        sidebarStyle: .tinted,
        sidebarTintHex: "#9D174D",
        listBackgroundTintHex: "#FDF2F8",
        listBackgroundTintOpacity: 0.04,
        secondaryTextColorHex: "#4B5563",  // Cool gray
        tertiaryTextColorHex: "#6B7280",   // Medium gray
        detailBackgroundColorHex: "#FDF2F8",
        linkColorHex: "#9D174D",
        rowSeparatorColorHex: "#FBCFE8",
        useSerifTitles: false,
        iconColorHex: "#9D174D",
        darkModeOverrides: DarkModeOverrides(
            accentColorHex: "#F472B6",
            sidebarTintHex: "#5B1032",
            listBackgroundTintHex: "#5B1032",
            secondaryTextColorHex: "#9CA3AF",
            tertiaryTextColorHex: "#6B7280",
            detailBackgroundColorHex: "#4C0519",
            linkColorHex: "#F472B6"
        )
    )

    // MARK: - Citation

    /// Warm amber/gold, evokes old manuscripts and citations
    static let citation = ThemeSettings(
        themeID: .citation,
        isCustom: false,
        accentColorHex: "#B45309",  // Amber/gold
        unreadDotColorHex: "#F59E0B", // Bright amber dot
        sidebarStyle: .tinted,
        sidebarTintHex: "#B45309",
        listBackgroundTintHex: "#FFFBEB",
        listBackgroundTintOpacity: 0.05,
        secondaryTextColorHex: "#78350F",  // Dark amber/brown
        tertiaryTextColorHex: "#92400E",   // Medium amber
        detailBackgroundColorHex: "#FFFBEB",
        linkColorHex: "#B45309",
        rowSeparatorColorHex: "#FDE68A",
        useSerifTitles: true,
        iconColorHex: "#B45309",
        darkModeOverrides: DarkModeOverrides(
            accentColorHex: "#FCD34D",
            sidebarTintHex: "#78350F",
            listBackgroundTintHex: "#78350F",
            secondaryTextColorHex: "#D4A574",
            tertiaryTextColorHex: "#A78347",
            detailBackgroundColorHex: "#451A03",
            linkColorHex: "#FCD34D"
        )
    )
}
