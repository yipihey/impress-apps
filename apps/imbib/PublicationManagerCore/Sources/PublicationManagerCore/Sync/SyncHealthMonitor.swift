//
//  SyncHealthMonitor.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-28.
//

import Foundation
import Combine
import OSLog
#if canImport(CloudKit)
import CloudKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Observable health monitor for CloudKit sync status.
///
/// Provides real-time updates on sync health, including:
/// - Last sync time
/// - Pending upload/download counts
/// - Unresolved conflicts
/// - CloudKit quota usage
/// - Actionable issues with resolution steps
///
/// # Usage
///
/// ```swift
/// struct SyncHealthView: View {
///     var health = SyncHealthMonitor.shared
///
///     var body: some View {
///         if health.hasIssues {
///             // Show issues
///         }
///     }
/// }
/// ```
@MainActor
@Observable
public final class SyncHealthMonitor {

    // MARK: - Singleton

    public static let shared = SyncHealthMonitor()

    // MARK: - Observable Properties

    /// Last successful sync date.
    public private(set) var lastSyncDate: Date?

    /// Number of items pending upload.
    public private(set) var pendingUploadCount: Int = 0

    /// Number of items pending download.
    public private(set) var pendingDownloadCount: Int = 0

    /// Number of unresolved sync conflicts.
    public private(set) var unresolvedConflictCount: Int = 0

    /// CloudKit quota usage (0.0 to 1.0, or nil if unknown).
    public private(set) var quotaUsage: Double?

    /// Whether CloudKit sync is enabled.
    public private(set) var isSyncEnabled: Bool = true

    /// Whether sync is currently in progress.
    public private(set) var isSyncing: Bool = false

    /// Current issues requiring user attention.
    public private(set) var issues: [SyncHealthIssue] = []

    /// Overall health status.
    public private(set) var status: SyncHealthStatus = .healthy

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private let syncSettingsStore: CloudKitSyncSettingsStore

    // MARK: - Initialization

    private init() {
        self.syncSettingsStore = CloudKitSyncSettingsStore.shared

        // Load initial state
        loadInitialState()

        // Observe sync notifications
        setupNotificationObservers()

        // Observe sync conflict queue
        observeConflictQueue()
    }

    // MARK: - Public API

    /// Whether there are any issues requiring attention.
    public var hasIssues: Bool {
        !issues.isEmpty
    }

    /// Force a refresh of sync health data.
    public func refresh() async {
        await updateQuotaUsage()
        updateFromSyncSettings()
        updateStatus()
    }

    /// Attempt to resolve an issue.
    public func resolveIssue(_ issue: SyncHealthIssue) async {
        switch issue.type {
        case .conflict:
            // Navigate to conflict resolution view
            NotificationCenter.default.post(name: .navigateToConflictResolution, object: nil)

        case .syncPaused:
            // Resume sync
            syncSettingsStore.isDisabledByUser = false
            updateFromSyncSettings()

        case .quotaWarning, .quotaExceeded:
            // Open iCloud settings
            #if os(macOS)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.icloud") {
                NSWorkspace.shared.open(url)
            }
            #endif

        case .networkError:
            // Trigger manual sync
            await triggerManualSync()

        case .schemaVersionMismatch:
            // Open App Store for update
            #if os(macOS)
            if let url = URL(string: "macappstore://apps.apple.com/app/id123456789") {
                NSWorkspace.shared.open(url)
            }
            #endif

        case .outdatedBackup:
            // Trigger backup
            NotificationCenter.default.post(name: .showBackupPrompt, object: nil)
        }

        // Remove the issue after attempting resolution
        issues.removeAll { $0.id == issue.id }
        updateStatus()
    }

    // MARK: - Private Methods

    private func loadInitialState() {
        lastSyncDate = syncSettingsStore.lastSyncDate
        isSyncEnabled = !syncSettingsStore.isDisabledByUser

        if let error = syncSettingsStore.lastError {
            addIssue(SyncHealthIssue(
                type: .networkError,
                severity: .warning,
                title: "Sync Error",
                description: error,
                suggestedAction: "Try syncing again"
            ))
        }

        updateStatus()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .syncDidComplete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSyncCompleted()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncDidFail)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let error = notification.object as? Error {
                    self?.handleSyncFailed(error)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncDidStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isSyncing = true
            }
            .store(in: &cancellables)
    }

    private func observeConflictQueue() {
        // Observe conflict queue changes
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateConflictCount()
            }
            .store(in: &cancellables)
    }

    private func handleSyncCompleted() {
        isSyncing = false
        lastSyncDate = Date()
        syncSettingsStore.recordSuccessfulSync()

        // Clear network-related issues
        issues.removeAll { $0.type == .networkError }
        updateStatus()
    }

    private func handleSyncFailed(_ error: Error) {
        isSyncing = false

        let issue = SyncHealthIssue(
            type: .networkError,
            severity: .warning,
            title: "Sync Failed",
            description: error.localizedDescription,
            suggestedAction: "Check your network connection and try again"
        )
        addIssue(issue)
        updateStatus()
    }

    private func updateConflictCount() {
        let count = SyncConflictQueue.shared.count
        unresolvedConflictCount = count

        if count > 0 {
            addIssue(SyncHealthIssue(
                type: .conflict,
                severity: .attention,
                title: "\(count) Unresolved Conflict\(count == 1 ? "" : "s")",
                description: "Some publications have conflicting changes from other devices",
                suggestedAction: "Review and resolve conflicts"
            ))
        } else {
            issues.removeAll { $0.type == .conflict }
        }
        updateStatus()
    }

    private func updateFromSyncSettings() {
        isSyncEnabled = !syncSettingsStore.isDisabledByUser
        lastSyncDate = syncSettingsStore.lastSyncDate

        if !isSyncEnabled {
            addIssue(SyncHealthIssue(
                type: .syncPaused,
                severity: .info,
                title: "Sync Paused",
                description: "iCloud sync is currently disabled",
                suggestedAction: "Enable sync to keep your library in sync across devices"
            ))
        } else {
            issues.removeAll { $0.type == .syncPaused }
        }
    }

    private func updateQuotaUsage() async {
        #if canImport(CloudKit)
        do {
            let container = CKContainer(identifier: "iCloud.com.imbib.app")
            let accountStatus = try await container.accountStatus()

            if accountStatus != .available {
                quotaUsage = nil
                return
            }

            // Note: CloudKit doesn't provide direct quota API
            // This would require tracking upload sizes manually
            // For now, set to nil (unknown)
            quotaUsage = nil

        } catch {
            Logger.sync.warning("Failed to check CloudKit status: \(error.localizedDescription)")
        }
        #endif
    }

    private func triggerManualSync() async {
        do {
            try await SyncService.shared.triggerSync()
        } catch {
            handleSyncFailed(error)
        }
    }

    private func addIssue(_ issue: SyncHealthIssue) {
        // Replace existing issue of same type
        issues.removeAll { $0.type == issue.type }
        issues.append(issue)
    }

    private func updateStatus() {
        if issues.contains(where: { $0.severity == .critical }) {
            status = .critical
        } else if issues.contains(where: { $0.severity == .warning }) {
            status = .degraded
        } else if issues.contains(where: { $0.severity == .attention }) {
            status = .attention
        } else if !isSyncEnabled {
            status = .disabled
        } else {
            status = .healthy
        }
    }
}

// MARK: - Supporting Types

/// Overall sync health status.
public enum SyncHealthStatus: String, Sendable {
    /// Everything is working normally.
    case healthy

    /// Sync is working but needs attention.
    case attention

    /// Sync is degraded due to warnings.
    case degraded

    /// Critical issue preventing sync.
    case critical

    /// Sync is disabled by user.
    case disabled

    /// SF Symbol name for this status.
    public var iconName: String {
        switch self {
        case .healthy:
            return "checkmark.icloud"
        case .attention:
            return "exclamationmark.icloud"
        case .degraded:
            return "exclamationmark.triangle"
        case .critical:
            return "xmark.icloud"
        case .disabled:
            return "icloud.slash"
        }
    }

    /// Color for this status.
    public var color: String {
        switch self {
        case .healthy:
            return "green"
        case .attention:
            return "yellow"
        case .degraded:
            return "orange"
        case .critical:
            return "red"
        case .disabled:
            return "gray"
        }
    }

    /// Human-readable description.
    public var description: String {
        switch self {
        case .healthy:
            return "Sync is healthy"
        case .attention:
            return "Needs attention"
        case .degraded:
            return "Sync degraded"
        case .critical:
            return "Sync unavailable"
        case .disabled:
            return "Sync disabled"
        }
    }
}

/// An issue that requires user attention.
public struct SyncHealthIssue: Identifiable, Sendable {
    public let id = UUID()
    public let type: IssueType
    public let severity: Severity
    public let title: String
    public let description: String
    public let suggestedAction: String
    public let createdAt: Date = Date()

    public enum IssueType: Sendable {
        case conflict
        case syncPaused
        case quotaWarning
        case quotaExceeded
        case networkError
        case schemaVersionMismatch
        case outdatedBackup
    }

    public enum Severity: Int, Comparable, Sendable {
        case info = 0
        case attention = 1
        case warning = 2
        case critical = 3

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// Posted when sync completes successfully.
    static let syncDidComplete = Notification.Name("syncDidComplete")

    /// Posted when sync fails.
    static let syncDidFail = Notification.Name("syncDidFail")

    /// Posted when sync starts.
    static let syncDidStart = Notification.Name("syncDidStart")

    /// Posted to navigate to conflict resolution.
    static let navigateToConflictResolution = Notification.Name("navigateToConflictResolution")

    /// Posted to show backup prompt.
    static let showBackupPrompt = Notification.Name("showBackupPrompt")
}

// NOTE: Logger.sync is defined in Logger+Extensions.swift
