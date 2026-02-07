import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A lightweight cross-app document reference for imprint manuscripts.
public struct ImpressDocumentRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let lastModified: Date?

    public init(id: UUID, title: String, lastModified: Date? = nil) {
        self.id = id
        self.title = title
        self.lastModified = lastModified
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ImpressDocumentRef: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .impressDocumentReference)
        ProxyRepresentation(exporting: \.title) // fallback: plain text title
    }
}
