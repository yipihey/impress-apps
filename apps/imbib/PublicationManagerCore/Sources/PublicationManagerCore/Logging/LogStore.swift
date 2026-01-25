//
//  LogStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import SwiftUI

// MARK: - Log Level

public enum LogLevel: String, CaseIterable, Sendable, Codable {
    case debug
    case info
    case warning
    case error

    public var icon: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }

    public var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Log Entry

public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - Log Store

/// Central store for capturing and displaying log entries.
/// Uses a ring buffer to limit memory usage.
@MainActor
@Observable
public final class LogStore {

    // MARK: - Singleton

    public static let shared = LogStore()

    // MARK: - Properties

    public private(set) var entries: [LogEntry] = []

    /// Maximum number of entries to keep
    public var maxEntries: Int = 1000

    /// Whether logging to the store is enabled
    public var isEnabled: Bool = true

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Add a log entry to the store
    public func add(_ entry: LogEntry) {
        guard isEnabled else { return }

        entries.append(entry)

        // Trim to max size
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Add a log entry with individual parameters
    public func log(
        level: LogLevel,
        category: String,
        message: String
    ) {
        add(LogEntry(
            level: level,
            category: category,
            message: message
        ))
    }

    /// Clear all log entries
    public func clear() {
        entries.removeAll()
    }

    /// Export all entries as a formatted string
    public func export() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        return entries.map { entry in
            let time = formatter.string(from: entry.timestamp)
            let level = entry.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            let category = entry.category.padding(toLength: 12, withPad: " ", startingAt: 0)
            return "[\(time)] [\(level)] [\(category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Export entries matching a filter
    public func export(levels: Set<LogLevel>, searchText: String) -> String {
        let filtered = filteredEntries(levels: levels, searchText: searchText)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        return filtered.map { entry in
            let time = formatter.string(from: entry.timestamp)
            let level = entry.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            let category = entry.category.padding(toLength: 12, withPad: " ", startingAt: 0)
            return "[\(time)] [\(level)] [\(category)] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Get entries filtered by level and search text
    public func filteredEntries(levels: Set<LogLevel>, searchText: String) -> [LogEntry] {
        entries.filter { entry in
            guard levels.contains(entry.level) else { return false }
            if searchText.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText) ||
                   entry.category.localizedCaseInsensitiveContains(searchText)
        }
    }
}
