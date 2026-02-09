//
//  ActivityRecord.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDActivityRecord.
//

import Foundation
import ImbibRustCore

/// A library activity log entry.
public struct ActivityRecord: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let activityType: String
    public let actorDisplayName: String?
    public let targetTitle: String?
    public let targetID: String?
    public let date: Date
    public let detail: String?
    public let libraryID: UUID

    public init(from row: ActivityRecordRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.activityType = row.activityType
        self.actorDisplayName = row.actorDisplayName
        self.targetTitle = row.targetTitle
        self.targetID = row.targetId
        self.date = Date(timeIntervalSince1970: TimeInterval(row.date) / 1000.0)
        self.detail = row.detail
        self.libraryID = UUID(uuidString: row.libraryId) ?? UUID()
    }

    // MARK: - Display Helpers

    /// Parsed activity type enum.
    public var typeEnum: ActivityType? {
        ActivityType(rawValue: activityType)
    }

    /// Human-readable description of the activity.
    public var formattedDescription: String {
        let actor = actorDisplayName ?? "Someone"
        let target = targetTitle ?? "an item"
        switch typeEnum {
        case .added: return "\(actor) added \(target)"
        case .removed: return "\(actor) removed \(target)"
        case .annotated: return "\(actor) annotated \(target)"
        case .commented: return "\(actor) commented on \(target)"
        case .organized: return "\(actor) organized \(target)"
        case .modified: return "\(actor) modified \(target)"
        case .none: return "\(actor) updated \(target)"
        }
    }
}

/// Activity type categories.
public enum ActivityType: String, Sendable {
    case added
    case removed
    case annotated
    case commented
    case organized
    case modified

    /// System icon name for this activity type.
    public var icon: String {
        switch self {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .annotated: return "highlighter"
        case .commented: return "text.bubble"
        case .organized: return "folder"
        case .modified: return "pencil.circle"
        }
    }
}
