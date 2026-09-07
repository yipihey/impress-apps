//
//  LinkedFile.swift
//  PublicationManagerCore
//
//  Domain struct for linked files (PDFs, supplementary data, etc.).
//

import Foundation
import ImbibRustCore

/// A file attached to a publication (PDF, supplementary data, etc.).
public struct LinkedFileModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let relativePath: String?
    public let fileSize: Int64
    public let isPDF: Bool
    public let isLocallyMaterialized: Bool
    public let pdfCloudAvailable: Bool
    public let dateAdded: Date

    // MARK: Provenance (ADR-025: files a device sync wrote)

    /// Lower-cased extension (`pdf`, `epub`, `rmdoc`, …) when the store knows it.
    public let fileType: String?
    public let sha256: String?
    /// A user-facing name distinct from the on-disk filename (e.g. "reMarkable — annotated").
    public let displayName: String?
    public let mimeType: String?
    /// `nil`/`primary` for the source file; `eink-annotated` for the tablet's
    /// rendition with handwriting drawn in; `eink-rmdoc` for the raw archive.
    public let role: String?
    /// The e-ink device that produced this file, if a sync imported it.
    public let sourceDeviceId: String?
    public let sourceRemoteId: String?
    public let sourceRemoteModified: Date?

    public var isPrimary: Bool { role == nil || role == "primary" }
    public var isEInkAnnotated: Bool { role == "eink-annotated" }
    public var isEInkArchive: Bool { role == "eink-rmdoc" }

    public init(from row: LinkedFileRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.filename = row.filename
        self.relativePath = row.relativePath
        self.fileSize = row.fileSize
        self.isPDF = row.isPdf
        self.isLocallyMaterialized = row.isLocallyMaterialized
        self.pdfCloudAvailable = row.pdfCloudAvailable
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
        self.fileType = row.fileType
        self.sha256 = row.sha256
        self.displayName = row.displayName
        self.mimeType = row.mimeType
        self.role = row.role
        self.sourceDeviceId = row.sourceDeviceId
        self.sourceRemoteId = row.sourceRemoteId
        self.sourceRemoteModified = row.sourceRemoteModifiedMs.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
        }
    }
}
