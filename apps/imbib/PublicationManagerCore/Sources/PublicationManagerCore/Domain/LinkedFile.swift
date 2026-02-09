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

    public init(from row: LinkedFileRow) {
        self.id = UUID(uuidString: row.id) ?? UUID()
        self.filename = row.filename
        self.relativePath = row.relativePath
        self.fileSize = row.fileSize
        self.isPDF = row.isPdf
        self.isLocallyMaterialized = row.isLocallyMaterialized
        self.pdfCloudAvailable = row.pdfCloudAvailable
        self.dateAdded = Date(timeIntervalSince1970: TimeInterval(row.dateAdded) / 1000.0)
    }
}
