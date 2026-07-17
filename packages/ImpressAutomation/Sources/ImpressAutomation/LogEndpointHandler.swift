//
//  LogEndpointHandler.swift
//  ImpressAutomation
//
//  Reusable handler for GET /api/logs endpoint.
//  Any app's HTTP router can delegate to this handler.
//

import Foundation
import ImpressLogging

/// Handles GET /api/logs requests against the shared LogStore.
///
/// Query parameters:
///   - `limit` (Int, default 100): Maximum entries to return
///   - `offset` (Int, default 0): Entries to skip
///   - `level` (String, comma-separated): Filter by levels (e.g. "info,warning,error")
///   - `category` (String): Filter by category substring
///   - `search` (String): Filter by message text
///   - `after` (String, ISO8601): Only entries after this timestamp
public struct LogEndpointHandler {

    @MainActor
    public static func handle(_ request: HTTPRequest) -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 100
        let offset = request.queryParams["offset"].flatMap { Int($0) } ?? 0
        let levelFilter = request.queryParams["level"]
        let categoryFilter = request.queryParams["category"]
        let searchFilter = request.queryParams["search"]
        let afterFilter = request.queryParams["after"]

        let store = LogStore.shared
        var entries = store.entries

        // Filter by level
        if let levelParam = levelFilter, !levelParam.isEmpty {
            let allowedLevels = Set(
                levelParam
                    .components(separatedBy: ",")
                    .compactMap { LogLevel(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            )
            if !allowedLevels.isEmpty {
                entries = entries.filter { allowedLevels.contains($0.level) }
            }
        }

        // Filter by category
        if let category = categoryFilter, !category.isEmpty {
            entries = entries.filter {
                $0.category.localizedCaseInsensitiveContains(category)
            }
        }

        // Filter by search text
        if let search = searchFilter, !search.isEmpty {
            entries = entries.filter {
                $0.message.localizedCaseInsensitiveContains(search)
            }
        }

        // Filter by timestamp
        if let afterStr = afterFilter, !afterStr.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let afterDate = formatter.date(from: afterStr) {
                entries = entries.filter { $0.timestamp > afterDate }
            } else {
                // Try without fractional seconds
                let basicFormatter = ISO8601DateFormatter()
                if let afterDate = basicFormatter.date(from: afterStr) {
                    entries = entries.filter { $0.timestamp > afterDate }
                }
            }
        }

        let totalFiltered = entries.count
        let totalInStore = store.entries.count

        // Apply pagination
        let paginatedEntries = Array(entries.dropFirst(offset).prefix(limit))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let entryDicts: [[String: Any]] = paginatedEntries.map { entry in
            [
                "id": entry.id.uuidString,
                "timestamp": iso.string(from: entry.timestamp),
                "level": entry.level.rawValue,
                "category": entry.category,
                "message": entry.message
            ]
        }

        let response: [String: Any] = [
            "status": "ok",
            "data": [
                "entries": entryDicts,
                "count": totalFiltered,
                "totalInStore": totalInStore
            ] as [String: Any]
        ]

        return .json(response)
    }

    /// Handles GET /api/logs/stream — a cursor-based incremental log feed for
    /// agents watching a scenario unfold.
    ///
    /// Unlike `/api/logs` (newest-first, offset-paginated), this returns
    /// entries *after* a cursor in chronological order and hands back a
    /// `nextCursor` to poll with next. The `HTTPServer` is request/response, so
    /// this is a follow-by-repoll loop rather than a held-open socket — same
    /// ergonomics, no risk to the shared connection handling.
    ///
    /// Query parameters:
    ///   - `after` (String, ISO8601): return only entries strictly after this.
    ///     Omit on the first call to start from "now" (returns an empty batch
    ///     with a fresh cursor); pass `after=0` to backfill from the oldest.
    ///   - `limit` (Int, default 200): max entries per batch
    ///   - `level`, `category`, `search`: same filters as `/api/logs`
    @MainActor
    public static func handleStream(_ request: HTTPRequest) -> HTTPResponse {
        let limit = request.queryParams["limit"].flatMap { Int($0) } ?? 200
        let afterParam = request.queryParams["after"]

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()

        var entries = filtered(
            request,
            levelFilter: request.queryParams["level"],
            categoryFilter: request.queryParams["category"],
            searchFilter: request.queryParams["search"]
        )

        // Resolve the cursor. Missing → start from now (no backlog). "0" →
        // from the beginning. Otherwise parse the ISO8601 timestamp.
        let cursor: Date
        if let afterStr = afterParam, !afterStr.isEmpty {
            if afterStr == "0" {
                cursor = Date(timeIntervalSince1970: 0)
            } else {
                cursor = parseTimestamp(afterStr) ?? now
            }
        } else {
            cursor = now
        }

        entries = entries.filter { $0.timestamp > cursor }
        entries.sort { $0.timestamp < $1.timestamp }   // chronological
        let batch = Array(entries.prefix(limit))

        // Next cursor = last delivered entry's timestamp, else echo the input
        // cursor so the caller doesn't rewind. Start-from-now echoes `now`.
        let nextCursorDate = batch.last?.timestamp ?? cursor
        let hasMore = entries.count > batch.count

        let entryDicts: [[String: Any]] = batch.map { entry in
            [
                "id": entry.id.uuidString,
                "timestamp": iso.string(from: entry.timestamp),
                "level": entry.level.rawValue,
                "category": entry.category,
                "message": entry.message
            ]
        }

        let response: [String: Any] = [
            "status": "ok",
            "data": [
                "entries": entryDicts,
                "count": batch.count,
                "nextCursor": iso.string(from: nextCursorDate),
                "hasMore": hasMore,
                "serverTime": iso.string(from: now)
            ] as [String: Any]
        ]
        return .json(response)
    }

    // MARK: - Helpers

    /// Apply the shared level/category/search filters to the store snapshot.
    @MainActor
    private static func filtered(
        _ request: HTTPRequest,
        levelFilter: String?,
        categoryFilter: String?,
        searchFilter: String?
    ) -> [LogEntry] {
        var entries = LogStore.shared.entries
        if let levelParam = levelFilter, !levelParam.isEmpty {
            let allowed = Set(
                levelParam.components(separatedBy: ",")
                    .compactMap { LogLevel(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            )
            if !allowed.isEmpty { entries = entries.filter { allowed.contains($0.level) } }
        }
        if let category = categoryFilter, !category.isEmpty {
            entries = entries.filter { $0.category.localizedCaseInsensitiveContains(category) }
        }
        if let search = searchFilter, !search.isEmpty {
            entries = entries.filter { $0.message.localizedCaseInsensitiveContains(search) }
        }
        return entries
    }

    /// Parse an ISO8601 timestamp, tolerating presence/absence of fractional
    /// seconds.
    private static func parseTimestamp(_ str: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: str) { return d }
        return ISO8601DateFormatter().date(from: str)
    }
}
