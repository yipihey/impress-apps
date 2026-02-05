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
}
