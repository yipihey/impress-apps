#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  AgentRowData.swift
//  PublicationManagerCore
//
//  MailStyleItem row models for `task@1.0.0` and `agent-run@1.0.0` items
//  (Stage 2-C, ADR-0021) — same value-type mirror shape as
//  MessageRowData/FigureRowData.
//

import Foundation
import ImpressFTUI
import ImpressMailStyle
import ImpressRustCore

// MARK: - TaskRowData

/// A display-ready snapshot of a `task@1.0.0` item for the chassis list.
public struct TaskRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    /// Kernel lifecycle state (queued | running | waiting_review |
    /// completed | failed | cancelled) — KERNEL-owned; the chassis never
    /// mutates it.
    public let state: String
    public let taskDescription: String
    public let assignedTo: String?
    public let isReadState: Bool
    public let isStarredState: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]
    public let tagPaths: [String]
    public let dateCreated: Date
    public let dateModified: Date

    public init?(from row: SharedItemRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        let payload = AgentStoreReader.taskPayload(from: row)
        let title = payload?.title ?? ""
        self.title = title.isEmpty ? "Untitled task" : title
        self.state = payload?.state ?? "queued"
        self.taskDescription = payload?.description ?? ""
        self.assignedTo = payload?.assignedTo
        self.isReadState = row.isRead
        self.isStarredState = row.isStarred

        if let colorName = row.flagColor, let flagColor = FlagColor(rawValue: colorName) {
            // SharedItemRow carries only the color — default solid/full chrome.
            self.flag = PublicationFlag(color: flagColor)
        } else {
            self.flag = nil
        }

        self.tagPaths = row.tags
        self.tagDisplays = row.tags.map { path in
            TagDisplayData(
                id: UUID(),
                path: path,
                leaf: path.components(separatedBy: "/").last ?? path
            )
        }
        self.dateCreated = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.modifiedMs) / 1000.0)
    }
}

extension TaskRowData: MailStyleItem {
    /// Top-left header = the lifecycle state ("Waiting Review"), the
    /// task-list analogue of a sender line.
    public var headerText: String {
        AgentStoreReader.stateDisplayName(state)
    }
    public var titleText: String { title }
    /// Last state movement — the kernel bumps `modified` per transition.
    public var date: Date { dateModified }
    /// Keep the ENVELOPE read flag (not state==running): impel-taskd marks
    /// rows read/unread through the store like every other kind.
    public var isRead: Bool { isReadState }
    public var isStarred: Bool { isStarredState }

    public var previewText: String? {
        taskDescription.isEmpty ? nil : String(taskDescription.prefix(200))
    }

    public var subtitleText: String? { state }

    /// Trailing badge = the claiming agent, when assigned.
    public var trailingBadgeText: String? { assignedTo }

    public var hasAttachment: Bool { false }
    public var hasSecondaryAttachment: Bool { false }
    public var yearText: String? { nil }
}

// MARK: - AgentRunRowData

/// A display-ready snapshot of an `agent-run@1.0.0` item (immutable
/// provenance record) for the chassis list.
public struct AgentRunRowData: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let agentID: String
    public let model: String
    public let promptHash: String?
    public let resultSummary: String?
    public let tokenCount: Int64?
    public let durationMs: Int64?
    public let isReadState: Bool
    public let isStarredState: Bool
    public let flag: PublicationFlag?
    public let tagDisplays: [TagDisplayData]
    public let tagPaths: [String]
    public let dateCreated: Date
    public let dateModified: Date

    public init?(from row: SharedItemRow) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.id = id
        let payload = AgentStoreReader.runPayload(from: row)
        self.agentID = payload?.agentID ?? ""
        self.model = payload?.model ?? ""
        self.promptHash = payload?.promptHash
        self.resultSummary = payload?.resultSummary
        self.tokenCount = payload?.tokenCount
        self.durationMs = payload?.durationMs
        self.isReadState = row.isRead
        self.isStarredState = row.isStarred

        if let colorName = row.flagColor, let flagColor = FlagColor(rawValue: colorName) {
            self.flag = PublicationFlag(color: flagColor)
        } else {
            self.flag = nil
        }

        self.tagPaths = row.tags
        self.tagDisplays = row.tags.map { path in
            TagDisplayData(
                id: UUID(),
                path: path,
                leaf: path.components(separatedBy: "/").last ?? path
            )
        }
        self.dateCreated = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.modifiedMs) / 1000.0)
    }

    /// "1.2k tok · 3.4s" metadata line for rows and the Info tab.
    public var metricsText: String? {
        var parts: [String] = []
        if let tokenCount { parts.append("\(tokenCount) tok") }
        if let durationMs {
            parts.append(String(format: "%.1fs", Double(durationMs) / 1000.0))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension AgentRunRowData: MailStyleItem {
    /// Top-left header = the invoking agent (the run's "sender").
    public var headerText: String {
        agentID.isEmpty ? "Unknown Agent" : agentID
    }
    /// Title = the result summary when recorded, else the model id.
    public var titleText: String {
        if let resultSummary, !resultSummary.isEmpty {
            // First line only — summaries are Markdown documents.
            return String(resultSummary.split(separator: "\n").first ?? "(run)")
        }
        return model.isEmpty ? "(run)" : model
    }
    /// Runs are append-only — dates come from `createdMs`.
    public var date: Date { dateCreated }
    public var isRead: Bool { isReadState }
    public var isStarred: Bool { isStarredState }

    public var previewText: String? {
        guard let resultSummary, !resultSummary.isEmpty else { return nil }
        let collapsed = resultSummary
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(200))
    }

    public var subtitleText: String? {
        model.isEmpty ? nil : model
    }

    /// Trailing badge = token/duration metrics, when recorded.
    public var trailingBadgeText: String? { metricsText }

    public var hasAttachment: Bool { false }
    public var hasSecondaryAttachment: Bool { false }
    public var yearText: String? { nil }
}
#endif
