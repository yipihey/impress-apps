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
    /// Pseudo smart-library — every publication that appears in at
    /// least one `citation-usage@1.0.0` record (i.e. is cited by any
    /// imprint manuscript). Resolved at query time from the
    /// `CitedInManuscriptsSnapshot` singleton.
    case citedInManuscripts

    /// Union of multiple sources — papers from all child sources, deduped
    /// by paper UUID. Used by Cmd-click multi-selection of libraries / collections.
    /// The list query, count, and viewID derive from the contained array.
    case combined([PublicationSource])

    /// Deterministic UUID for SwiftUI `.id()` — ensures view recreation on source change.
    public var viewID: UUID {
        switch self {
        case .library(let id), .smartSearch(let id), .collection(let id),
             .scixLibrary(let id), .inbox(let id):
            return id
        case .flagged(let color):
            // Use a deterministic mapping for flag colors instead of hashValue (which varies across launches)
            let colorIndex: UInt16 = {
                guard let c = color else { return 0 }
                switch c {
                case "red": return 1
                case "orange": return 2
                case "yellow": return 3
                case "green": return 4
                case "blue": return 5
                case "purple": return 6
                case "grey", "gray": return 7
                default:
                    // Deterministic fallback: sum of UTF-8 bytes mod 65535
                    return UInt16(c.utf8.reduce(0) { ($0 &+ UInt16($1)) } | 0x8000)
                }
            }()
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", colorIndex))!
        case .unread:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000001")!
        case .starred:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000002")!
        case .tag(let path):
            // Deterministic hash from tag path using FNV-1a instead of Swift's hashValue
            var hash: UInt64 = 14695981039346656037 // FNV offset basis
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211 // FNV prime
            }
            return UUID(uuidString: String(format: "00000000-0000-0000-BBBB-%012x", hash & 0xFFFF_FFFF_FFFF))!
        case .dismissed:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000003")!
        case .citedInManuscripts:
            return UUID(uuidString: "00000000-0000-0000-AAAA-000000000004")!
        case .combined(let sources):
            // Order-independent deterministic id: sort child viewIDs and
            // FNV-hash their bytes. Two `.combined` sources with the same
            // set of children produce the same viewID, regardless of order.
            let sortedIDs = sources.map { $0.viewID.uuidString }.sorted()
            var hash: UInt64 = 14695981039346656037
            for s in sortedIDs {
                for byte in s.utf8 {
                    hash ^= UInt64(byte)
                    hash &*= 1099511628211
                }
            }
            return UUID(uuidString: String(format: "00000000-0000-0000-CCCC-%012x", hash & 0xFFFF_FFFF_FFFF))!
        }
    }
}
