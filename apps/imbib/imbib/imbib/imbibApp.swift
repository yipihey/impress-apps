//
//  imbibApp.swift
//  imbib
//
//  Created by Claude on 2026-01-04.
//

import SwiftUI
import CoreData
import CoreSpotlight
import CloudKit
import PublicationManagerCore
import ImpressKit
import OSLog
import UniformTypeIdentifiers
import ImpressKeyboard
#if os(macOS)
import AppKit
#endif

private let appLogger = Logger(subsystem: "com.imbib.app", category: "app")

// MARK: - App Delegate for URL Scheme Handling

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Event monitor for mouse back/forward buttons
    private var mouseEventMonitor: Any?

    private func debugLog(_ message: String) {
        // Use NSLog which works in sandboxed apps and shows in Console.app
        NSLog("[DEBUG] %@", message)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("AppDelegate.applicationDidFinishLaunching called")

        // Clear any corrupted SwiftUI window state on launch
        // This prevents oversized windows from being restored
        sanitizeWindowDefaults()

        // Set up mouse back/forward button handling
        setupMouseButtonMonitor()
    }

    /// Monitor mouse back/forward buttons and map them to focus cycling (h/l shortcuts).
    /// Button 3 = back = focus left, Button 4 = forward = focus right.
    private func setupMouseButtonMonitor() {
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: // Back button
                NotificationCenter.default.post(name: .cycleFocusLeft, object: nil)
                return nil // Consume the event
            case 4: // Forward button
                NotificationCenter.default.post(name: .cycleFocusRight, object: nil)
                return nil // Consume the event
            default:
                return event // Pass through other buttons
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up event monitor
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    /// Remove corrupted SwiftUI window state that could cause oversized windows.
    /// Checks against actual current screen dimensions to catch size mismatches.
    private func sanitizeWindowDefaults() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        // Get the maximum screen dimensions from all connected displays
        let maxScreenHeight = NSScreen.screens.map { $0.frame.height }.max() ?? 1080
        let maxScreenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1920

        // Add some tolerance (10%) for edge cases
        let maxAllowedHeight = maxScreenHeight * 1.1
        let maxAllowedWidth = maxScreenWidth * 1.1

        for key in allKeys {
            // Check for SwiftUI window frame and split view entries
            if key.contains("SwiftUI") && (key.hasPrefix("NSWindow Frame") || key.hasPrefix("NSSplitView")) {
                // Check if it contains oversized dimensions
                if let value = defaults.object(forKey: key) {
                    var shouldDelete = false

                    // For NSWindow Frame strings like "x y width height screenX screenY screenWidth screenHeight"
                    if let frameString = value as? String {
                        let parts = frameString.split(separator: " ").compactMap { Double($0) }
                        if parts.count >= 4 {
                            let width = parts[2]
                            let height = parts[3]
                            // If window is larger than current screen configuration
                            if width > maxAllowedWidth || height > maxAllowedHeight {
                                shouldDelete = true
                                appLogger.info("Removing oversized window frame: \(key.prefix(60))... (\(Int(width))x\(Int(height)) > \(Int(maxAllowedWidth))x\(Int(maxAllowedHeight)))")
                            }
                        }
                    }

                    // For NSSplitView arrays
                    if let frameArray = value as? [String] {
                        for frameString in frameArray {
                            let parts = frameString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            if parts.count >= 4,
                               let width = Double(parts[2]),
                               let height = Double(parts[3]) {
                                // If split view dimension is larger than current screen
                                if width > maxAllowedWidth || height > maxAllowedHeight {
                                    shouldDelete = true
                                    appLogger.info("Removing oversized split view: \(key.prefix(60))... (dim: \(Int(width))x\(Int(height)))")
                                    break
                                }
                            }
                        }
                    }

                    if shouldDelete {
                        defaults.removeObject(forKey: key)
                    }
                }
            }
        }
    }

    func application(_ application: NSApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        debugLog("Accepting CloudKit share invitation")
        let pc = PersistenceController.shared
        guard let ckContainer = pc.container as? NSPersistentCloudKitContainer,
              let sharedStore = pc.sharedStore else {
            debugLog("Cannot accept share: CloudKit container or shared store not available")
            return
        }
        ckContainer.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error {
                appLogger.error("Share accept failed: \(error.localizedDescription)")
            } else {
                appLogger.info("CloudKit share accepted successfully")
                NotificationCenter.default.post(name: .sharedLibraryAccepted, object: nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        debugLog("AppDelegate.application(open:) called with \(urls.count) URLs")
        for url in urls {
            debugLog("Processing URL: \(url.absoluteString)")
            if url.scheme == "imbib" {
                // Handle URL scheme (imbib://...)
                Task {
                    await URLSchemeHandler.shared.handle(url)
                }
            } else if url.isFileURL {
                // Handle file opening (via AirDrop, Finder double-click, etc.)
                handleFileOpen(url)
            }
        }
    }

    /// Handle opening of .imbib, .bib, and .ris files
    private func handleFileOpen(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        debugLog("Handling file open: \(url.lastPathComponent) (extension: \(ext))")

        switch ext {
        case "imbib", "bib", "bibtex", "ris":
            // Post notification to show unified import view with the file
            NotificationCenter.default.post(
                name: .showUnifiedImport,
                object: nil,
                userInfo: ["fileURL": url]
            )
        default:
            debugLog("Unhandled file extension: \(ext)")
        }
    }

    // MARK: - Handoff Support

    /// Handle incoming Handoff activities from other devices.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        debugLog("Received Handoff activity: \(userActivity.activityType)")

        switch userActivity.activityType {
        case HandoffService.readingActivityType:
            // Continue reading a PDF from another device
            if let session = HandoffService.parseReadingActivity(userActivity) {
                debugLog("Restoring reading session: \(session.citeKey) at page \(session.page)")
                NotificationCenter.default.post(
                    name: .restoreHandoffReading,
                    object: nil,
                    userInfo: [
                        "publicationID": session.publicationID.uuidString,
                        "citeKey": session.citeKey,
                        "page": session.page,
                        "zoom": session.zoom
                    ]
                )
                return true
            }

        case HandoffService.viewingActivityType:
            // Continue viewing a publication from another device
            if let (publicationID, citeKey) = HandoffService.parseViewingActivity(userActivity) {
                debugLog("Restoring viewing activity: \(citeKey)")
                NotificationCenter.default.post(
                    name: .restoreHandoffViewing,
                    object: nil,
                    userInfo: [
                        "publicationID": publicationID.uuidString,
                        "citeKey": citeKey
                    ]
                )
                return true
            }

        case CSSearchableItemActionType:
            // User tapped a Spotlight search result
            if let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let uuid = UUID(uuidString: identifier) {
                debugLog("Opening from Spotlight: \(identifier)")
                // Navigate to the paper via URL scheme
                Task {
                    await URLSchemeHandler.shared.handle(URL(string: "imbib://paper/\(uuid.uuidString)")!)
                }
                return true
            }

        default:
            break
        }

        return false
    }
}
#endif

@main
struct imbibApp: App {

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // MARK: - State

    @State private var libraryManager: LibraryManager
    @State private var libraryViewModel: LibraryViewModel
    @State private var searchViewModel: SearchViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var shareExtensionHandler: ShareExtensionHandler?

    /// Development mode: edit the bundled default library set
    private let isEditingDefaultSet: Bool

    // MARK: - Initialization

    /// Dependencies created during app initialization, used for async setup.
    private struct AppDependencies: Sendable {
        let credentialManager: CredentialManager
        let sourceManager: SourceManager
        let repository: PublicationRepository
        let deduplicationService: DeduplicationService
    }

    init() {
        let appStart = CFAbsoluteTimeGetCurrent()

        // Phase 1: Development mode flags (--edit-default-set, --show-welcome-screen, UI testing)
        isEditingDefaultSet = Self.setupDevelopmentModeFlags()
        appLogger.info("imbib app initializing...")

        // Phase 2: Data layer setup (migrations, Core Data, shared services)
        let deps = Self.setupDataLayer()

        // Phase 3: Initialize view models with dependencies
        let (libraryManager, libraryViewModel, searchViewModel, settingsViewModel) = Self.setupViewModels(deps: deps)
        _libraryManager = State(initialValue: libraryManager)
        _libraryViewModel = State(initialValue: libraryViewModel)
        _searchViewModel = State(initialValue: searchViewModel)
        _settingsViewModel = State(initialValue: settingsViewModel)

        // Phase 4: Set up notification observers for extensions
        Self.setupNotificationObservers()

        // Phase 5: Schedule background initialization (async)
        Self.scheduleBackgroundInit(deps: deps)

        appLogger.info("⏱ TOTAL app init: \(Int((CFAbsoluteTimeGetCurrent() - appStart) * 1000))ms")
    }

    // MARK: - Initialization Phases

    /// Phase 1: Set up development mode flags and handle special launch modes.
    /// Returns whether we're in edit-default-set mode.
    private static func setupDevelopmentModeFlags() -> Bool {
        #if os(macOS)
        let editingDefaultSet = CommandLine.arguments.contains("--edit-default-set")
        if editingDefaultSet {
            appLogger.info("Running in edit-default-set mode")
        }

        // Handle --show-welcome-screen flag (shows welcome screen without resetting data)
        if FirstRunManager.shouldShowWelcomeScreen {
            appLogger.info("--show-welcome-screen flag detected, will show welcome screen")
            // Set force flag so ContentView shows the onboarding sheet
            OnboardingManager.forceShowOnboarding = true
        }

        // Handle UI testing mode
        if UITestingConfiguration.isUITesting {
            UITestingConfiguration.logConfiguration()
            // Note: State reset is handled asynchronously in scheduleBackgroundInit
            // to avoid deadlock with @MainActor
        }

        return editingDefaultSet
        #else
        return false
        #endif
    }

    /// Phase 2: Set up the data layer and create shared dependencies.
    private static func setupDataLayer() -> AppDependencies {
        // Seed test data if requested in UI testing mode
        if UITestingEnvironment.isUITesting {
            TestDataSeeder.seedIfNeeded(context: PersistenceController.shared.viewContext)
        }

        // Create shared dependencies
        let stepStart = CFAbsoluteTimeGetCurrent()
        let credentialManager = CredentialManager.shared
        let sourceManager = SourceManager(credentialManager: credentialManager)
        let repository = PublicationRepository()
        let deduplicationService = DeduplicationService()
        appLogger.info("⏱ Created shared dependencies: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        return AppDependencies(
            credentialManager: credentialManager,
            sourceManager: sourceManager,
            repository: repository,
            deduplicationService: deduplicationService
        )
    }

    /// Phase 3: Initialize view models with dependencies.
    private static func setupViewModels(deps: AppDependencies) -> (
        LibraryManager,
        LibraryViewModel,
        SearchViewModel,
        SettingsViewModel
    ) {
        var stepStart = CFAbsoluteTimeGetCurrent()

        let libraryManager = LibraryManager()
        appLogger.info("⏱ LibraryManager initialized: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        stepStart = CFAbsoluteTimeGetCurrent()
        let libraryViewModel = LibraryViewModel(repository: deps.repository)
        let searchViewModel = SearchViewModel(
            sourceManager: deps.sourceManager,
            deduplicationService: deps.deduplicationService,
            repository: deps.repository
        )
        let settingsViewModel = SettingsViewModel(
            sourceManager: deps.sourceManager,
            credentialManager: deps.credentialManager
        )
        appLogger.info("⏱ ViewModels initialized: \(Int((CFAbsoluteTimeGetCurrent() - stepStart) * 1000))ms")

        return (libraryManager, libraryViewModel, searchViewModel, settingsViewModel)
    }

    /// Phase 4: Set up Darwin notification observers for extensions.
    /// Must be done early, before the app might receive notifications.
    private static func setupNotificationObservers() {
        appLogger.info("⏱ Before Darwin notification setup")
        ShareExtensionHandler.setupDarwinNotificationObserver()
        SafariImportHandler.shared.setupNotificationObserver()
        appLogger.info("⏱ After Darwin notification setup")
    }

    /// Phase 5: Schedule background initialization tasks.
    /// Runs asynchronously to avoid blocking app launch.
    private static func scheduleBackgroundInit(deps: AppDependencies) {
        Task {
            // Handle UI testing mode - reset state and seed data
            if UITestingConfiguration.isUITesting {
                if UITestingConfiguration.shouldResetState {
                    appLogger.info("UI Testing: resetting state")
                    try? await FirstRunManager.shared.resetToFirstRun()
                }
                await UITestingConfiguration.seedTestDataIfNeeded()
            }

            // Register File Provider domain
            do {
                try await FileProviderDomainManager.shared.registerDomain()
                appLogger.info("File Provider domain registered")
            } catch {
                appLogger.error("Failed to register File Provider domain: \(error.localizedDescription)")
            }

            // Initialize full-text search index
            await FullTextSearchService.shared.initialize()
            appLogger.info("Full-text search index initialized")

            // Deduplicate feeds (CloudKit sync can create duplicates)
            await MainActor.run {
                let duplicatesRemoved = FeedDeduplicationService.shared.deduplicateFeeds(
                    in: PersistenceController.shared.viewContext
                )
                if duplicatesRemoved > 0 {
                    appLogger.info("Feed deduplication: removed \(duplicatesRemoved) duplicate(s)")
                }
            }

            // Register built-in sources
            await deps.sourceManager.registerBuiltInSources()
            DragDropCoordinator.shared.sourceManager = deps.sourceManager
            await AutomationService.shared.configure(sourceManager: deps.sourceManager)
            appLogger.info("Built-in sources registered")

            // Register browser URL providers for interactive PDF downloads
            // Higher priority = tried first. ArXiv has highest priority (direct PDF, always free)
            await BrowserURLProviderRegistry.shared.register(ArXivSource.self, priority: 20)
            await BrowserURLProviderRegistry.shared.register(SciXSource.self, priority: 11)
            await BrowserURLProviderRegistry.shared.register(ADSSource.self, priority: 10)
            appLogger.info("BrowserURLProviders registered")

            // Configure staggered smart search refresh service (before InboxCoordinator)
            await SmartSearchRefreshService.shared.configure(
                sourceManager: deps.sourceManager,
                repository: deps.repository
            )
            appLogger.info("SmartSearchRefreshService configured")

            // Start background enrichment coordinator
            await EnrichmentCoordinator.shared.start()
            appLogger.info("EnrichmentCoordinator started")

            // Start Inbox coordinator (scheduling, fetch service)
            await InboxCoordinator.shared.start()
            appLogger.info("InboxCoordinator started")

            // Set up embedding service change observers for reactive index updates (ADR-022)
            await EmbeddingService.shared.setupChangeObservers()
            appLogger.info("EmbeddingService change observers set up")

            // Start HTTP automation server if enabled
            await HTTPAutomationServer.shared.start()
            if await HTTPAutomationServer.shared.running {
                appLogger.info("HTTP automation server started")
            }

            // Auto-build search indexes after a short delay (ADR-022)
            // This ensures Cmd+K global search works without manual setup
            try? await Task.sleep(for: .seconds(3))
            await autoPopulateSearchIndexesOnStartup()

            // Cleanup old exploration collections based on retention setting
            await cleanupExplorationCollectionsOnStartup()
        }
    }

    /// Cleanup old exploration collections based on user's retention setting.
    private static func cleanupExplorationCollectionsOnStartup() async {
        let retention = SyncedSettingsStore.shared.explorationRetention
        // Only cleanup if retention is time-based (not forever or sessionOnly)
        // sessionOnly is handled on app quit, forever keeps everything
        if let days = retention.days, days > 0 {
            await MainActor.run {
                let libraryManager = LibraryManager()
                libraryManager.cleanupExplorationCollections(olderThanDays: days)
            }
            appLogger.info("Exploration cleanup: retention=\(retention.rawValue)")
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .withTheme()
                .environment(libraryManager)
                .environment(libraryViewModel)
                .environment(searchViewModel)
                .environment(settingsViewModel)
                .task {
                    // Start heartbeat for SiblingDiscovery
                    Task.detached {
                        while !Task.isCancelled {
                            ImpressNotification.postHeartbeat(from: .imbib)
                            try? await Task.sleep(for: .seconds(25))
                        }
                    }
                }
                .onAppear {
                    ensureMainWindowVisible()
                    // Initialize share extension handler
                    if shareExtensionHandler == nil {
                        shareExtensionHandler = ShareExtensionHandler(
                            libraryManager: libraryManager,
                            sourceManager: searchViewModel.sourceManager
                        )
                    }
                    // Note: App Group access is deferred until the Safari extension is actually used.
                    // This avoids the TCC "access data from other apps" dialog at startup.
                    // When a Darwin notification arrives from the extension, we process imports
                    // and sync data back to the App Group at that time.
                }
                .onReceive(NotificationCenter.default.publisher(for: ShareExtensionService.sharedURLReceivedNotification)) { _ in
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                // Font size keyboard shortcut handlers
                .onReceive(NotificationCenter.default.publisher(for: .increaseFontSize)) { _ in
                    Task {
                        await ThemeSettingsStore.shared.increaseFontScale()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .decreaseFontSize)) { _ in
                    Task {
                        await ThemeSettingsStore.shared.decreaseFontScale()
                    }
                }
                #if os(macOS)
                // Clear exploration library on app quit if retention is "While App is Open"
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    if SyncedSettingsStore.shared.explorationRetention == .sessionOnly {
                        libraryManager.clearExplorationLibrary()
                        appLogger.info("Cleared exploration library on app termination (sessionOnly mode)")
                    }
                }
                #endif
                #if os(iOS)
                .onOpenURL { url in
                    // Handle Universal Links (https://imbib.app/...)
                    if UniversalLinksHandler.canHandle(url) {
                        if let command = UniversalLinksHandler.parse(url) {
                            Task {
                                await UniversalLinksHandler.handle(command)
                            }
                        }
                    } else if url.scheme == "imbib" {
                        // Handle automation URL schemes (imbib://...)
                        Task {
                            await URLSchemeHandler.shared.handle(url)
                        }
                    } else if url.isFileURL {
                        // Handle file opening (via AirDrop, Files app, etc.)
                        let ext = url.pathExtension.lowercased()
                        if ["imbib", "bib", "bibtex", "ris"].contains(ext) {
                            NotificationCenter.default.post(
                                name: .showUnifiedImport,
                                object: nil,
                                userInfo: ["fileURL": url]
                            )
                        }
                    }
                }
                // Handle Handoff: Continue reading PDF from another device
                .onContinueUserActivity(HandoffService.readingActivityType) { activity in
                    if let session = HandoffService.parseReadingActivity(activity) {
                        NotificationCenter.default.post(
                            name: .restoreHandoffReading,
                            object: nil,
                            userInfo: [
                                "publicationID": session.publicationID.uuidString,
                                "citeKey": session.citeKey,
                                "page": session.page,
                                "zoom": session.zoom
                            ]
                        )
                    }
                }
                // Handle Handoff: Continue viewing publication from another device
                .onContinueUserActivity(HandoffService.viewingActivityType) { activity in
                    if let (publicationID, citeKey) = HandoffService.parseViewingActivity(activity) {
                        NotificationCenter.default.post(
                            name: .restoreHandoffViewing,
                            object: nil,
                            userInfo: [
                                "publicationID": publicationID.uuidString,
                                "citeKey": citeKey
                            ]
                        )
                    }
                }
                // Handle Spotlight search results
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = UUID(uuidString: identifier) {
                        Task {
                            await URLSchemeHandler.shared.handle(URL(string: "imbib://paper/\(uuid.uuidString)")!)
                        }
                    }
                }
                #endif
        }
        .commands {
            AppCommands()
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(settingsViewModel)
                .environment(libraryManager)
        }

        Window("Console", id: "console") {
            ConsoleView()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .defaultSize(width: 800, height: 400)

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            KeyboardShortcutsView()
        }
        .keyboardShortcut("/", modifiers: .command)
        .defaultSize(width: 450, height: 700)

        Window("Help", id: "help") {
            HelpWindowView()
        }
        .defaultSize(width: 900, height: 700)
        #endif
    }

    // MARK: - Window Management

    #if os(macOS)
    /// Ensure the main window is visible and frontmost on launch
    private func ensureMainWindowVisible() {
        DispatchQueue.main.async {
            // Find the main window (the one with ContentView)
            if let mainWindow = NSApplication.shared.windows.first(where: { window in
                window.contentView?.subviews.contains(where: { $0.className.contains("ContentView") }) ?? false
                    || window.title.isEmpty || window.title == "imbib"
            }) {
                mainWindow.makeKeyAndOrderFront(nil)
                appLogger.info("Main window made visible and frontmost")
            } else if NSApplication.shared.windows.isEmpty {
                // No windows at all - this shouldn't happen with WindowGroup
                appLogger.warning("No windows found on launch")
            } else {
                // Fallback: make any non-console window visible
                for window in NSApplication.shared.windows {
                    if window.title != "Console" {
                        window.makeKeyAndOrderFront(nil)
                        appLogger.info("Made window '\(window.title)' visible")
                        break
                    }
                }
            }

            // Set up dock badge observer and initial badge
            setupDockBadge()
        }
    }

    /// Set up dock badge for Inbox unread count
    private func setupDockBadge() {
        // Set initial badge
        updateDockBadge(InboxManager.shared.unreadCount)

        // Observe unread count changes
        NotificationCenter.default.addObserver(
            forName: .inboxUnreadCountChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let count = notification.userInfo?["count"] as? Int {
                updateDockBadge(count)
            }
        }
    }
    #endif
}

#if os(macOS)
/// Update the dock badge with unread count
@MainActor
private func updateDockBadge(_ count: Int) {
    if count > 0 {
        NSApp.dockTile.badgeLabel = "\(count)"
    } else {
        NSApp.dockTile.badgeLabel = nil
    }
}
#endif

// MARK: - App Commands

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    /// Check if running in edit-default-set development mode
    private var isEditingDefaultSet: Bool {
        CommandLine.arguments.contains("--edit-default-set")
    }

    var body: some Commands {
        // Note: Settings menu is handled automatically by the Settings { } scene
        // Do not add a custom CommandGroup(replacing: .appSettings) as it creates duplicates

        // Development mode: Export default set
        if isEditingDefaultSet {
            CommandGroup(before: .newItem) {
                Button("Export as Default Library Set...") {
                    exportDefaultLibrarySet()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()
            }
        }

        // File menu
        CommandGroup(after: .newItem) {
            Button("Import...") {
                NotificationCenter.default.post(name: .showUnifiedImport, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command])

            Button("Export...") {
                NotificationCenter.default.post(name: .showUnifiedExport, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // Edit menu - context-aware pasteboard commands
        // When a text field has focus, use system clipboard; otherwise, use publication clipboard
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if TextFieldFocusDetection.isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .copyPublications, object: nil)
                }
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Copy as Citation") {
                NotificationCenter.default.post(name: .copyAsCitation, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Copy DOI/URL") {
                NotificationCenter.default.post(name: .copyIdentifier, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .option])

            Button("Cut") {
                if TextFieldFocusDetection.isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .cutPublications, object: nil)
                }
            }
            .keyboardShortcut("x", modifiers: .command)

            Button("Paste") {
                if TextFieldFocusDetection.isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .pastePublications, object: nil)
                }
            }
            .keyboardShortcut("v", modifiers: .command)

            Divider()

            Button("Select All") {
                if TextFieldFocusDetection.isTextFieldFocused() {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else {
                    NotificationCenter.default.post(name: .selectAllPublications, object: nil)
                }
            }
            .keyboardShortcut("a", modifiers: .command)

            Divider()

            // Find submenu (⌘F is handled by ContentView for global search)
            Menu("Find") {
                Button("Focus Search") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
            }
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button("Command Palette...") {
                NotificationCenter.default.post(name: .showCommandPalette, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Show Library") {
                NotificationCenter.default.post(name: .showLibrary, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Search") {
                NotificationCenter.default.post(name: .showSearch, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("Show Inbox") {
                NotificationCenter.default.post(name: .showInbox, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("Show PDF Tab") {
                NotificationCenter.default.post(name: .showPDFTab, object: nil)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("Show Notes Tab") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("Show BibTeX Tab") {
                NotificationCenter.default.post(name: .showBibTeXTab, object: nil)
            }
            .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button("Toggle Detail Pane") {
                NotificationCenter.default.post(name: .toggleDetailPane, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Divider()

            Button("Focus Sidebar") {
                NotificationCenter.default.post(name: .focusSidebar, object: nil)
            }
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button("Focus List") {
                NotificationCenter.default.post(name: .focusList, object: nil)
            }
            .keyboardShortcut("2", modifiers: [.command, .option])

            Button("Focus Detail") {
                NotificationCenter.default.post(name: .focusDetail, object: nil)
            }
            .keyboardShortcut("3", modifiers: [.command, .option])

            Divider()

            Button("Show Console") {
                openWindow(id: "console")
            }
            .keyboardShortcut("c", modifiers: [.control, .command])

            Divider()

            Button("Increase Text Size") {
                NotificationCenter.default.post(name: .increaseFontSize, object: nil)
            }
            .keyboardShortcut("=", modifiers: [.command, .shift])

            Button("Decrease Text Size") {
                NotificationCenter.default.post(name: .decreaseFontSize, object: nil)
            }
            .keyboardShortcut("-", modifiers: [.command, .shift])
        }

        // Paper menu (new)
        CommandMenu("Paper") {
            Button("Open PDF") {
                NotificationCenter.default.post(name: .openSelectedPaper, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Open Notes") {
                NotificationCenter.default.post(name: .showNotesTab, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Open References") {
                NotificationCenter.default.post(name: .openReferences, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Toggle Read/Unread") {
                NotificationCenter.default.post(name: .toggleReadStatus, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Button("Mark All as Read") {
                NotificationCenter.default.post(name: .markAllAsRead, object: nil)
            }
            .keyboardShortcut("u", modifiers: [.command, .option])

            Divider()

            Button("Save to Library") {
                NotificationCenter.default.post(name: .saveToLibrary, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button("Dismiss from Inbox") {
                NotificationCenter.default.post(name: .dismissFromInbox, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Divider()

            Button("Move to Collection...") {
                NotificationCenter.default.post(name: .moveToCollection, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.control, .command])

            Button("Add to Collection...") {
                NotificationCenter.default.post(name: .addToCollection, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Remove from Collection") {
                NotificationCenter.default.post(name: .removeFromCollection, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Share...") {
                NotificationCenter.default.post(name: .sharePapers, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Button("Send to E-Ink Device") {
                NotificationCenter.default.post(name: .sendToEInkDevice, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.control, .command])

            Button("Sync E-Ink Annotations") {
                NotificationCenter.default.post(name: .syncEInkAnnotations, object: nil)
            }

            Divider()

            Button("Delete") {
                NotificationCenter.default.post(name: .deleteSelectedPapers, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        // Annotate menu (PDF annotations)
        CommandMenu("Annotate") {
            Button("Highlight Selection") {
                NotificationCenter.default.post(name: .highlightSelection, object: nil)
            }
            .keyboardShortcut("h", modifiers: .control)

            Button("Underline Selection") {
                NotificationCenter.default.post(name: .underlineSelection, object: nil)
            }
            .keyboardShortcut("u", modifiers: .control)

            Button("Strikethrough Selection") {
                NotificationCenter.default.post(name: .strikethroughSelection, object: nil)
            }
            .keyboardShortcut("t", modifiers: .control)

            Divider()

            Button("Add Note at Selection") {
                NotificationCenter.default.post(name: .addNoteAtSelection, object: nil)
            }
            .keyboardShortcut("n", modifiers: .control)

            Divider()

            Menu("Highlight Color") {
                Button("Yellow") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "yellow"]
                    )
                }
                Button("Green") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "green"]
                    )
                }
                Button("Blue") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "blue"]
                    )
                }
                Button("Pink") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "pink"]
                    )
                }
                Button("Purple") {
                    NotificationCenter.default.post(
                        name: .highlightSelection,
                        object: nil,
                        userInfo: ["color": "purple"]
                    )
                }
            }
        }

        // Go menu (new)
        CommandMenu("Go") {
            Button("Back") {
                NotificationCenter.default.post(name: .navigateBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Forward") {
                NotificationCenter.default.post(name: .navigateForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            // Note: Arrow key shortcuts are handled via .onKeyPress() in ContentView
            // to allow text fields to capture them when focused
            Button("Next Paper") {
                NotificationCenter.default.post(name: .navigateNextPaper, object: nil)
            }

            Button("Previous Paper") {
                NotificationCenter.default.post(name: .navigatePreviousPaper, object: nil)
            }

            Button("First Paper") {
                NotificationCenter.default.post(name: .navigateFirstPaper, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Last Paper") {
                NotificationCenter.default.post(name: .navigateLastPaper, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("Next Unread") {
                NotificationCenter.default.post(name: .navigateNextUnread, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: .option)

            Button("Previous Unread") {
                NotificationCenter.default.post(name: .navigatePreviousUnread, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .option)

            Divider()

            // Note: Vim shortcuts (j/k for papers, Option+j/k for unread, h/l for tabs)
            // are handled via .onKeyPress() to allow text fields to capture them when focused

            Button("Previous Tab") {
                NotificationCenter.default.post(name: .showPreviousDetailTab, object: nil)
            }

            Button("Next Tab") {
                NotificationCenter.default.post(name: .showNextDetailTab, object: nil)
            }

            Divider()

            Button("Go to Page...") {
                NotificationCenter.default.post(name: .pdfGoToPage, object: nil)
            }
            .keyboardShortcut("g", modifiers: .command)
        }

        // Window menu additions
        CommandGroup(after: .windowArrangement) {
            Divider()

            Button("Refresh") {
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Toggle Unread Filter") {
                NotificationCenter.default.post(name: .toggleUnreadFilter, object: nil)
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Toggle PDF Filter") {
                NotificationCenter.default.post(name: .togglePDFFilter, object: nil)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            Divider()

            // Fullscreen window commands (Shift+letter shortcuts)
            Button("Open PDF in Fullscreen") {
                NotificationCenter.default.post(name: .detachPDFTab, object: nil)
            }
            .keyboardShortcut("p", modifiers: .shift)

            Button("Open Notes in Fullscreen") {
                NotificationCenter.default.post(name: .detachNotesTab, object: nil)
            }
            .keyboardShortcut("n", modifiers: .shift)

            Button("Open Info in Fullscreen") {
                NotificationCenter.default.post(name: .detachInfoTab, object: nil)
            }
            .keyboardShortcut("i", modifiers: .shift)

            Button("Open BibTeX in Fullscreen") {
                NotificationCenter.default.post(name: .detachBibTeXTab, object: nil)
            }
            .keyboardShortcut("b", modifiers: .shift)

            Button("Flip Window Positions") {
                NotificationCenter.default.post(name: .flipWindowPositions, object: nil)
            }
            .keyboardShortcut("f", modifiers: .shift)

            Button("Close Detached Windows") {
                NotificationCenter.default.post(name: .closeDetachedWindows, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift, .option])
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Button("imbib Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Search Help...") {
                NotificationCenter.default.post(name: .showHelpSearchPalette, object: nil)
            }
            .keyboardShortcut("?", modifiers: [.command, .shift])

            Divider()

            Button("Keyboard Shortcuts") {
                openWindow(id: "keyboard-shortcuts")
            }
            .keyboardShortcut("/", modifiers: .command)

            Divider()

            Button("Online Documentation") {
                if let url = URL(string: "https://yipihey.github.io/impress-apps/") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("What's New") {
                if let url = URL(string: "https://github.com/yipihey/impress-apps/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Report an Issue...") {
                if let url = URL(string: "https://github.com/yipihey/impress-apps/issues") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Release Notes") {
                if let url = URL(string: "https://github.com/yipihey/impress-apps/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Export current libraries as a default library set (development mode)
    private func exportDefaultLibrarySet() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DefaultLibrarySet.json"
        panel.message = "Export current libraries as the default set for new users"
        panel.prompt = "Export"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                do {
                    try DefaultLibrarySetManager.shared.exportCurrentAsDefaultSet(to: url)
                    appLogger.info("Exported default library set to: \(url.lastPathComponent)")

                    // Show success alert
                    let alert = NSAlert()
                    alert.messageText = "Export Successful"
                    alert.informativeText = "Default library set exported to \(url.lastPathComponent)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } catch {
                    appLogger.error("Failed to export default library set: \(error.localizedDescription)")

                    // Show error alert
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
        #endif
    }

    /// Toggle the settings window - close if open, open if closed.
    private func toggleSettingsWindow() {
        #if os(macOS)
        // Find the settings window by checking the SwiftUI Settings identifier specifically
        // Be very strict to avoid accidentally matching other windows
        let settingsWindow = NSApp.windows.first(where: { window in
            guard let identifier = window.identifier?.rawValue else { return false }
            // Only match the exact SwiftUI Settings window identifiers
            return identifier == "com_apple_SwiftUI_Settings_window" ||
                   identifier.hasPrefix("com.apple.SwiftUI.Settings")
        })

        if let window = settingsWindow, window.isVisible {
            window.close()
            return
        }

        // Open settings using the standard macOS action
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        #endif
    }
}

// Note: Notification.Name extensions are now defined in PublicationManagerCore/Notifications.swift

// MARK: - Auto-populate Search Indexes

/// Auto-populate search indexes if needed on startup.
///
/// Builds the embedding index for semantic search (Cmd+K global search).
/// Called a few seconds after startup to avoid blocking the UI.
private func autoPopulateSearchIndexesOnStartup() async {
    // Only build if embedding service is available and index is not yet built
    let embeddingAvailable = await EmbeddingService.shared.isAvailable
    let hasEmbeddingIndex = await EmbeddingService.shared.hasIndex

    if embeddingAvailable && !hasEmbeddingIndex {
        logInfo("Auto-building embedding index for global search...", category: "embedding")

        // Fetch all user libraries from Core Data (excluding system libraries)
        let libraries = await MainActor.run {
            let context = PersistenceController.shared.viewContext
            let request = NSFetchRequest<CDLibrary>(entityName: "Library")
            // Exclude system libraries: Dismissed, Exploration, and any marked as system
            request.predicate = NSPredicate(
                format: "name != %@ AND name != %@ AND isSystemLibrary == NO",
                "Dismissed", "Exploration"
            )
            return (try? context.fetch(request)) ?? []
        }

        if !libraries.isEmpty {
            let count = await EmbeddingService.shared.buildIndex(from: libraries)
            logInfo("Auto-built embedding index with \(count) publications from \(libraries.count) libraries", category: "embedding")
        }
    }
}
