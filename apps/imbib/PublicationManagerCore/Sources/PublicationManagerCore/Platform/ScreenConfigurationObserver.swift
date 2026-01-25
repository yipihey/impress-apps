//
//  ScreenConfigurationObserver.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-19.
//

#if os(macOS)
import AppKit
import os.log

/// Observes screen configuration changes and provides information about available displays.
/// Used for dual-monitor support to intelligently place windows on secondary displays.
@MainActor
@Observable
public final class ScreenConfigurationObserver {
    // MARK: - Singleton

    public static let shared = ScreenConfigurationObserver()

    // MARK: - Published State

    /// All currently connected screens, ordered by position (leftmost first)
    public private(set) var screens: [NSScreen] = []

    /// Whether a secondary display is available
    public var hasSecondaryScreen: Bool { screens.count > 1 }

    /// The primary screen (usually the one with the menu bar)
    public var primaryScreen: NSScreen? { NSScreen.main }

    /// The secondary screen, if available (first non-primary screen)
    public var secondaryScreen: NSScreen? {
        guard screens.count > 1 else { return nil }
        // Return first screen that isn't the main screen
        return screens.first { $0 != NSScreen.main } ?? screens.last
    }

    /// A hash representing the current screen configuration
    /// Used to persist window positions per-configuration
    public private(set) var configurationHash: String = ""

    /// Number of connected screens
    public var screenCount: Int { screens.count }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.imbib", category: "ScreenConfiguration")

    // MARK: - Initialization

    private init() {
        updateScreens()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        logger.info("ScreenConfigurationObserver initialized with \(self.screens.count) screen(s)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Screen Updates

    @objc private func screensChanged(_ notification: Notification) {
        let oldCount = screens.count
        let oldHash = configurationHash

        updateScreens()

        if screens.count != oldCount {
            logger.info("Screen count changed: \(oldCount) → \(self.screens.count)")
            NotificationCenter.default.post(name: .screenCountDidChange, object: self)
        }

        if configurationHash != oldHash {
            logger.info("Screen configuration changed: \(self.configurationHash)")
            NotificationCenter.default.post(name: .screenConfigurationDidChange, object: self)
        }
    }

    private func updateScreens() {
        screens = NSScreen.screens

        // Generate a hash from screen properties
        // Using localized name + resolution to identify configuration
        configurationHash = screens.map { screen in
            let frame = screen.frame
            return "\(screen.localizedName)_\(Int(frame.width))x\(Int(frame.height))"
        }.joined(separator: "|")
    }

    // MARK: - Screen Queries

    /// Get the screen at a specific index (0 = primary)
    public func screen(at index: Int) -> NSScreen? {
        guard index >= 0 && index < screens.count else { return nil }
        return screens[index]
    }

    /// Get the index of a screen in the current configuration
    public func index(of screen: NSScreen) -> Int? {
        screens.firstIndex(of: screen)
    }

    /// Get the best screen for a new window (prefers secondary if available)
    public func preferredScreenForNewWindow() -> NSScreen {
        secondaryScreen ?? primaryScreen ?? NSScreen.main ?? screens.first!
    }

    /// Get screen by checking if a point is within its frame
    public func screen(containing point: NSPoint) -> NSScreen? {
        screens.first { $0.frame.contains(point) }
    }

    // MARK: - Frame Calculations

    /// Calculate a maximized frame for a window on the given screen
    /// Accounts for menu bar and dock
    public func maximizedFrame(on screen: NSScreen) -> NSRect {
        screen.visibleFrame
    }

    /// Calculate a frame for the right half of a screen
    public func rightHalfFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX,
            y: visible.minY,
            width: visible.width / 2,
            height: visible.height
        )
    }

    /// Calculate a frame for the left half of a screen
    public func leftHalfFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX,
            y: visible.minY,
            width: visible.width / 2,
            height: visible.height
        )
    }

    /// Calculate a centered frame with the given size on a screen
    public func centeredFrame(size: NSSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Constrain a frame to fit within the given screen's visible area.
    /// This prevents windows from being larger than the screen or positioned off-screen.
    public func constrainedFrame(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame

        // Constrain size to not exceed screen
        var width = min(frame.width, visible.width)
        var height = min(frame.height, visible.height)

        // Ensure minimum size
        width = max(width, 400)
        height = max(height, 300)

        // Constrain position to keep window on screen
        var x = frame.origin.x
        var y = frame.origin.y

        // Keep within horizontal bounds
        if x < visible.minX {
            x = visible.minX
        } else if x + width > visible.maxX {
            x = visible.maxX - width
        }

        // Keep within vertical bounds
        if y < visible.minY {
            y = visible.minY
        } else if y + height > visible.maxY {
            y = visible.maxY - height
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Safely set a window's frame, ensuring it fits within the target screen.
    /// Returns true if the frame was constrained.
    @discardableResult
    public func safelySetFrame(_ window: NSWindow, to frame: NSRect, on screen: NSScreen, animate: Bool = true) -> Bool {
        let constrained = constrainedFrame(frame, to: screen)
        let wasConstrained = constrained != frame

        if wasConstrained {
            logger.debug("Window frame constrained: \(Int(frame.width))x\(Int(frame.height)) → \(Int(constrained.width))x\(Int(constrained.height))")
        }

        window.setFrame(constrained, display: true, animate: animate)
        return wasConstrained
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the number of connected screens changes
    static let screenCountDidChange = Notification.Name("screenCountDidChange")

    /// Posted when the screen configuration changes (resolution, arrangement, etc.)
    static let screenConfigurationDidChange = Notification.Name("screenConfigurationDidChange")
}
#endif
