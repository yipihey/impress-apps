//
//  DetachedWindowStateStore.swift
//  imbib
//
//  Created by Claude on 2026-01-19.
//

#if os(macOS)
import Foundation
import AppKit
import OSLog

// MARK: - Detached Window State

/// State for a single detached window
public struct DetachedWindowState: Codable, Equatable, Sendable {
    /// The publication's cite key (used to find the publication)
    public let publicationCiteKey: String

    /// The tab type (pdf, notes, bibtex, info)
    public let tab: String

    /// Window frame (x, y, width, height)
    public let frameX: Double
    public let frameY: Double
    public let frameWidth: Double
    public let frameHeight: Double

    /// Screen identifier (screen's localizedName for matching)
    public let screenName: String?

    /// When the window was last opened
    public let dateOpened: Date

    public init(
        publicationCiteKey: String,
        tab: String,
        frame: NSRect,
        screenName: String? = nil
    ) {
        self.publicationCiteKey = publicationCiteKey
        self.tab = tab
        self.frameX = frame.origin.x
        self.frameY = frame.origin.y
        self.frameWidth = frame.size.width
        self.frameHeight = frame.size.height
        self.screenName = screenName
        self.dateOpened = Date()
    }

    var frame: NSRect {
        NSRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)
    }
}

// MARK: - Detached Window State Store

/// Actor-based store for persisting detached window state.
///
/// Saves which windows are open, their positions, and which screens they're on
/// so they can be restored on app restart.
public actor DetachedWindowStateStore {

    // MARK: - Singleton

    public static let shared = DetachedWindowStateStore()

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private var cache: [DetachedWindowState] = []
    private let storageKey = "detached_window_states"
    private let logger = Logger(subsystem: "com.imbib.app", category: "detachedwindows")

    // MARK: - Initialization

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Load synchronously on init (safe since this is during actor creation)
        if let data = userDefaults.data(forKey: storageKey),
           let states = try? JSONDecoder().decode([DetachedWindowState].self, from: data) {
            cache = states
        }
    }

    // MARK: - Public API

    /// Get all saved window states
    public func getAllStates() -> [DetachedWindowState] {
        cache
    }

    /// Save the state of a detached window
    public func saveWindowState(_ state: DetachedWindowState) {
        // Remove any existing state for this publication/tab combo
        cache.removeAll { $0.publicationCiteKey == state.publicationCiteKey && $0.tab == state.tab }

        // Add the new state
        cache.append(state)

        // Persist
        saveToDefaults()
        logger.debug("Saved window state for \(state.publicationCiteKey)/\(state.tab)")
    }

    /// Remove the state for a window (when closed)
    public func removeWindowState(publicationCiteKey: String, tab: String) {
        cache.removeAll { $0.publicationCiteKey == publicationCiteKey && $0.tab == tab }
        saveToDefaults()
        logger.debug("Removed window state for \(publicationCiteKey)/\(tab)")
    }

    /// Clear all saved window states
    public func clearAllStates() {
        cache.removeAll()
        saveToDefaults()
        logger.debug("Cleared all detached window states")
    }

    /// Sanitize all saved window states to ensure frames fit within screen bounds.
    /// Call this on app startup to fix any corrupted oversized window states.
    public func sanitizeAllStates() {
        var modified = false

        for (index, state) in cache.enumerated() {
            // Find the target screen
            let targetScreen = state.screenName.flatMap { screenName in
                NSScreen.screens.first { $0.localizedName == screenName }
            } ?? NSScreen.main

            guard let screen = targetScreen else { continue }

            let visibleFrame = screen.visibleFrame
            var frame = state.frame

            // Check if frame is oversized or off-screen
            let needsCorrection = frame.width > visibleFrame.width ||
                                  frame.height > visibleFrame.height ||
                                  frame.minX < visibleFrame.minX ||
                                  frame.minY < visibleFrame.minY ||
                                  frame.maxX > visibleFrame.maxX ||
                                  frame.maxY > visibleFrame.maxY

            if needsCorrection {
                // Constrain size
                frame.size.width = min(frame.width, visibleFrame.width)
                frame.size.height = min(frame.height, visibleFrame.height)

                // Constrain position
                if frame.minX < visibleFrame.minX {
                    frame.origin.x = visibleFrame.minX
                } else if frame.maxX > visibleFrame.maxX {
                    frame.origin.x = visibleFrame.maxX - frame.width
                }
                if frame.minY < visibleFrame.minY {
                    frame.origin.y = visibleFrame.minY
                } else if frame.maxY > visibleFrame.maxY {
                    frame.origin.y = visibleFrame.maxY - frame.height
                }

                // Update the cached state
                cache[index] = DetachedWindowState(
                    publicationCiteKey: state.publicationCiteKey,
                    tab: state.tab,
                    frame: frame,
                    screenName: state.screenName
                )
                modified = true
                logger.info("Sanitized oversized window state for \(state.publicationCiteKey)/\(state.tab)")
            }
        }

        if modified {
            saveToDefaults()
            logger.info("Saved sanitized window states")
        }
    }

    /// Get state for a specific window
    public func getState(publicationCiteKey: String, tab: String) -> DetachedWindowState? {
        cache.first { $0.publicationCiteKey == publicationCiteKey && $0.tab == tab }
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            cache = []
            return
        }

        do {
            cache = try JSONDecoder().decode([DetachedWindowState].self, from: data)
            logger.info("Loaded \(self.cache.count) detached window states")
        } catch {
            logger.error("Failed to decode detached window states: \(error.localizedDescription)")
            cache = []
        }
    }

    private func saveToDefaults() {
        do {
            let data = try JSONEncoder().encode(cache)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            logger.error("Failed to encode detached window states: \(error.localizedDescription)")
        }
    }
}

#endif // os(macOS)
