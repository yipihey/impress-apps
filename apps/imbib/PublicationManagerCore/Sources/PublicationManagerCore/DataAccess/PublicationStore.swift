//
//  PublicationStore.swift
//  PublicationManagerCore
//
//  Protocol for publication storage, enabling different backends.
//

import Foundation
import ImbibRustCore

/// Protocol for publication storage, enabling different backends
public protocol PublicationStore: Sendable, Actor {
    func fetchAll(in library: String?) async throws -> [Publication]
    func fetch(id: String) async throws -> Publication?
    func fetch(byCiteKey: String, in library: String?) async throws -> Publication?
    func search(query: String) async throws -> [Publication]
    func save(_ publication: Publication) async throws
    func delete(id: String) async throws
    func batchImport(_ publications: [Publication]) async throws

    /// Stream of changes for reactive updates
    nonisolated func changes() -> AsyncStream<StoreChange>
}

public enum StoreChange: Sendable {
    case inserted([String])
    case updated([String])
    case deleted([String])
    case reloaded
}
