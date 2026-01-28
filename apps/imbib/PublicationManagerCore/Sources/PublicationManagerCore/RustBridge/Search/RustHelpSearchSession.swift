//
//  RustHelpSearchSession.swift
//  PublicationManagerCore
//
//  Actor-based help documentation search backed by the Rust imbib-core library (Tantivy).
//  Provides full-text search for help documents with thread-safe access and term highlighting.
//

import Foundation
import ImbibRustCore
import OSLog

private let logger = Logger(subsystem: "com.imbib.help", category: "rust-search")

// MARK: - Platform Enum (mirrors Rust)

/// Platform for help documentation filtering
public enum RustHelpPlatform: Sendable {
    case iOS
    case macOS
    case both

    /// Convert to Rust type
    func toRust() -> ImbibRustCore.HelpPlatform {
        switch self {
        case .iOS: return .ios
        case .macOS: return .macOs
        case .both: return .both
        }
    }

    /// Convert from Rust type
    static func from(_ rust: ImbibRustCore.HelpPlatform) -> RustHelpPlatform {
        switch rust {
        case .ios: return .iOS
        case .macOs: return .macOS
        case .both: return .both
        }
    }

    /// Get current platform
    public static var current: RustHelpPlatform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #else
        return .both
        #endif
    }
}

// MARK: - Help Document Input

/// Input for indexing a help document
public struct HelpDocumentInput: Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let keywords: [String]
    public let platform: RustHelpPlatform
    public let category: String

    public init(
        id: String,
        title: String,
        body: String,
        keywords: [String] = [],
        platform: RustHelpPlatform = .both,
        category: String = ""
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.keywords = keywords
        self.platform = platform
        self.category = category
    }

    /// Convert to Rust HelpDocument type
    func toRust() -> ImbibRustCore.HelpDocument {
        ImbibRustCore.HelpDocument(
            id: id,
            title: title,
            body: body,
            keywords: keywords,
            platform: platform.toRust(),
            category: category
        )
    }
}

// MARK: - Help Search Result

/// A search result from the help index
public struct RustHelpSearchHit: Sendable, Identifiable {
    /// Document identifier
    public let id: String
    /// Document title
    public let title: String
    /// Snippet with highlighted terms (using <mark> tags)
    public let snippet: String
    /// Relevance score (0.0 to 1.0)
    public let relevanceScore: Float
    /// Target platform
    public let platform: RustHelpPlatform
    /// Category
    public let category: String

    init(from result: ImbibRustCore.HelpSearchResult) {
        self.id = result.id
        self.title = result.title
        self.snippet = result.snippet
        self.relevanceScore = result.relevanceScore
        self.platform = RustHelpPlatform.from(result.platform)
        self.category = result.category
    }

    public init(
        id: String,
        title: String,
        snippet: String,
        relevanceScore: Float,
        platform: RustHelpPlatform,
        category: String
    ) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.relevanceScore = relevanceScore
        self.platform = platform
        self.category = category
    }
}

// MARK: - Help Search Error

/// Errors that can occur when using the help search index
public enum HelpSearchIndexError: Error, LocalizedError {
    case notInitialized
    case initializationFailed(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Help search index not initialized"
        case .initializationFailed(let reason):
            return "Failed to initialize help search index: \(reason)"
        case .operationFailed(let reason):
            return "Help search operation failed: \(reason)"
        }
    }
}

// MARK: - Rust Help Search Session (Actor-based)

/// Actor-based help documentation search backed by Rust/Tantivy.
/// Provides thread-safe access to the help search index with term highlighting.
public actor RustHelpSearchSession {
    private var handleId: UInt64?

    /// Create a help search session (uninitialized)
    public init() {}

    /// Initialize with a path on disk
    /// - Parameter path: Directory path for the index
    /// - Throws: HelpSearchIndexError if creation fails
    public func initialize(path: URL) async throws {
        do {
            self.handleId = try helpIndexCreate(path: path.path)
            logger.info("Help search index initialized at \(path.path)")
        } catch {
            logger.error("Failed to initialize help search index: \(error.localizedDescription)")
            throw HelpSearchIndexError.initializationFailed("\(error)")
        }
    }

    /// Initialize with an in-memory index (for testing)
    /// - Throws: HelpSearchIndexError if creation fails
    public func initializeInMemory() async throws {
        do {
            self.handleId = try helpIndexCreateInMemory()
            logger.info("Help search index initialized in memory")
        } catch {
            logger.error("Failed to initialize in-memory help search index: \(error.localizedDescription)")
            throw HelpSearchIndexError.initializationFailed("\(error)")
        }
    }

    /// Add a help document to the index
    /// - Parameter document: The document to index
    /// - Throws: HelpSearchIndexError if indexing fails
    public func add(_ document: HelpDocumentInput) async throws {
        guard let id = handleId else {
            throw HelpSearchIndexError.notInitialized
        }
        do {
            try helpIndexAddDocument(handleId: id, document: document.toRust())
        } catch {
            throw HelpSearchIndexError.operationFailed("\(error)")
        }
    }

    /// Index multiple documents
    /// - Parameter documents: The documents to index
    /// - Throws: HelpSearchIndexError if indexing fails
    public func addAll(_ documents: [HelpDocumentInput]) async throws {
        for document in documents {
            try await add(document)
        }
    }

    /// Commit pending changes to the index
    /// - Throws: HelpSearchIndexError if commit fails
    public func commit() async throws {
        guard let id = handleId else {
            throw HelpSearchIndexError.notInitialized
        }
        do {
            try helpIndexCommit(handleId: id)
            logger.info("Help search index committed")
        } catch {
            throw HelpSearchIndexError.operationFailed("\(error)")
        }
    }

    /// Search the help index
    /// - Parameters:
    ///   - query: The search query
    ///   - limit: Maximum number of results
    ///   - platformFilter: Optional platform to filter results
    /// - Returns: Array of search results with highlighted snippets
    /// - Throws: HelpSearchIndexError if search fails
    public func search(
        query: String,
        limit: Int = 20,
        platformFilter: RustHelpPlatform? = nil
    ) async throws -> [RustHelpSearchHit] {
        guard let id = handleId else {
            throw HelpSearchIndexError.notInitialized
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        do {
            let results = try helpIndexSearch(
                handleId: id,
                query: trimmedQuery,
                limit: UInt32(limit),
                platform: platformFilter?.toRust()
            )
            return results.map { RustHelpSearchHit(from: $0) }
        } catch {
            throw HelpSearchIndexError.operationFailed("\(error)")
        }
    }

    /// Search with automatic platform filtering for current platform
    /// - Parameters:
    ///   - query: The search query
    ///   - limit: Maximum number of results
    /// - Returns: Array of search results relevant to current platform
    /// - Throws: HelpSearchIndexError if search fails
    public func searchForCurrentPlatform(
        query: String,
        limit: Int = 20
    ) async throws -> [RustHelpSearchHit] {
        try await search(query: query, limit: limit, platformFilter: .current)
    }

    /// Close the index and release resources
    public func close() async {
        guard let id = handleId else { return }
        do {
            try helpIndexClose(handleId: id)
            logger.info("Help search index closed")
        } catch {
            logger.warning("Failed to close help search index: \(error.localizedDescription)")
        }
        handleId = nil
    }

    /// Check if the index is initialized (async - actor-isolated)
    public func checkInitialized() async -> Bool {
        handleId != nil
    }

    deinit {
        if let id = handleId {
            do {
                try helpIndexClose(handleId: id)
            } catch {
                print("Warning: Failed to close help search index in deinit: \(error)")
            }
        }
    }

    /// Get the number of active help index handles (for debugging)
    public static var activeHandleCount: Int {
        Int(helpIndexHandleCount())
    }
}

// MARK: - RustHelpSearchService

/// Service for searching help documentation using Rust-powered full-text search.
///
/// This service manages the help search index lifecycle and provides
/// high-level search functionality with platform-aware filtering.
public actor RustHelpSearchService {

    // MARK: - Singleton

    public static let shared = RustHelpSearchService()

    // MARK: - State

    private var session: RustHelpSearchSession?
    private var isIndexBuilt = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Index Management

    /// Initialize the help search index
    /// - Parameter indexPath: Optional path for persistent index. Uses in-memory if nil.
    public func initializeIndex(at indexPath: URL? = nil) async throws {
        let session = RustHelpSearchSession()

        if let path = indexPath {
            try await session.initialize(path: path)
        } else {
            try await session.initializeInMemory()
        }

        self.session = session
        logger.info("RustHelpSearchService initialized")
    }

    /// Index help documents from markdown content
    /// - Parameter documents: Array of (id, title, content, keywords, platform, category) tuples
    public func indexDocuments(_ documents: [HelpDocumentInput]) async throws {
        guard let session = session else {
            throw HelpSearchIndexError.notInitialized
        }

        try await session.addAll(documents)
        try await session.commit()
        isIndexBuilt = true

        logger.info("Indexed \(documents.count) help documents")
    }

    /// Search help documents
    /// - Parameters:
    ///   - query: Search query
    ///   - limit: Maximum results
    ///   - filterPlatform: Whether to filter by current platform
    /// - Returns: Search results with highlighted snippets
    public func search(
        query: String,
        limit: Int = 20,
        filterPlatform: Bool = true
    ) async throws -> [RustHelpSearchHit] {
        guard let session = session else {
            throw HelpSearchIndexError.notInitialized
        }

        if filterPlatform {
            return try await session.searchForCurrentPlatform(query: query, limit: limit)
        } else {
            return try await session.search(query: query, limit: limit)
        }
    }

    /// Check if the service is ready for searching
    public func isReady() async -> Bool {
        guard let session = session else { return false }
        return await session.checkInitialized() && isIndexBuilt
    }

    /// Close the search service and release resources
    public func close() async {
        await session?.close()
        session = nil
        isIndexBuilt = false
    }
}

// MARK: - Rust Help Search Info

/// Information about Rust help search availability
public enum RustHelpSearchInfo {
    public static var isAvailable: Bool { true }
}
