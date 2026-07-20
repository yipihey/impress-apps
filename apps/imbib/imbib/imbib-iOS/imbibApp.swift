//
//  imbibApp.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import OSLog
import UserNotifications
import AppIntents

private let appLogger = Logger(subsystem: "com.imbib.app", category: "app")

@main
struct imbibApp: App {

    // MARK: - State

    @State private var libraryManager: LibraryManager
    @State private var libraryViewModel: LibraryViewModel
    @State private var searchViewModel: SearchViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var smartSearchService = SmartSearchService()
    @State private var shareExtensionHandler: ShareExtensionHandler?

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Initialization

    init() {
        appLogger.info("imbib iOS app initializing...")

        // Use shared credential manager singleton for persistence
        let credentialManager = CredentialManager.shared
        let sourceManager = SourceManager(credentialManager: credentialManager)
        let deduplicationService = DeduplicationService()

        appLogger.info("Created shared dependencies")

        // Initialize LibraryManager first
        _libraryManager = State(initialValue: LibraryManager())

        appLogger.info("LibraryManager initialized")

        // Initialize ViewModels
        _libraryViewModel = State(initialValue: LibraryViewModel())
        _searchViewModel = State(initialValue: SearchViewModel(
            sourceManager: sourceManager,
            deduplicationService: deduplicationService
        ))
        _settingsViewModel = State(initialValue: SettingsViewModel(
            sourceManager: sourceManager,
            credentialManager: credentialManager
        ))

        appLogger.info("ViewModels initialized")

        // UI-testing: seed a deterministic in-memory store *synchronously* so
        // XCUITests have stable anchors before any view queries the store.
        // Gated on launch args (`--ui-testing --uitesting-seed`); a no-op in
        // production. `RustStoreAdapter.shared` already routes to an in-memory
        // store under `--ui-testing`, so this never touches real user data.
        // (The iOS app previously had no UI-test seeding path at all — the
        // `shouldSeedTestData` flag existed but nothing consumed it.)
        Self.seedUITestDataIfNeeded()

        // UI-testing: skip the first-run onboarding sheet so the main split
        // view is reachable immediately. The in-memory store starts fresh on
        // every launch, so onboarding would otherwise always present and cover
        // the UI. Gated on `--ui-testing`; a no-op in production.
        if UITestingEnvironment.isUITesting {
            OnboardingManager.shared.completeOnboarding()
        }

        // Capture libraryManager for use in Task (can't capture self in struct)
        let capturedLibraryManager = libraryManager

        // Register built-in sources and start enrichment
        Task {
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

            await sourceManager.registerBuiltInSources()
            DragDropCoordinator.shared.sourceManager = sourceManager
            appLogger.info("Built-in sources registered")

            // Register browser URL providers for interactive PDF downloads
            // Higher priority = tried first. ArXiv has highest priority (direct PDF, always free)
            await BrowserURLProviderRegistry.shared.register(ArXivSource.self, priority: 20)
            await BrowserURLProviderRegistry.shared.register(ADSSource.self, priority: 10)
            appLogger.info("BrowserURLProviders registered")

            // Start background enrichment coordinator
            await EnrichmentCoordinator.shared.start()
            appLogger.info("EnrichmentCoordinator started")

            // Start Inbox coordinator (scheduling, fetch service)
            await InboxCoordinator.shared.start()
            appLogger.info("InboxCoordinator started")

            // Set up embedding service change observers for reactive index updates (ADR-022)
            await EmbeddingService.shared.setupChangeObservers()
            appLogger.info("EmbeddingService change observers set up")

            // Auto-build search indexes after a short delay (ADR-022)
            // This ensures global search works without manual setup
            Task {
                try? await Task.sleep(for: .seconds(3))
                await autoPopulateSearchIndexesOnStartup()
            }

            // Cleanup old exploration collections based on retention setting
            await cleanupExplorationCollectionsOnStartup(libraryManager: capturedLibraryManager)
        }

        // Request notification permissions for badge.
        // Skipped under UI testing so the system permission alert doesn't
        // block the automation session.
        if !UITestingEnvironment.isUITesting {
            requestNotificationPermissions()
        }

        appLogger.info("imbib iOS app initialization complete")
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            IOSContentView()
                .withTheme()
                .environment(libraryManager)
                .environment(libraryViewModel)
                .environment(searchViewModel)
                .environment(smartSearchService)
                .environment(settingsViewModel)
                .onAppear {
                    // Wire SmartSearch to the user's "Save" library so Cmd+S
                    // imports land in the same place as inbox-triage `s`.
                    smartSearchService.libraryManager = libraryManager

                    // Skip badge setup under UI testing: `setBadgeCount` triggers
                    // the notification-authorization system alert on iOS 17+,
                    // which would block the automation session.
                    if !UITestingEnvironment.isUITesting {
                        setupBadgeObserver()
                    }
                    // Initialize share extension handler
                    if shareExtensionHandler == nil {
                        shareExtensionHandler = ShareExtensionHandler(
                            libraryManager: libraryManager,
                            sourceManager: searchViewModel.sourceManager
                        )
                    }
                    // Process any pending shared URLs from share extension
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: ShareExtensionService.sharedURLReceivedNotification)) { _ in
                    Task {
                        await shareExtensionHandler?.handlePendingSharedItems()
                    }
                }
                .onOpenURL { url in
                    // Handle automation URL scheme requests
                    Task {
                        await URLSchemeHandler.shared.handle(url)
                    }
                }
                // Clear exploration library when going to background if retention is "While App is Open"
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background && SyncedSettingsStore.shared.explorationRetention == .sessionOnly {
                        libraryManager.clearExplorationLibrary()
                        appLogger.info("Cleared exploration library on background (sessionOnly mode)")
                    }
                }
        }
    }

    // MARK: - App Shortcuts

    /// Expose shortcuts provider for Siri and Shortcuts app discovery.
    /// This ensures the intents are linked into the app binary.
    @available(iOS 16.0, *)
    private static let _shortcutsProvider: any AppShortcutsProvider.Type = ImbibShortcuts.self

    // MARK: - UI Testing Seed

    /// Seed a small deterministic library for XCUITests.
    ///
    /// Only runs when launched with `--ui-testing --uitesting-seed`. The
    /// in-memory store (enabled by `--ui-testing`) starts empty, so this
    /// gives the UI-test target stable anchors: a library named
    /// "Test Library" with two well-known publications. Runs synchronously
    /// during `init()` so the store is populated before any view's `.task`
    /// reads it (avoiding a load/seed race).
    @MainActor
    private static func seedUITestDataIfNeeded() {
        guard UITestingEnvironment.isUITesting, UITestingEnvironment.shouldSeedTestData else { return }
        let store = RustStoreAdapter.shared
        // Idempotent: never double-seed an already-populated store.
        guard store.listLibraries().isEmpty else {
            appLogger.info("UI-testing seed: store already populated, skipping")
            return
        }
        guard let library = store.createLibrary(name: "Test Library") else {
            appLogger.error("UI-testing seed: failed to create Test Library")
            return
        }
        store.setLibraryDefault(id: library.id)

        let bibtex = """
        @article{Einstein1905,
            author = {Albert Einstein},
            title = {On the Electrodynamics of Moving Bodies},
            journal = {Annalen der Physik},
            year = {1905}
        }

        @article{Hubble1929,
            author = {Edwin Hubble},
            title = {A Relation between Distance and Radial Velocity among Extra-Galactic Nebulae},
            journal = {Proceedings of the National Academy of Sciences},
            year = {1929}
        }
        """
        let ids = store.importBibTeX(bibtex, libraryId: library.id)
        appLogger.info("UI-testing seed: imported \(ids.count) papers into '\(library.name)'")
    }

    // MARK: - Badge Management

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { granted, error in
            if granted {
                appLogger.info("Badge notification permission granted")
            } else if let error = error {
                appLogger.error("Badge permission error: \(error.localizedDescription)")
            }
        }
    }

    private func setupBadgeObserver() {
        // Set initial badge
        updateAppBadge(InboxManager.shared.unreadCount)

        // Observe unread count changes
        NotificationCenter.default.addObserver(
            forName: .inboxUnreadCountChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let count = notification.userInfo?["count"] as? Int {
                updateAppBadge(count)
            }
        }
    }
}

/// Update the app icon badge with unread count
private func updateAppBadge(_ count: Int) {
    UNUserNotificationCenter.current().setBadgeCount(count) { error in
        if let error = error {
            appLogger.error("Failed to set badge: \(error.localizedDescription)")
        }
    }
}

// MARK: - Exploration Cleanup

/// Cleanup old exploration collections based on user's retention setting.
private func cleanupExplorationCollectionsOnStartup(libraryManager: LibraryManager) async {
    let retention = SyncedSettingsStore.shared.explorationRetention
    // Only cleanup if retention is time-based (not forever or sessionOnly)
    // sessionOnly is handled when going to background, forever keeps everything
    if let days = retention.days, days > 0 {
        await MainActor.run {
            libraryManager.cleanupExplorationCollections(olderThanDays: days)
        }
        appLogger.info("Exploration cleanup: retention=\(retention.rawValue)")
    }
}

// MARK: - Auto-populate Search Indexes

/// Auto-populate search indexes if needed on startup.
///
/// Builds the embedding index for semantic search.
/// Called a few seconds after startup to avoid blocking the UI.
private func autoPopulateSearchIndexesOnStartup() async {
    // Only build if embedding service is available and index is not yet built
    let embeddingAvailable = await EmbeddingService.shared.isAvailable
    let hasEmbeddingIndex = await EmbeddingService.shared.hasIndex

    if embeddingAvailable && !hasEmbeddingIndex {
        appLogger.info("Embedding index not yet built — will be built on demand")
    } else if !embeddingAvailable {
        appLogger.debug("Embedding service not available, skipping auto-index")
    } else {
        appLogger.debug("Embedding index already built, skipping auto-index")
    }
}
