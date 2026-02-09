//
//  Annotation.swift
//  PublicationManagerCore
//
//  Domain struct replacing CDAnnotation.
//

import Foundation
import ImbibRustCore

/// A PDF annotation (highlight, note, underline, etc.).
public struct AnnotationModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let annotationType: String
    public let pageNumber: Int
    public let boundsJSON: String?
    public let color: String?
    public let contents: String?
    public let selectedText: String?
    public let authorName: String?
    public let dateCreated: Date
    public let dateModified: Date
    public let linkedFileID: UUID

    public init(from row: ImbibRustCore.AnnotationRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.annotationType = row.annotationType
        self.pageNumber = Int(row.pageNumber)
        self.boundsJSON = row.boundsJson
        self.color = row.color
        self.contents = row.contents
        self.selectedText = row.selectedText
        self.authorName = row.authorName
        self.dateCreated = Date(timeIntervalSince1970: TimeInterval(row.dateCreated) / 1000.0)
        self.dateModified = Date(timeIntervalSince1970: TimeInterval(row.dateModified) / 1000.0)
        self.linkedFileID = UUID(uuidString: row.linkedFileId) ?? UUID()
    }
}
