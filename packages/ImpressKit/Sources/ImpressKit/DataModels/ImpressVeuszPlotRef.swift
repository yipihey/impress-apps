import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Cross-app reference to a Veusz plot tracked by an imprint manuscript.
///
/// imprint owns the underlying `.vsz` source and rendered output; other impress
/// apps (impel, impart, etc.) can pass references to a plot via drag-drop or
/// shared-state without depending on imprint's internal types.
public struct ImpressVeuszPlotRef: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let manuscriptID: UUID
    public let renderedFormat: String  // "svg" | "png" | "pdf"
    public let renderedRelativePath: String

    public init(
        id: UUID,
        displayName: String,
        manuscriptID: UUID,
        renderedFormat: String = "svg",
        renderedRelativePath: String
    ) {
        self.id = id
        self.displayName = displayName
        self.manuscriptID = manuscriptID
        self.renderedFormat = renderedFormat
        self.renderedRelativePath = renderedRelativePath
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension ImpressVeuszPlotRef: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .impressVeuszPlotReference)
        ProxyRepresentation(exporting: { $0.displayName })  // fallback: plain text
    }
}
