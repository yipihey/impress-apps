//
//  WidgetDataStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Widget Data Store

/// Manages data sharing between the main app and widget extensions.
///
/// Uses App Groups (`group.com.imbib.app`) to store lightweight data that
/// widgets can read. The main app writes to this store, and widgets read
/// from it via their TimelineProvider.
///
/// Features:
/// - Inbox statistics (unread count, total count)
/// - Current reading session
/// - Paper of the day
/// - Recent papers list
/// - Automatic widget timeline refresh
///
/// Usage in main app:
/// ```swift
/// // Update inbox count
/// await WidgetDataStore.shared.updateInboxStats(unread: 5, total: 12)
///
/// // Update reading session
/// await WidgetDataStore.shared.updateReadingSession(session)
/// ```
///
/// Usage in widget:
/// ```swift
/// // Read inbox stats
/// let stats = WidgetDataStore.shared.inboxStats
/// ```
@MainActor
public final class WidgetDataStore {

    // MARK: - Singleton

    public static let shared = WidgetDataStore()

    // MARK: - Constants

    /// App Group identifier for data sharing
    public static let appGroupID = "group.com.imbib.app"

    // UserDefaults keys
    private enum Keys {
        static let inboxStats = "widget.inboxStats"
        static let readingSession = "widget.readingSession"
        static let paperOfDay = "widget.paperOfDay"
        static let recentPapers = "widget.recentPapers"
        static let lastSyncDate = "widget.lastSyncDate"
    }

    // MARK: - Properties

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupID)
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Initialization

    private init() {
        Logger.widgets.info("Widget data store initialized with group: \(Self.appGroupID)")
    }

    // MARK: - Inbox Stats

    /// Current inbox statistics.
    ///
    /// Read this from widgets to display inbox count.
    public var inboxStats: WidgetInboxStats? {
        guard let data = defaults?.data(forKey: Keys.inboxStats) else { return nil }
        return try? decoder.decode(WidgetInboxStats.self, from: data)
    }

    /// Update inbox statistics.
    ///
    /// Call this from `InboxManager` when unread count changes.
    ///
    /// - Parameters:
    ///   - unread: Number of unread papers
    ///   - total: Total number of papers in inbox
    public func updateInboxStats(unread: Int, total: Int) {
        let stats = WidgetInboxStats(
            unreadCount: unread,
            totalCount: total,
            lastUpdateDate: Date()
        )

        if let data = try? encoder.encode(stats) {
            defaults?.set(data, forKey: Keys.inboxStats)
            Logger.widgets.debug("Updated inbox stats: \(unread) unread / \(total) total")
            reloadWidgetTimeline(kind: WidgetKind.inboxCount)
        }
    }

    // MARK: - Reading Session

    /// Current reading session.
    ///
    /// Read this from widgets to show reading progress.
    public var readingSession: WidgetReadingSession? {
        guard let data = defaults?.data(forKey: Keys.readingSession) else { return nil }
        return try? decoder.decode(WidgetReadingSession.self, from: data)
    }

    /// Update the current reading session.
    ///
    /// Call this from `PDFViewerWithControls` when reading position changes.
    ///
    /// - Parameter session: The current reading session, or nil to clear
    public func updateReadingSession(_ session: WidgetReadingSession?) {
        if let session = session,
           let data = try? encoder.encode(session) {
            defaults?.set(data, forKey: Keys.readingSession)
            Logger.widgets.debug("Updated reading session: \(session.paper.citeKey) page \(session.currentPage)/\(session.totalPages)")
        } else {
            defaults?.removeObject(forKey: Keys.readingSession)
            Logger.widgets.debug("Cleared reading session")
        }
        reloadWidgetTimeline(kind: WidgetKind.readingProgress)
    }

    /// Clear the reading session.
    ///
    /// Call this when the user closes the PDF.
    public func clearReadingSession() {
        defaults?.removeObject(forKey: Keys.readingSession)
        reloadWidgetTimeline(kind: WidgetKind.readingProgress)
    }

    // MARK: - Paper of the Day

    /// Current paper of the day.
    ///
    /// Read this from widgets to display a featured paper.
    public var paperOfDay: WidgetPaperOfDay? {
        guard let data = defaults?.data(forKey: Keys.paperOfDay) else { return nil }
        let paper = try? decoder.decode(WidgetPaperOfDay.self, from: data)
        // Return nil if not from today
        if let paper = paper, !paper.isToday {
            return nil
        }
        return paper
    }

    /// Set the paper of the day.
    ///
    /// Call this once per day to feature a paper in widgets.
    ///
    /// - Parameters:
    ///   - paper: The paper to feature
    ///   - reason: Why this paper was selected (e.g., "Recent addition", "Unread in inbox")
    public func setPaperOfDay(_ paper: WidgetPaper, reason: String) {
        let potd = WidgetPaperOfDay(paper: paper, reason: reason)

        if let data = try? encoder.encode(potd) {
            defaults?.set(data, forKey: Keys.paperOfDay)
            Logger.widgets.info("Set paper of day: \(paper.citeKey) - \(reason)")
            reloadWidgetTimeline(kind: WidgetKind.paperOfDay)
        }
    }

    // MARK: - Recent Papers

    /// Recent papers list for widgets.
    ///
    /// Read this from widgets to display a list of recent additions.
    public var recentPapers: [WidgetPaper] {
        guard let data = defaults?.data(forKey: Keys.recentPapers) else { return [] }
        return (try? decoder.decode([WidgetPaper].self, from: data)) ?? []
    }

    /// Update the recent papers list.
    ///
    /// Call this when papers are added to the library.
    ///
    /// - Parameter papers: List of recent papers (max 10)
    public func updateRecentPapers(_ papers: [WidgetPaper]) {
        let limited = Array(papers.prefix(10))

        if let data = try? encoder.encode(limited) {
            defaults?.set(data, forKey: Keys.recentPapers)
            Logger.widgets.debug("Updated recent papers: \(limited.count) papers")
            reloadWidgetTimeline(kind: WidgetKind.recentPapers)
        }
    }

    // MARK: - Sync

    /// Last sync date for widgets.
    public var lastSyncDate: Date? {
        defaults?.object(forKey: Keys.lastSyncDate) as? Date
    }

    /// Perform a full sync of widget data.
    ///
    /// Call this on app launch to ensure widgets have up-to-date data.
    public func performFullSync(
        inboxUnread: Int,
        inboxTotal: Int,
        recentPapers: [WidgetPaper]
    ) {
        updateInboxStats(unread: inboxUnread, total: inboxTotal)
        updateRecentPapers(recentPapers)
        defaults?.set(Date(), forKey: Keys.lastSyncDate)

        // Select paper of day if not set for today
        if paperOfDay == nil, let firstPaper = recentPapers.first(where: { !$0.isRead }) {
            setPaperOfDay(firstPaper, reason: "Unread addition")
        }

        Logger.widgets.info("Performed full widget sync")
    }

    // MARK: - Widget Timeline Refresh

    /// Request widget timeline refresh.
    ///
    /// This tells WidgetKit to reload the specified widget type.
    private func reloadWidgetTimeline(kind: String) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        Logger.widgets.debug("Requested timeline reload for: \(kind)")
        #endif
    }

    /// Request refresh for all widget types.
    public func reloadAllWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        Logger.widgets.info("Requested reload for all widgets")
        #endif
    }
}

// MARK: - PublicationRowData Extension

extension PublicationRowData {
    /// Convert to a lightweight WidgetPaper for widget display.
    public func toWidgetPaper() -> WidgetPaper {
        return WidgetPaper(
            id: id,
            citeKey: citeKey,
            title: title,
            authors: authorString,
            year: year,
            isRead: isRead,
            hasPDF: hasPDFAvailable,
            dateAdded: dateAdded
        )
    }
}

// MARK: - Logger Extension

extension Logger {
    static let widgets = Logger(subsystem: "com.imbib.app", category: "widgets")
}
