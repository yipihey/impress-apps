//
//  PaperProvider.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-04.
//

import Foundation

// MARK: - Paper Provider Protocol

/// Protocol for types that provide collections of papers.
///
/// Providers abstract over different paper sources:
/// - LocalLibrary: Papers from a .bib file (persistent)
/// - SmartSearch: Papers from a saved query (cached)
/// - AdHocSearch: Papers from a one-time search (ephemeral)
public protocol PaperProvider: Sendable {
    associatedtype Paper: PaperRepresentable

    /// Unique identifier for this provider
    var id: UUID { get }

    /// Display name for this provider
    var name: String { get }

    /// Type of provider
    var providerType: PaperProviderType { get }

    /// Whether the provider is currently loading papers
    var isLoading: Bool { get async }

    /// Current papers from this provider
    var papers: [Paper] { get async }

    /// Total count of papers (may be known before loading all)
    var count: Int { get async }

    /// Refresh papers from source
    func refresh() async throws
}

// MARK: - Provider Type

/// Types of paper providers
public enum PaperProviderType: Sendable, Equatable {
    /// Local library backed by .bib file
    case library

    /// Saved smart search (stores query, fetches on demand)
    case smartSearch

    /// Ad-hoc search (session-only, not persisted)
    case adHocSearch
}

// MARK: - Provider Events

/// Events emitted by paper providers for UI updates
public enum PaperProviderEvent: Sendable {
    case willLoad
    case didLoad(count: Int)
    case didFail(Error)
    case paperAdded(id: String)
    case paperRemoved(id: String)
    case paperUpdated(id: String)
}

// MARK: - Type-Erased Provider

/// Type-erased wrapper for any PaperProvider.
/// Useful for storing heterogeneous providers in collections.
public actor AnyPaperProvider: PaperProvider {
    public typealias Paper = AnyPaper

    private let _id: UUID
    private let _name: String
    private let _providerType: PaperProviderType
    private let _isLoading: @Sendable () async -> Bool
    private let _papers: @Sendable () async -> [AnyPaper]
    private let _count: @Sendable () async -> Int
    private let _refresh: @Sendable () async throws -> Void

    public init<P: PaperProvider>(_ provider: P) {
        self._id = provider.id
        self._name = provider.name
        self._providerType = provider.providerType
        self._isLoading = { await provider.isLoading }
        self._papers = { await provider.papers.map { AnyPaper($0) } }
        self._count = { await provider.count }
        self._refresh = { try await provider.refresh() }
    }

    public nonisolated var id: UUID { _id }
    public nonisolated var name: String { _name }
    public nonisolated var providerType: PaperProviderType { _providerType }

    public var isLoading: Bool {
        get async { await _isLoading() }
    }

    public var papers: [AnyPaper] {
        get async { await _papers() }
    }

    public var count: Int {
        get async { await _count() }
    }

    public func refresh() async throws {
        try await _refresh()
    }
}

// MARK: - Provider Collection

/// A collection of paper providers, useful for the sidebar
public actor PaperProviderCollection {
    private var providers: [UUID: AnyPaperProvider] = [:]

    public init() {}

    public func add<P: PaperProvider>(_ provider: P) {
        providers[provider.id] = AnyPaperProvider(provider)
    }

    public func remove(id: UUID) {
        providers.removeValue(forKey: id)
    }

    public func get(id: UUID) -> AnyPaperProvider? {
        providers[id]
    }

    public var all: [AnyPaperProvider] {
        Array(providers.values)
    }

    public var libraries: [AnyPaperProvider] {
        providers.values.filter { $0.providerType == .library }
    }

    public var smartSearches: [AnyPaperProvider] {
        providers.values.filter { $0.providerType == .smartSearch }
    }
}
