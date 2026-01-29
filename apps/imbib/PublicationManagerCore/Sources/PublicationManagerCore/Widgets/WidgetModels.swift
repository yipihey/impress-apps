//
//  WidgetModels.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import Foundation

// MARK: - Widget Data Models

/// Data for a paper displayed in widgets.
///
/// This is a lightweight, Codable struct that can be stored in UserDefaults
/// and read by widget extensions via App Groups.
public struct WidgetPaper: Codable, Identifiable, Sendable {
    public let id: UUID
    public let citeKey: String
    public let title: String
    public let authors: String
    public let year: Int?
    public let isRead: Bool
    public let hasPDF: Bool
    public let dateAdded: Date

    public init(
        id: UUID,
        citeKey: String,
        title: String,
        authors: String,
        year: Int?,
        isRead: Bool,
        hasPDF: Bool,
        dateAdded: Date
    ) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.authors = authors
        self.year = year
        self.isRead = isRead
        self.hasPDF = hasPDF
        self.dateAdded = dateAdded
    }

    /// Short author display (first author + et al.)
    public var shortAuthors: String {
        let parts = authors.components(separatedBy: " and ")
        if parts.count > 1 {
            return "\(parts[0]) et al."
        }
        return authors
    }

    /// Deep link URL to open this paper in the app
    public var deepLinkURL: URL {
        URL(string: "imbib://paper/\(id.uuidString)")!
    }
}

/// Data for the current reading session.
///
/// Used by the Reading Progress widget to show what the user is currently reading.
public struct WidgetReadingSession: Codable, Sendable {
    public let paper: WidgetPaper
    public let currentPage: Int
    public let totalPages: Int
    public let lastReadDate: Date

    public init(
        paper: WidgetPaper,
        currentPage: Int,
        totalPages: Int,
        lastReadDate: Date
    ) {
        self.paper = paper
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.lastReadDate = lastReadDate
    }

    /// Reading progress as a percentage (0.0 to 1.0)
    public var progress: Double {
        guard totalPages > 0 else { return 0 }
        return Double(currentPage) / Double(totalPages)
    }

    /// Progress formatted as percentage string
    public var progressPercentage: String {
        "\(Int(progress * 100))%"
    }
}

/// Inbox statistics for the Inbox Count widget.
public struct WidgetInboxStats: Codable, Sendable {
    public let unreadCount: Int
    public let totalCount: Int
    public let lastUpdateDate: Date

    public init(
        unreadCount: Int,
        totalCount: Int,
        lastUpdateDate: Date = Date()
    ) {
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.lastUpdateDate = lastUpdateDate
    }
}

/// Data for the Paper of the Day widget.
public struct WidgetPaperOfDay: Codable, Sendable {
    public let paper: WidgetPaper
    public let reason: String  // Why this paper was selected
    public let date: Date

    public init(
        paper: WidgetPaper,
        reason: String,
        date: Date = Date()
    ) {
        self.paper = paper
        self.reason = reason
        self.date = date
    }

    /// Check if this paper is still valid for today
    public var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - Widget Kind Identifiers

/// Identifiers for different widget types.
///
/// These must match the `kind` parameter in widget configurations.
public enum WidgetKind {
    public static let inboxCount = "InboxCountWidget"
    public static let paperOfDay = "PaperOfDayWidget"
    public static let readingProgress = "ReadingProgressWidget"
    public static let recentPapers = "RecentPapersWidget"
}
