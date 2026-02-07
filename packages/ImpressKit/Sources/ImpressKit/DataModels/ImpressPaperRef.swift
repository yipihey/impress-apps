import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A lightweight cross-app paper reference for drag-and-drop and inter-app communication.
public struct ImpressPaperRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let citeKey: String
    public let title: String?
    public let doi: String?

    public init(id: UUID, citeKey: String, title: String? = nil, doi: String? = nil) {
        self.id = id
        self.citeKey = citeKey
        self.title = title
        self.doi = doi
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ImpressPaperRef: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .impressPaperReference)
        ProxyRepresentation(exporting: \.citeKey) // fallback: plain text cite key
    }
}
