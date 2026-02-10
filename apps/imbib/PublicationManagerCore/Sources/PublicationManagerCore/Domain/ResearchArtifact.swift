//
//  ResearchArtifact.swift
//  PublicationManagerCore
//
//  Domain struct for research artifacts captured from any source.
//

import Foundation
import ImbibRustCore
import ImpressFTUI

/// A research artifact — any captured item that doesn't fit the bibliography model.
public struct ResearchArtifact: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let schema: ArtifactType
    public let title: String
    public var sourceURL: String?
    public var notes: String?
    public var artifactSubtype: String?
    public var fileName: String?
    public var fileHash: String?
    public var fileSize: Int64?
    public var fileMimeType: String?
    public var captureContext: String?
    public var originalAuthor: String?
    public var eventName: String?
    public var eventDate: String?
    public var tags: [TagDisplayData]
    public var flagColor: String?
    public var isRead: Bool
    public var isStarred: Bool
    public let created: Date
    public let author: String

    public init(from row: ArtifactRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.schema = ArtifactType(rawValue: row.schema) ?? .general
        self.title = row.title
        self.sourceURL = row.sourceUrl
        self.notes = row.notes
        self.artifactSubtype = row.artifactSubtype
        self.fileName = row.fileName
        self.fileHash = row.fileHash
        self.fileSize = row.fileSize
        self.fileMimeType = row.fileMimeType
        self.captureContext = row.captureContext
        self.originalAuthor = row.originalAuthor
        self.eventName = row.eventName
        self.eventDate = row.eventDate
        self.tags = row.tags.map { tag in
            TagDisplayData(
                id: UUID(),
                path: tag.path,
                leaf: tag.leafName,
                colorLight: tag.colorLight,
                colorDark: tag.colorDark
            )
        }
        self.flagColor = row.flagColor
        self.isRead = row.isRead
        self.isStarred = row.isStarred
        self.created = Date(timeIntervalSince1970: TimeInterval(row.createdAt) / 1000.0)
        self.author = row.author
    }
}

/// The type taxonomy for research artifacts.
public enum ArtifactType: String, CaseIterable, Sendable, Hashable {
    case presentation = "impress/artifact/presentation"
    case poster = "impress/artifact/poster"
    case dataset = "impress/artifact/dataset"
    case webpage = "impress/artifact/webpage"
    case note = "impress/artifact/note"
    case media = "impress/artifact/media"
    case code = "impress/artifact/code"
    case general = "impress/artifact/general"

    public var displayName: String {
        switch self {
        case .presentation: return "Presentation"
        case .poster: return "Poster"
        case .dataset: return "Dataset"
        case .webpage: return "Web Page"
        case .note: return "Note"
        case .media: return "Media"
        case .code: return "Code"
        case .general: return "General"
        }
    }

    public var iconName: String {
        switch self {
        case .presentation: return "play.rectangle"
        case .poster: return "doc.richtext"
        case .dataset: return "tablecells"
        case .webpage: return "globe"
        case .note: return "note.text"
        case .media: return "photo"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .general: return "archivebox"
        }
    }

    public var pluralDisplayName: String {
        switch self {
        case .presentation: return "Presentations"
        case .poster: return "Posters"
        case .dataset: return "Datasets"
        case .webpage: return "Web Pages"
        case .note: return "Notes"
        case .media: return "Media"
        case .code: return "Code"
        case .general: return "General"
        }
    }
}
