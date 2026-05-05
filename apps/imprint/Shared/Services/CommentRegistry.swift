//
//  CommentRegistry.swift
//  imprint
//
//  Singleton that maps document UUID → CommentService so the HTTP router
//  can reach a document's comment service from its actor context.
//
//  Each open document's SwiftUI view registers its `CommentService` on
//  appear and unregisters on disappear. Agents hitting the HTTP API can
//  create/list/resolve/accept/reject comments for any open document.
//

import Foundation

/// Registry of CommentService instances, keyed by document UUID.
///
/// Reads and writes are serialized by an internal lock; the registry is
/// safe to call from any thread. Registered services are stored as weak
/// references because they're owned by the SwiftUI view.
@MainActor
public final class CommentRegistry {

    public static let shared = CommentRegistry()

    private var services: [UUID: CommentService] = [:]

    private init() {}

    /// Register a document's comment service.
    public func register(_ service: CommentService, for documentID: UUID) {
        services[documentID] = service
    }

    /// Unregister a document's comment service (call when the document closes).
    public func unregister(documentID: UUID) {
        services.removeValue(forKey: documentID)
    }

    /// Look up the comment service for a document, if any.
    public func service(for documentID: UUID) -> CommentService? {
        services[documentID]
    }

    /// The document UUID that owns the given comment id, if any open
    /// document has it. O(number of open documents).
    public func documentID(forComment commentID: UUID) -> UUID? {
        for (docID, service) in services {
            if service.comments.contains(where: { $0.id == commentID }) {
                return docID
            }
        }
        return nil
    }

    /// All currently-registered document IDs.
    public var allDocumentIDs: [UUID] { Array(services.keys) }
}
