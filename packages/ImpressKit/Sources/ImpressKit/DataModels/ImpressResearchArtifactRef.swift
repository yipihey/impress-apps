import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A lightweight cross-app research artifact reference for drag-and-drop and inter-app communication.
public struct ImpressResearchArtifactRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let schema: String
    public let title: String
    public let sourceURL: String?

    public init(id: UUID, schema: String, title: String, sourceURL: String? = nil) {
        self.id = id
        self.schema = schema
        self.title = title
        self.sourceURL = sourceURL
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ImpressResearchArtifactRef: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .impressResearchArtifactReference)
        ProxyRepresentation(exporting: \.title) // fallback: plain text title
    }
}
