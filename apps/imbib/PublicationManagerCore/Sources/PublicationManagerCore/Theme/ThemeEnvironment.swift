//
//  ThemeEnvironment.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-14.
//

import SwiftUI
import ImpressMailStyle

// MARK: - Theme Colors Environment Key

private struct ThemeColorsKey: EnvironmentKey {
    static let defaultValue = ThemeColors.default
}

// MARK: - Font Scale Environment Key

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The current theme colors resolved for the current color scheme
    var themeColors: ThemeColors {
        get { self[ThemeColorsKey.self] }
        set { self[ThemeColorsKey.self] = newValue }
    }

    /// The current font scale factor (0.7 to 1.4, default 1.0)
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// MARK: - Theme Provider

/// View modifier that provides theme colors to the view hierarchy.
///
/// This modifier:
/// - Loads theme settings from ThemeSettingsStore
/// - Listens for theme change notifications
/// - Resolves colors based on current colorScheme (light/dark)
/// - Applies the system tint color
///
/// Usage:
/// ```swift
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///                 .withTheme()
///         }
///     }
/// }
/// ```
public struct ThemeProvider: ViewModifier {

    @Environment(\.colorScheme) private var colorScheme
    @State private var settings: ThemeSettings = ThemeSettingsStore.loadSettingsSync()
    @State private var systemTextScale: Double = SystemTextScale.current

    public init() {}

    public func body(content: Content) -> some View {
        let colors = ThemeColors(from: settings, colorScheme: colorScheme)
        // Combine user's theme font scale with system text size scale
        let effectiveFontScale = settings.fontScale * systemTextScale

        content
            .environment(\.themeColors, colors)
            .environment(\.fontScale, effectiveFontScale)
            .environment(\.mailStyleColors, colors)
            .environment(\.mailStyleFontScale, effectiveFontScale)
            .tint(colors.accent)
            .preferredColorScheme(settings.appearanceMode.colorScheme)
            #if os(macOS)
            .background(WindowBackgroundSetter(color: colors.detailBackground))
            #endif
            .task {
                settings = await ThemeSettingsStore.shared.settings
            }
            .onReceive(NotificationCenter.default.publisher(for: .themeSettingsDidChange)) { _ in
                Task {
                    settings = await ThemeSettingsStore.shared.settings
                }
            }
            #if os(macOS)
            // Listen for system text size changes (accessibility settings)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                systemTextScale = SystemTextScale.current
            }
            #endif
    }
}

// MARK: - System Text Scale

/// Utility to get the macOS system text size scale factor
public enum SystemTextScale {
    /// Get the current system text size scale factor
    ///
    /// This reads the macOS "Text size" setting from System Settings > Accessibility > Display
    /// and returns a scale factor relative to the default text size.
    ///
    /// - Returns: Scale factor (1.0 = default, >1.0 = larger text, <1.0 = smaller text)
    public static var current: Double {
        #if os(macOS)
        // Get the system's preferred body font
        let preferredFont = NSFont.preferredFont(forTextStyle: .body)
        let preferredSize = preferredFont.pointSize

        // macOS default body font size is 13pt
        let defaultBodySize: CGFloat = 13.0

        // Calculate scale factor
        let scale = preferredSize / defaultBodySize

        // Clamp to reasonable range
        return max(0.8, min(1.5, scale))
        #else
        // iOS uses Dynamic Type which is handled differently
        return 1.0
        #endif
    }
}

// MARK: - macOS Window Background

#if os(macOS)
import AppKit

/// NSViewRepresentable that sets the window background color and titlebar appearance
struct WindowBackgroundSetter: NSViewRepresentable {
    let color: Color?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        DispatchQueue.main.async {
            updateWindowAppearance(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateWindowAppearance(for: nsView)
        }
    }

    private func updateWindowAppearance(for view: NSView) {
        guard let window = view.window else { return }

        if let color = color {
            // Convert SwiftUI Color to NSColor
            let nsColor = NSColor(color)
            window.backgroundColor = nsColor
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
        } else {
            // Reset to system default
            window.backgroundColor = nil
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
        }
    }
}
#endif

// MARK: - View Extension

public extension View {
    /// Apply the theme provider to inject theme colors into the environment
    func withTheme() -> some View {
        modifier(ThemeProvider())
    }
}

// MARK: - Preview Helper

/// A view modifier for previews that applies a specific theme
public struct PreviewTheme: ViewModifier {
    let themeID: ThemeID
    let colorScheme: ColorScheme

    public init(_ themeID: ThemeID, colorScheme: ColorScheme = .light) {
        self.themeID = themeID
        self.colorScheme = colorScheme
    }

    public func body(content: Content) -> some View {
        let settings = ThemeSettings.predefined(themeID)
        let colors = ThemeColors(from: settings, colorScheme: colorScheme)

        content
            .environment(\.themeColors, colors)
            .environment(\.fontScale, settings.fontScale)
            .environment(\.mailStyleColors, colors)
            .environment(\.mailStyleFontScale, settings.fontScale)
            .environment(\.colorScheme, colorScheme)
            .tint(colors.accent)
    }
}

public extension View {
    /// Apply a specific theme for previews
    func previewTheme(_ themeID: ThemeID, colorScheme: ColorScheme = .light) -> some View {
        modifier(PreviewTheme(themeID, colorScheme: colorScheme))
    }
}
