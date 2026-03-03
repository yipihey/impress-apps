//
//  ThemeEnvironment.swift
//  ImpressTheme
//
//  SwiftUI environment keys for theme colors and font scaling.
//

import SwiftUI

// MARK: - Font Scale Environment Key

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The current font scale factor (0.7 to 1.4, default 1.0)
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// MARK: - System Text Scale

/// Utility to get the macOS system text size scale factor
public enum SystemTextScale {
    /// Get the current system text size scale factor.
    ///
    /// Reads the macOS "Text size" setting from System Settings > Accessibility > Display
    /// and returns a scale factor relative to the default text size.
    ///
    /// - Returns: Scale factor (1.0 = default, >1.0 = larger, <1.0 = smaller)
    public static var current: Double {
        #if os(macOS)
        let preferredFont = NSFont.preferredFont(forTextStyle: .body)
        let preferredSize = preferredFont.pointSize
        let defaultBodySize: CGFloat = 13.0
        let scale = preferredSize / defaultBodySize
        return max(0.8, min(1.5, scale))
        #else
        return 1.0
        #endif
    }
}

// MARK: - Window Background Setter

#if os(macOS)
import AppKit

/// NSViewRepresentable that sets the window background color and titlebar appearance.
public struct WindowBackgroundSetter: NSViewRepresentable {
    let color: Color?

    public init(color: Color?) {
        self.color = color
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        DispatchQueue.main.async {
            updateWindowAppearance(for: view)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateWindowAppearance(for: nsView)
        }
    }

    private func updateWindowAppearance(for view: NSView) {
        guard let window = view.window else { return }

        if let color = color {
            let nsColor = NSColor(color)
            window.backgroundColor = nsColor
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
        } else {
            window.backgroundColor = nil
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
        }
    }
}
#endif
