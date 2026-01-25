//
//  ReadingPositionStore.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation
import OSLog

// MARK: - Reading Position

/// Stores the reading position for a PDF (page number and zoom level)
public struct ReadingPosition: Codable, Equatable, Sendable {
    /// The current page number (1-indexed)
    public var pageNumber: Int

    /// The zoom level (0.25 to 4.0, where 1.0 is 100%)
    public var zoomLevel: CGFloat

    /// When the position was last updated
    public var lastReadDate: Date

    public init(
        pageNumber: Int = 1,
        zoomLevel: CGFloat = 1.0,
        lastReadDate: Date = Date()
    ) {
        self.pageNumber = pageNumber
        self.zoomLevel = zoomLevel
        self.lastReadDate = lastReadDate
    }
}

// MARK: - Reading Position Store

/// Actor-based store for persisting reading positions per publication.
///
/// Follows the same pattern as PDFSettingsStore - uses UserDefaults with
/// in-memory caching for performance.
public actor ReadingPositionStore {

    // MARK: - Singleton

    public static let shared = ReadingPositionStore(userDefaults: .forCurrentEnvironment)

    // MARK: - Properties

    private let userDefaults: UserDefaults
    private var cache: [UUID: ReadingPosition] = [:]
    private let keyPrefix = "reading_position_"
    private let globalZoomKey = "global_pdf_zoom_level"
    private let defaultZoomLevel: CGFloat = 1.0

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .forCurrentEnvironment) {
        self.userDefaults = userDefaults
    }

    // MARK: - Global Zoom

    /// Get or set the global zoom level (shared across all PDFs)
    public var globalZoomLevel: CGFloat {
        get {
            let value = userDefaults.double(forKey: globalZoomKey)
            return value > 0 ? CGFloat(value) : defaultZoomLevel
        }
        set {
            let clamped = max(0.25, min(4.0, newValue))
            userDefaults.set(Double(clamped), forKey: globalZoomKey)
        }
    }

    /// Set the global zoom level
    public func setGlobalZoom(_ zoomLevel: CGFloat) {
        globalZoomLevel = zoomLevel
        Logger.files.debugCapture("Global zoom set to \(Int(zoomLevel * 100))%", category: "reading")
    }

    // MARK: - Public Interface

    /// Get the saved reading position for a publication
    public func get(for publicationID: UUID) -> ReadingPosition? {
        // Check cache first
        if let cached = cache[publicationID] {
            return cached
        }

        // Load from UserDefaults
        let key = keyPrefix + publicationID.uuidString
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }

        do {
            let position = try JSONDecoder().decode(ReadingPosition.self, from: data)
            cache[publicationID] = position
            return position
        } catch {
            Logger.files.warningCapture("Failed to decode reading position: \(error.localizedDescription)", category: "reading")
            return nil
        }
    }

    /// Save a reading position for a publication
    public func save(_ position: ReadingPosition, for publicationID: UUID) {
        // Update cache
        cache[publicationID] = position

        // Persist to UserDefaults
        let key = keyPrefix + publicationID.uuidString
        do {
            let data = try JSONEncoder().encode(position)
            userDefaults.set(data, forKey: key)
            Logger.files.debugCapture("Saved reading position for \(publicationID): page \(position.pageNumber), zoom \(position.zoomLevel)", category: "reading")
        } catch {
            Logger.files.warningCapture("Failed to encode reading position: \(error.localizedDescription)", category: "reading")
        }
    }

    /// Update just the page number (convenience method)
    public func updatePage(_ pageNumber: Int, for publicationID: UUID) {
        var position = get(for: publicationID) ?? ReadingPosition()
        position.pageNumber = pageNumber
        position.lastReadDate = Date()
        save(position, for: publicationID)
    }

    /// Update just the zoom level (convenience method)
    public func updateZoom(_ zoomLevel: CGFloat, for publicationID: UUID) {
        var position = get(for: publicationID) ?? ReadingPosition()
        position.zoomLevel = zoomLevel
        position.lastReadDate = Date()
        save(position, for: publicationID)
    }

    /// Clear the reading position for a publication
    public func clear(for publicationID: UUID) {
        cache.removeValue(forKey: publicationID)
        let key = keyPrefix + publicationID.uuidString
        userDefaults.removeObject(forKey: key)
        Logger.files.debugCapture("Cleared reading position for \(publicationID)", category: "reading")
    }

    /// Clear all reading positions (for testing)
    public func clearAll() {
        cache.removeAll()

        // Remove all reading position keys from UserDefaults
        let allKeys = userDefaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(keyPrefix) {
            userDefaults.removeObject(forKey: key)
        }
        Logger.files.infoCapture("Cleared all reading positions", category: "reading")
    }

    // MARK: - Recently Read

    /// Get publications sorted by last read date (most recent first)
    public func recentlyRead(limit: Int = 10) -> [(UUID, ReadingPosition)] {
        // Load all positions from UserDefaults
        let allKeys = userDefaults.dictionaryRepresentation().keys
        var positions: [(UUID, ReadingPosition)] = []

        for key in allKeys where key.hasPrefix(keyPrefix) {
            let uuidString = String(key.dropFirst(keyPrefix.count))
            guard let uuid = UUID(uuidString: uuidString),
                  let data = userDefaults.data(forKey: key),
                  let position = try? JSONDecoder().decode(ReadingPosition.self, from: data) else {
                continue
            }
            positions.append((uuid, position))
        }

        // Sort by last read date (most recent first) and limit
        return positions
            .sorted { $0.1.lastReadDate > $1.1.lastReadDate }
            .prefix(limit)
            .map { $0 }
    }
}
