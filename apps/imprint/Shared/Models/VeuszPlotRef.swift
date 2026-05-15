import Foundation

/// Reference to a Veusz plot (.vsz source + rendered output) tracked by a manuscript.
///
/// `.vsz` files live inside the `.imprint` package under `figures/`. Each `VeuszPlotRef`
/// records the in-package paths, the export format, and the freshness of the rendered
/// output relative to the source so the Plots panel can show a status dot per plot.
public struct VeuszPlotRef: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var sourceRelativePath: String
    public var renderedRelativePath: String
    public var exportFormat: ExportFormat
    public var lastRenderedAt: Date?
    public var sourceModifiedAt: Date?
    public var renderStatus: RenderStatus

    /// Relative path inside the `.imprint` bundle to a JSON-LD provenance
    /// sidecar for the last rendered figure, when one was emitted.
    /// (ADR-0014 D57.) Older refs default to nil.
    public var provenanceRelativePath: String?

    public enum ExportFormat: String, Codable, CaseIterable, Sendable {
        case svg, png, pdf

        public var fileExtension: String { rawValue }
    }

    public enum RenderStatus: Codable, Hashable, Sendable {
        case idle
        case rendering
        case stale
        case failed(String)
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        sourceRelativePath: String,
        renderedRelativePath: String,
        exportFormat: ExportFormat = .svg,
        lastRenderedAt: Date? = nil,
        sourceModifiedAt: Date? = nil,
        renderStatus: RenderStatus = .idle,
        provenanceRelativePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceRelativePath = sourceRelativePath
        self.renderedRelativePath = renderedRelativePath
        self.exportFormat = exportFormat
        self.lastRenderedAt = lastRenderedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.renderStatus = renderStatus
        self.provenanceRelativePath = provenanceRelativePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceRelativePath, renderedRelativePath
        case exportFormat, lastRenderedAt, sourceModifiedAt, renderStatus
        case provenanceRelativePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourceRelativePath = try c.decode(String.self, forKey: .sourceRelativePath)
        renderedRelativePath = try c.decode(String.self, forKey: .renderedRelativePath)
        exportFormat = try c.decodeIfPresent(ExportFormat.self, forKey: .exportFormat) ?? .svg
        lastRenderedAt = try c.decodeIfPresent(Date.self, forKey: .lastRenderedAt)
        sourceModifiedAt = try c.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
        renderStatus = try c.decodeIfPresent(RenderStatus.self, forKey: .renderStatus) ?? .idle
        provenanceRelativePath = try c.decodeIfPresent(String.self, forKey: .provenanceRelativePath)
    }
}
