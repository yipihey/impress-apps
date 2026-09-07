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

    // MARK: Provenance (ADR-025: annotations a device sync imported)

    /// `nil` for annotations made in imbib; `eink` for ones imported from a tablet.
    public let source: String?
    public let sourceDeviceId: String?
    public let sourceRemoteId: String?
    public let sourcePageId: String?
    public let sourceItemId: String?
    /// Absolute path of the rendered ink strokes (PNG), for ink annotations.
    public let imagePath: String?
    /// The tablet's pen tool for ink annotations (`ballpoint`, `highlighter`, …).
    public let pen: String?
    /// Hash of the strokes; OCR text survives re-imports whose strokes did not change.
    public let strokesHash: String?
    /// Confidence of the OCR text in `contents`, 0…1, for ink annotations that were read.
    public let ocrConfidence: Double?
    public let importedAt: Date?

    public var isFromEInkDevice: Bool { source == "eink" }
    public var isInk: Bool { imagePath != nil }

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
        self.source = row.source
        self.sourceDeviceId = row.sourceDeviceId
        self.sourceRemoteId = row.sourceRemoteId
        self.sourcePageId = row.sourcePageId
        self.sourceItemId = row.sourceItemId
        self.imagePath = row.imagePath
        self.pen = row.pen
        self.strokesHash = row.strokesHash
        self.ocrConfidence = row.ocrConfidence
        self.importedAt = row.importedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
    }
}
