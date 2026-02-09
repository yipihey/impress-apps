//
//  DetailWindowController.swift
//  imbib
//
//  Created by Claude on 2026-01-19.
//

#if os(macOS)
import SwiftUI
import AppKit
import PublicationManagerCore
import OSLog

// MARK: - Detached Tab Type

/// Represents a tab that can be detached to a separate window
public enum DetachedTab: String, Codable, Hashable {
    case pdf
    case notes
    case bibtex
    case info

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .notes: return "Notes"
        case .bibtex: return "BibTeX"
        case .info: return "Info"
        }
    }

    var icon: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .notes: return "note.text"
        case .bibtex: return "curlybraces"
        case .info: return "info.circle"
        }
    }

    /// Default window size for this tab type
    var defaultSize: NSSize {
        switch self {
        case .pdf: return NSSize(width: 900, height: 1000)
        case .notes: return NSSize(width: 900, height: 900)
        case .bibtex: return NSSize(width: 700, height: 600)
        case .info: return NSSize(width: 500, height: 600)
        }
    }

    /// Minimum window size for this tab type
    var minSize: NSSize {
        switch self {
        case .pdf: return NSSize(width: 500, height: 400)
        case .notes: return NSSize(width: 600, height: 500)
        case .bibtex: return NSSize(width: 500, height: 400)
        case .info: return NSSize(width: 400, height: 400)
        }
    }
}

// MARK: - Window Key

/// Unique identifier for a detached window
struct DetachedWindowKey: Hashable {
    let publicationID: UUID
    let tab: DetachedTab
}

// MARK: - Detail Window Controller

/// Manages detached detail tab windows.
///
/// Allows any detail tab (PDF, Notes, BibTeX, Info) to be "popped out" to a
/// separate window, with intelligent placement on secondary displays.
///
/// Usage:
/// ```swift
/// await DetailWindowController.shared.openTab(.pdf, for: publication)
/// ```
@MainActor
public final class DetailWindowController {

    // MARK: - Shared Instance

    public static let shared = DetailWindowController()

    // MARK: - Properties

    /// Currently open detached windows
    private var windows: [DetachedWindowKey: NSWindow] = [:]

    /// Window delegates (must retain)
    private var delegates: [DetachedWindowKey: WindowDelegate] = [:]

    private let logger = Logger(subsystem: "com.imbib", category: "DetailWindow")

    /// Stored environment objects for NotesTab (injected via openTab)
    private var libraryViewModel: LibraryViewModel?
    private var libraryManager: LibraryManager?

    // MARK: - Initialization

    /// Reference to the main app window (for flip positions)
    private weak var mainAppWindow: NSWindow?

    private init() {
        logger.info("DetailWindowController initialized")

        // Listen for screen configuration changes to handle disconnect
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: .screenConfigurationDidChange,
            object: nil
        )

        // Listen for flip window positions command (works from any window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFlipWindowPositions),
            name: .flipWindowPositions,
            object: nil
        )
    }

    /// Register the main app window for flip positions feature
    public func registerMainWindow(_ window: NSWindow) {
        mainAppWindow = window
        logger.debug("Registered main app window for flip positions")
    }

    // MARK: - Public API

    /// Open a detached window for a specific tab of a publication.
    ///
    /// If a window is already open for this publication+tab, it will be brought to front.
    ///
    /// - Parameters:
    ///   - tab: The tab type to open (pdf, notes, bibtex, info)
    ///   - publication: The publication model to display
    ///   - screen: Optional target screen (defaults to secondary if available)
    ///   - library: The library containing the publication (needed for PDF path resolution)
    public func openTab(
        _ tab: DetachedTab,
        for publication: PublicationModel,
        on screen: NSScreen? = nil,
        library: LibraryModel? = nil,
        libraryViewModel: LibraryViewModel? = nil,
        libraryManager: LibraryManager? = nil
    ) {
        // Store environment objects for NotesTab
        if let vm = libraryViewModel { self.libraryViewModel = vm }
        if let lm = libraryManager { self.libraryManager = lm }
        let key = DetachedWindowKey(publicationID: publication.id, tab: tab)

        // Check for existing window
        if let existingWindow = windows[key] {
            logger.info("Bringing existing \(tab.title) window to front")
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        logger.info("Creating detached \(tab.title) window for: \(publication.title)")

        // Create the content view
        let contentView = createContentView(for: tab, publication: publication, library: library)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: contentView)

        // Create window
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(tab.title) - \(publication.title)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = tab.minSize

        // Position window
        let targetScreen = screen
            ?? ScreenConfigurationObserver.shared.secondaryScreen
            ?? NSScreen.main

        if let targetScreen = targetScreen {
            positionWindow(window, for: tab, on: targetScreen)
        } else {
            window.setContentSize(tab.defaultSize)
            window.center()
        }

        // Set window delegate to track close
        let delegate = WindowDelegate(key: key, citeKey: publication.citeKey, controller: self)
        window.delegate = delegate
        delegates[key] = delegate

        // Store reference
        windows[key] = window

        // Show window and ensure it gets focus
        window.makeKeyAndOrderFront(nil)

        // Activate the app and ensure the new window becomes key window
        // This is important for proper focus transfer to secondary monitors
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            window.makeKey()
            // Enter fullscreen mode after window is on screen
            window.toggleFullScreen(nil)
        }

        // Save state for restoration on app restart
        Task {
            let state = DetachedWindowState(
                publicationCiteKey: publication.citeKey,
                tab: tab.rawValue,
                frame: window.frame,
                screenName: window.screen?.localizedName
            )
            await DetachedWindowStateStore.shared.saveWindowState(state)
        }

        logger.info("Detached \(tab.title) window opened")
    }

    /// Open a detached window using publication ID and library ID.
    ///
    /// Looks up the PublicationModel from the Rust store.
    public func openTab(
        _ tab: DetachedTab,
        forPublicationID publicationID: UUID,
        libraryID: UUID? = nil,
        on screen: NSScreen? = nil,
        libraryViewModel: LibraryViewModel? = nil,
        libraryManager: LibraryManager? = nil
    ) {
        // Get publication data from Rust store
        let store = RustStoreAdapter.shared
        guard let publication = store.getPublicationDetail(id: publicationID) else {
            logger.warning("Cannot open detached window: publication \(publicationID) not found")
            return
        }

        let library: LibraryModel? = libraryID.flatMap { store.getLibrary(id: $0) }

        openTab(
            tab,
            for: publication,
            on: screen,
            library: library,
            libraryViewModel: libraryViewModel,
            libraryManager: libraryManager
        )
    }

    /// Close all detached windows for a publication by ID.
    public func closeWindows(forPublicationID id: UUID) {
        let keysToClose = windows.keys.filter { $0.publicationID == id }
        for key in keysToClose {
            closeWindow(key: key)
        }
    }

    /// Close a specific detached window by publication ID.
    public func closeTab(_ tab: DetachedTab, forPublicationID id: UUID) {
        let key = DetachedWindowKey(publicationID: id, tab: tab)
        closeWindow(key: key)
    }

    /// Close all detached windows.
    public func closeAllWindows() {
        for window in windows.values {
            window.close()
        }
        windows.removeAll()
        delegates.removeAll()
        logger.info("All detached windows closed")
    }

    /// Check if a window is open for a specific tab of a publication by ID.
    public func hasOpenWindow(_ tab: DetachedTab, forPublicationID id: UUID) -> Bool {
        let key = DetachedWindowKey(publicationID: id, tab: tab)
        return windows[key] != nil
    }

    /// Check if any detached windows are open for a publication by ID.
    public func hasAnyOpenWindow(forPublicationID id: UUID) -> Bool {
        windows.keys.contains { $0.publicationID == id }
    }

    /// Get count of open detached windows
    public var openWindowCount: Int { windows.count }

    /// Restore windows from saved state.
    ///
    /// Call this during app startup to restore any detached windows that were open
    /// when the app was last closed.
    public func restoreFromSavedState() {
        Task {
            // First, sanitize any corrupted/oversized window states
            await DetachedWindowStateStore.shared.sanitizeAllStates()

            let states = await DetachedWindowStateStore.shared.getAllStates()

            guard !states.isEmpty else {
                logger.debug("No saved detached window states to restore")
                return
            }

            logger.info("Restoring \(states.count) detached windows from saved state")

            let store = RustStoreAdapter.shared

            for state in states {
                // Find the publication by cite key via RustStoreAdapter
                guard let pubRow = store.findByCiteKey(citeKey: state.publicationCiteKey) else {
                    logger.warning("Could not find publication for cite key: \(state.publicationCiteKey)")
                    continue
                }

                guard let publication = store.getPublicationDetail(id: pubRow.id) else {
                    logger.warning("Could not load publication detail for: \(state.publicationCiteKey)")
                    continue
                }

                guard let tab = DetachedTab(rawValue: state.tab) else {
                    logger.warning("Invalid tab type in saved state: \(state.tab)")
                    continue
                }

                // Find target screen by name, or use saved frame position
                let targetScreen = state.screenName.flatMap { screenName in
                    NSScreen.screens.first { $0.localizedName == screenName }
                }

                // Get library from publication's library IDs
                let library: LibraryModel? = publication.libraryIDs.first.flatMap { store.getLibrary(id: $0) }

                // Open the tab
                await MainActor.run {
                    openTab(tab, for: publication, on: targetScreen, library: library)

                    // Apply saved frame after window is created, with constraint to prevent oversized windows
                    let key = DetachedWindowKey(publicationID: publication.id, tab: tab)
                    if let window = windows[key] {
                        // Use the window's current screen or target screen for constraints
                        let constraintScreen = window.screen ?? targetScreen ?? ScreenConfigurationObserver.shared.primaryScreen
                        if let screen = constraintScreen {
                            let screenObserver = ScreenConfigurationObserver.shared
                            let wasConstrained = screenObserver.safelySetFrame(window, to: state.frame, on: screen, animate: false)

                            // If frame was constrained, update the saved state with corrected frame
                            if wasConstrained {
                                Task {
                                    let correctedState = DetachedWindowState(
                                        publicationCiteKey: state.publicationCiteKey,
                                        tab: state.tab,
                                        frame: window.frame,
                                        screenName: window.screen?.localizedName
                                    )
                                    await DetachedWindowStateStore.shared.saveWindowState(correctedState)
                                }
                            }
                        } else {
                            window.setFrame(state.frame, display: true)
                        }
                    }
                }
            }
        }
    }

    /// Flip window positions between displays.
    ///
    /// If the main window is on primary and detached is on secondary, swap them.
    public func flipWindowPositions(mainWindow: NSWindow?) {
        guard let mainWindow = mainWindow,
              ScreenConfigurationObserver.shared.hasSecondaryScreen else {
            return
        }

        let screenObserver = ScreenConfigurationObserver.shared

        // Find which screen each window is on
        let mainScreen = mainWindow.screen ?? screenObserver.primaryScreen
        let detachedWindows = Array(windows.values)

        guard let detachedWindow = detachedWindows.first,
              let primaryScreen = screenObserver.primaryScreen,
              let secondaryScreen = screenObserver.secondaryScreen else {
            return
        }

        // Swap positions using safe frame setting to prevent oversized windows
        if mainScreen == primaryScreen {
            // Main is on primary, move to secondary
            let newFrame = screenObserver.maximizedFrame(on: secondaryScreen)
            screenObserver.safelySetFrame(mainWindow, to: newFrame, on: secondaryScreen, animate: true)

            // Move detached to primary
            let detachedFrame = screenObserver.maximizedFrame(on: primaryScreen)
            screenObserver.safelySetFrame(detachedWindow, to: detachedFrame, on: primaryScreen, animate: true)
        } else {
            // Main is on secondary, move to primary
            let newFrame = screenObserver.maximizedFrame(on: primaryScreen)
            screenObserver.safelySetFrame(mainWindow, to: newFrame, on: primaryScreen, animate: true)

            // Move detached to secondary
            let detachedFrame = screenObserver.maximizedFrame(on: secondaryScreen)
            screenObserver.safelySetFrame(detachedWindow, to: detachedFrame, on: secondaryScreen, animate: true)
        }

        logger.info("Flipped window positions between displays")
    }

    // MARK: - Private

    private func closeWindow(key: DetachedWindowKey) {
        if let window = windows[key] {
            window.close()
        }
        windows.removeValue(forKey: key)
        delegates.removeValue(forKey: key)
        logger.info("Detached \(key.tab.title) window closed")
    }

    fileprivate func windowDidClose(key: DetachedWindowKey, citeKey: String) {
        windows.removeValue(forKey: key)
        delegates.removeValue(forKey: key)

        // Remove from state store
        Task {
            await DetachedWindowStateStore.shared.removeWindowState(
                publicationCiteKey: citeKey,
                tab: key.tab.rawValue
            )
        }

        logger.info("Detached \(key.tab.title) window closed via delegate")
    }

    @objc private func handleFlipWindowPositions(_ notification: Notification) {
        // Use the registered main app window, or find it by looking for a non-detached window
        let mainWindow = mainAppWindow ?? findMainAppWindow()
        guard let mainWindow = mainWindow else {
            logger.warning("Cannot flip positions: no main app window found")
            return
        }
        flipWindowPositions(mainWindow: mainWindow)
    }

    /// Find the main app window (not a detached window)
    private func findMainAppWindow() -> NSWindow? {
        // The main app window is any window that isn't one of our detached windows
        let detachedWindowSet = Set(windows.values)
        return NSApp.windows.first { window in
            !detachedWindowSet.contains(window) &&
            window.isVisible &&
            window.className.contains("NSWindow") // Exclude panels, popovers, etc.
        }
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        // If secondary display disconnected, migrate windows to primary
        guard !ScreenConfigurationObserver.shared.hasSecondaryScreen else { return }

        logger.info("Secondary display disconnected, migrating windows to primary")

        let screenObserver = ScreenConfigurationObserver.shared
        guard let primaryScreen = screenObserver.primaryScreen else { return }

        // Tile windows on primary screen using safe frame setting
        let openWindows = Array(windows.values)
        let screenFrame = primaryScreen.visibleFrame
        let windowCount = openWindows.count

        for (index, window) in openWindows.enumerated() {
            let width = screenFrame.width / CGFloat(min(windowCount, 2))
            let xOffset = width * CGFloat(index % 2)

            let newFrame = NSRect(
                x: screenFrame.minX + xOffset,
                y: screenFrame.minY,
                width: width,
                height: screenFrame.height
            )

            screenObserver.safelySetFrame(window, to: newFrame, on: primaryScreen, animate: true)
        }
    }

    private func positionWindow(_ window: NSWindow, for tab: DetachedTab, on screen: NSScreen) {
        let screenObserver = ScreenConfigurationObserver.shared

        switch tab {
        case .pdf, .notes:
            // PDF and notes (PDF+notes panel) windows maximize on target screen
            let frame = screenObserver.maximizedFrame(on: screen)
            screenObserver.safelySetFrame(window, to: frame, on: screen, animate: false)

        case .bibtex, .info:
            // Other windows use default size, centered on target screen
            let frame = screenObserver.centeredFrame(size: tab.defaultSize, on: screen)
            screenObserver.safelySetFrame(window, to: frame, on: screen, animate: false)
        }
    }

    @ViewBuilder
    private func createContentView(
        for tab: DetachedTab,
        publication: PublicationModel,
        library: LibraryModel?
    ) -> some View {
        switch tab {
        case .pdf:
            DetachedPDFView(publication: publication, library: library)
                .frame(minWidth: tab.minSize.width, minHeight: tab.minSize.height)

        case .notes:
            DetachedNotesView(publication: publication)
                .frame(minWidth: tab.minSize.width, minHeight: tab.minSize.height)

        case .bibtex:
            DetachedBibTeXView(publication: publication)
                .frame(minWidth: tab.minSize.width, minHeight: tab.minSize.height)

        case .info:
            DetachedInfoView(publication: publication)
                .frame(minWidth: tab.minSize.width, minHeight: tab.minSize.height)
        }
    }
}

// MARK: - Window Delegate

private class WindowDelegate: NSObject, NSWindowDelegate {

    let key: DetachedWindowKey
    let citeKey: String
    weak var controller: DetailWindowController?

    init(key: DetachedWindowKey, citeKey: String, controller: DetailWindowController) {
        self.key = key
        self.citeKey = citeKey
        self.controller = controller
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            controller?.windowDidClose(key: key, citeKey: citeKey)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Ensure the window has focus after fullscreen transition
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Move the mouse cursor to the center of the window's screen
        if let screen = window.screen {
            let centerX = screen.frame.midX
            let centerY = screen.frame.midY
            // CGPoint uses flipped coordinates (0,0 at top-left)
            let screenHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? screen.frame.height
            let flippedY = screenHeight - centerY
            CGWarpMouseCursorPosition(CGPoint(x: centerX, y: flippedY))
        }

        // Post notification so the SwiftUI view can request focus
        NotificationCenter.default.post(name: .detachedWindowDidEnterFullScreen, object: nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a detached window enters fullscreen mode
    static let detachedWindowDidEnterFullScreen = Notification.Name("detachedWindowDidEnterFullScreen")
}

#endif // os(macOS)
