import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// A lightweight cross-app figure reference for implore visualizations.
public struct ImpressFigureRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String?
    public let format: String?

    public init(id: UUID, title: String? = nil, format: String? = nil) {
        self.id = id
        self.title = title
        self.format = format
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ImpressFigureRef: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .impressFigureReference)
        ProxyRepresentation(exporting: { $0.title ?? $0.id.uuidString }) // fallback: plain text
    }
}
