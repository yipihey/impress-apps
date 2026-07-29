#if os(macOS)
// Chassis file — macOS-only: these four list scopes are declared inside the
// macOS-gated list wrappers (ManuscriptListWrapper, FigureListWrapper,
// MessageListWrapper, AgentRecordListWrapper), so their `RecordScopeKey`
// conformances cannot exist on iOS.
//
//  RecordScopeKey+MacScopes.swift
//  PublicationManagerCore
//
//  Split out of RecordScopeKey.swift in the iOS foundation pass. Verbatim —
//  no behaviour change; only the file the code sits in moved.
//

import Foundation

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
#endif
