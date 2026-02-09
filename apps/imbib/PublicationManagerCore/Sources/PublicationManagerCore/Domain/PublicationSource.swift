//
//  PublicationSource.swift
//  PublicationManagerCore
//
//  Defines what set of publications to display — replaces Core Data object references.
//

import Foundation

/// Describes the source of publications for a list view.
/// Uses only value types (UUIDs, strings) — no Core Data objects.
public enum PublicationSource: Hashable, Sendable {
    case library(UUID)
    case smartSearch(UUID)
    case collection(UUID)
    case flagged(String?)
    case scixLibrary(UUID)
    case unread
    case starred
    case tag(String)
    case inbox(UUID)
    case dismissed

    /// Deterministic UUID for SwiftUI `.id()` — ensures view recreation on source change.
    public var viewID: UUID {
        switch self {
        case .library(let id), .smartSearch(let id), .collection(let id),
             .scixLibrary(let id), .inbox(let id):
            return id
        case .flagged(let color):
            return UUID(uuidString: "00000000-0000-0000-0000-\(color?.hashValue ?? 0)") ?? UUID()
        case .unread:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000001")!
        case .starred:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000002")!
        case .tag(let path):
            return UUID(uuidString: "00000000-0000-0000-BBBB-\(abs(path.hashValue) % 999999999999)") ?? UUID()
        case .dismissed:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000003")!
        }
    }
}
