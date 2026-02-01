//
//  DirectoryArtifact.swift
//  MessageManagerCore
//
//  Represents an external directory referenced by a conversation.
//  Uses security-scoped bookmarks for sandbox access.
//

import Foundation
import OSLog

// MARK: - Directory Artifact

/// An external directory artifact referenced by a conversation.
/// Uses security-scoped bookmarks to maintain access across app launches.
public struct DirectoryArtifact: Identifiable, Codable, Sendable {
    /// Unique identifier
    public let id: UUID

    /// Display name for the directory
    public let name: String

    /// Security-scoped bookmark data
    public let bookmarkData: Data

    /// When the artifact was created
    public let createdAt: Date

    /// Last time the directory was accessed
    public var lastAccessedAt: Date

    /// The resolved URL (only valid while access is started).
    /// Returns nil if bookmark is stale or cannot be resolved.
    public var resolvedURL: URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url
    }

    /// Whether the bookmark is stale and needs to be recreated.
    public var isStale: Bool {
        var isStale = false
        _ = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return isStale
    }

    /// Initialize from a URL, creating a security-scoped bookmark.
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID)
    ///   - name: Display name (defaults to directory name)
    ///   - url: The directory URL to bookmark
    /// - Throws: If bookmark creation fails
    public init(id: UUID = UUID(), name: String? = nil, url: URL) throws {
        self.id = id
        self.name = name ?? url.lastPathComponent
        self.createdAt = Date()
        self.lastAccessedAt = Date()

        // Create security-scoped bookmark
        self.bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )
    }

    /// Initialize from existing bookmark data.
    public init(
        id: UUID,
        name: String,
        bookmarkData: Data,
        createdAt: Date,
        lastAccessedAt: Date
    ) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }

    /// Start accessing the security-scoped resource.
    /// - Returns: The URL if access was granted, nil otherwise
    public func startAccessing() -> URL? {
        guard let url = resolvedURL else {
            Logger.research.error("Failed to resolve bookmark for directory: \(self.name)")
            return nil
        }

        guard url.startAccessingSecurityScopedResource() else {
            Logger.research.error("Failed to start accessing security-scoped resource: \(self.name)")
            return nil
        }

        return url
    }

    /// Stop accessing the security-scoped resource.
    public func stopAccessing() {
        resolvedURL?.stopAccessingSecurityScopedResource()
    }

    /// Create a new bookmark for the same directory (refreshes stale bookmarks).
    /// - Parameter url: The current URL (must have access)
    /// - Returns: New DirectoryArtifact with fresh bookmark
    public func refreshed(from url: URL) throws -> DirectoryArtifact {
        try DirectoryArtifact(id: id, name: name, url: url)
    }
}

// MARK: - Directory Artifact Manager

/// Manages directory artifacts and their access state.
/// Use this actor to coordinate access to security-scoped directories.
public actor DirectoryArtifactManager {

    /// Shared instance
    public static let shared = DirectoryArtifactManager()

    /// Currently active access sessions (artifact ID -> URL)
    private var activeAccess: [UUID: URL] = [:]

    private init() {}

    // MARK: - Registration

    /// Register a directory for a conversation.
    /// - Parameters:
    ///   - url: The directory URL
    ///   - name: Optional display name
    /// - Returns: The created DirectoryArtifact
    public func registerDirectory(url: URL, name: String? = nil) throws -> DirectoryArtifact {
        let artifactName = name ?? url.lastPathComponent
        return try DirectoryArtifact(name: artifactName, url: url)
    }

    // MARK: - Access Management

    /// Start accessing a directory artifact.
    /// - Parameter artifact: The artifact to access
    /// - Returns: The URL if access was granted, nil otherwise
    public func startAccessing(_ artifact: DirectoryArtifact) -> URL? {
        // Return existing access if already active
        if let existing = activeAccess[artifact.id] {
            return existing
        }

        // Start new access
        guard let url = artifact.startAccessing() else {
            return nil
        }

        activeAccess[artifact.id] = url
        Logger.research.debug("Started accessing directory: \(artifact.name)")
        return url
    }

    /// Stop accessing a directory artifact.
    /// - Parameter artifact: The artifact to stop accessing
    public func stopAccessing(_ artifact: DirectoryArtifact) {
        guard activeAccess.removeValue(forKey: artifact.id) != nil else {
            return
        }
        artifact.stopAccessing()
        Logger.research.debug("Stopped accessing directory: \(artifact.name)")
    }

    /// Stop accessing by artifact ID.
    /// - Parameter id: The artifact ID
    public func stopAccessing(id: UUID) {
        guard let url = activeAccess.removeValue(forKey: id) else {
            return
        }
        url.stopAccessingSecurityScopedResource()
        Logger.research.debug("Stopped accessing directory by ID: \(id)")
    }

    /// Check if an artifact is currently being accessed.
    /// - Parameter artifact: The artifact to check
    /// - Returns: True if access is active
    public func isAccessing(_ artifact: DirectoryArtifact) -> Bool {
        activeAccess[artifact.id] != nil
    }

    /// Get the active URL for an artifact if available.
    /// - Parameter artifact: The artifact
    /// - Returns: The URL if access is active
    public func activeURL(for artifact: DirectoryArtifact) -> URL? {
        activeAccess[artifact.id]
    }

    /// Stop all active access sessions.
    public func stopAllAccess() {
        for (id, url) in activeAccess {
            url.stopAccessingSecurityScopedResource()
            Logger.research.debug("Stopped accessing directory: \(id)")
        }
        activeAccess.removeAll()
    }

    /// Number of currently active access sessions.
    public var activeCount: Int {
        activeAccess.count
    }
}

// MARK: - Directory Artifact Error

/// Errors related to directory artifact operations.
public enum DirectoryArtifactError: LocalizedError {
    case bookmarkCreationFailed(URL)
    case bookmarkResolutionFailed(String)
    case accessDenied(String)
    case staleBookmark(String)

    public var errorDescription: String? {
        switch self {
        case .bookmarkCreationFailed(let url):
            return "Failed to create security-scoped bookmark for: \(url.path)"
        case .bookmarkResolutionFailed(let name):
            return "Failed to resolve bookmark for directory: \(name)"
        case .accessDenied(let name):
            return "Access denied to directory: \(name)"
        case .staleBookmark(let name):
            return "Bookmark is stale for directory: \(name). Please re-select the directory."
        }
    }
}
