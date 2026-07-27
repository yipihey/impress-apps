#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  RecordScopeKey.swift
//  PublicationManagerCore
//
//  Stage 1 (ADR-0021): the one thing every per-kind list scope must provide.
//  Scopes stay PARALLEL per record kind (PublicationSource is publication-
//  only by ADR-0018 invariant 3; ManuscriptListScope is manuscript-only) —
//  this protocol just standardizes the `.id()` rule: any view receiving a
//  scope inside a cached detail closure carries `.id(scope.stableViewID)`.
//

import Foundation

public protocol RecordScopeKey {
    /// Deterministic identity for SwiftUI `.id()` — must be stable across
    /// body evaluations for the same logical scope.
    var stableViewID: UUID { get }
    /// Human-readable stable key (persistence, logging).
    var scopeKey: String { get }
}

extension ManuscriptListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all: return "manuscripts-all"
        case .status(let s): return "manuscripts-status-\(s.rawValue)"
        case .folder(let id): return "manuscripts-folder-\(id.uuidString)"
        case .flagged(let color): return "manuscripts-flagged-\(color?.rawValue ?? "any")"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension FigureListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .all: return "figures-all"
        case .unfiled: return "figures-unfiled"
        case .folder(let id): return "figures-folder-\(id.uuidString)"
        case .flagged(let color): return "figures-flagged-\(color?.rawValue ?? "any")"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension MessageListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .allInboxes: return "messages-all-inboxes"
        case .account(let id): return "messages-account-\(id.uuidString)"
        case .folder(let id): return "messages-folder-\(id.uuidString)"
        case .flagged(let color): return "messages-flagged-\(color?.rawValue ?? "any")"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension AgentListScope: RecordScopeKey {
    public var scopeKey: String {
        switch self {
        case .tasks: return "agents-tasks"
        case .runs: return "agents-runs"
        case .tasksByState(let state): return "agents-tasks-state-\(state)"
        }
    }

    public var stableViewID: UUID {
        UUID.deterministic(from: scopeKey)
    }
}

extension PublicationSource: RecordScopeKey {
    public var scopeKey: String { "publications-\(viewID.uuidString)" }
    public var stableViewID: UUID { viewID }
}

extension UUID {
    /// Deterministic UUID from a string key (FNV-1a over the key, folded into
    /// the 16 bytes) — mirrors the ImbibSidebarNodeID.stable approach so
    /// scope identity survives relaunches.
    static func deterministic(from key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 0xcbf29ce484222325
        for (i, byte) in key.utf8.enumerated() {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            bytes[i % 16] ^= UInt8(truncatingIfNeeded: hash)
        }
        // RFC 4122 version/variant bits so the result is a well-formed v4-shaped UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
#endif
