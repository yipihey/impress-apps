//
//  PlatformColors.swift
//  ImpressTheme
//
//  Platform-bridging SwiftUI `Color` helpers.
//
//  Rule 2 of ADR-023 (iOS/macOS parity protocol) says cross-platform
//  code should never sprinkle `#if os(macOS) Color(nsColor:)
//  #else Color(uiColor:) #endif` blocks through view bodies. Instead
//  it should reach for a shared platform-bridged color that resolves
//  to the appropriate AppKit or UIKit system color at compile time.
//
//  This file provides those helpers as `Color` static members so
//  existing view code can swap `Color(nsColor: .controlBackgroundColor)`
//  for `Color.platformControlBackground` and stay cross-platform.
//
//  Add new helpers here as more cross-platform color translation
//  needs surface. Keep each helper behind a `#if os(macOS)` /
//  `#else` branch so both platforms end up with a meaningful value.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public extension Color {

    /// The standard control background color: `NSColor.controlBackgroundColor`
    /// on macOS, `UIColor.secondarySystemBackground` on iOS. Use for
    /// pane backgrounds, filled input containers, and message bubbles.
    static var platformControlBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// The standard window / view background color:
    /// `NSColor.windowBackgroundColor` on macOS,
    /// `UIColor.systemBackground` on iOS. Use for top-level surfaces
    /// that want to match the system chrome.
    static var platformWindowBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    /// The standard separator line color: `NSColor.separatorColor`
    /// on macOS, `UIColor.separator` on iOS.
    static var platformSeparator: Color {
        #if os(macOS)
        return Color(nsColor: .separatorColor)
        #else
        return Color(uiColor: .separator)
        #endif
    }

    /// The tertiary-importance label color: `NSColor.tertiaryLabelColor`
    /// on macOS, `UIColor.tertiaryLabel` on iOS. Matches the existing
    /// `MailStyleColors` token so mail-style rows look identical on
    /// both platforms.
    static var platformTertiaryLabel: Color {
        #if os(macOS)
        return Color(nsColor: .tertiaryLabelColor)
        #else
        return Color(uiColor: .tertiaryLabel)
        #endif
    }
}
