import Foundation

/// Typed bridge for communicating with implore (data visualization) via canonical verbs.
public struct ImploreBridge: Sendable {

    /// List figures, optionally limiting the local result count.
    public static func listFigures(limit: Int = 50) async throws -> [FigureInfo] {
        let page = try await listFiguresPage(limit: limit)
        return page.figures
    }

    /// List figures with the count needed by callers that expose a response envelope.
    public static func listFiguresPage(limit: Int? = nil) async throws -> FigureListInfo {
        let records: [VerbFigureRecord] = try await SiblingBridge.shared.callVerb(
            "implore-service_list-figures", on: .implore, arguments: ["dataset_id": NSNull()])
        let figures = records.prefix(limit.map { max($0, 0) } ?? records.count)
            .map(FigureInfo.init(record:))
        return FigureListInfo(count: figures.count, figures: figures)
    }

    /// Get a specific figure; a missing figure remains a nil result.
    public static func getFigure(id: String) async throws -> FigureInfo? {
        let record: VerbFigureRecord? = try await SiblingBridge.shared.callVerb(
            "implore-service_get-figure", on: .implore, arguments: ["figure_id": id])
        return record.map(FigureInfo.init(record:))
    }

    /// Export a figure and return its rendered image bytes.
    ///
    /// No Swift callers relied on the previous implementation's raw JSON
    /// route envelope; this now returns the bytes promised by the API.
    public static func exportFigure(id: String, format: String = "png") async throws -> Data {
        let result = try await exportFigureResult(id: id, format: format)
        return result.data
    }

    /// Export rendered bytes and the renderer's local path, SHA-256 and MIME type.
    public static func exportFigureResult(
        id: String,
        format: String = "png",
        width: Double? = nil,
        height: Double? = nil,
        scale: Double? = nil,
        viewState: String? = nil
    ) async throws -> FigureExportResult {
        try await exportFigureResult(
            id: id, format: format, width: width, height: height, scale: scale,
            viewState: viewState, using: .shared)
    }

    /// Check if implore's HTTP API is available.
    public static func isAvailable() async -> Bool {
        await SiblingBridge.shared.isAvailable(.implore)
    }

    static func exportFigureResult(
        id: String,
        format: String,
        width: Double?,
        height: Double?,
        scale: Double?,
        viewState: String?,
        using bridge: SiblingBridge
    ) async throws -> FigureExportResult {
        let wire: FigureExportWire = try await bridge.callVerb(
            "implore-service_export-figure-data",
            on: .implore,
            arguments: [
                "figure_id": id,
                "format": format,
                "width": width as Any? ?? NSNull(),
                "height": height as Any? ?? NSNull(),
                "scale": scale as Any? ?? NSNull(),
                "view_state": viewState as Any? ?? NSNull(),
            ]
        )
        guard !wire.path.isEmpty, !wire.sha256.isEmpty, !wire.mimeType.isEmpty,
              !wire.data.isEmpty else {
            throw SiblingBridgeError.invalidResponse
        }
        return FigureExportResult(
            path: wire.path,
            sha256: wire.sha256,
            mimeType: wire.mimeType,
            data: Data(wire.data)
        )
    }
}

struct VerbFigureRecord: Decodable, Sendable {
    let id: String
    let name: String
    let datasetId: String?
    let figureType: String
    let datasetName: String?
    let width: Int?
    let height: Int?
    let xColumn: String?
    let yColumn: String?
    let colorColumn: String?
    let title: String?
    let createdAt: String?
    let modifiedAt: String?
    let tags: [String]?
    let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, width, height, tags
        case datasetId = "dataset_id"
        case figureType = "figure_type"
        case datasetName = "dataset_name"
        case xColumn = "x_column"
        case yColumn = "y_column"
        case colorColumn = "color_column"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case folderId = "folder_id"
    }
}

extension FigureInfo {
    init(record: VerbFigureRecord) {
        self.init(
            id: record.id,
            title: record.title,
            datasetName: record.datasetName,
            format: nil,
            createdAt: BridgeDate.parse(record.createdAt),
            modifiedAt: BridgeDate.parse(record.modifiedAt),
            name: record.name,
            datasetId: record.datasetId,
            figureType: record.figureType,
            width: record.width,
            height: record.height,
            xColumn: record.xColumn,
            yColumn: record.yColumn,
            colorColumn: record.colorColumn,
            tags: record.tags?.isEmpty == true ? nil : record.tags,
            folderId: record.folderId
        )
    }
}

// MARK: - Result Types

/// Figure metadata projected to the bridge's public shape. HTTP-only metadata
/// absent from the generated record remains nil (not synthesized).
public struct FigureInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let datasetName: String?
    public let format: String?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let name: String?
    public let datasetId: String?
    public let figureType: String?
    public let width: Int?
    public let height: Int?
    public let xColumn: String?
    public let yColumn: String?
    public let colorColumn: String?
    public let tags: [String]?
    public let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id, title, datasetName, format, createdAt, modifiedAt, name, datasetId
        case figureType = "type"
        case width, height, xColumn, yColumn, colorColumn, tags, folderId
    }

    init(
        id: String, title: String?, datasetName: String?, format: String?, createdAt: Date?,
        modifiedAt: Date?, name: String?, datasetId: String?, figureType: String?, width: Int?,
        height: Int?, xColumn: String?, yColumn: String?, colorColumn: String?,
        tags: [String]?, folderId: String?
    ) {
        self.id = id
        self.title = title
        self.datasetName = datasetName
        self.format = format
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.name = name
        self.datasetId = datasetId
        self.figureType = figureType
        self.width = width
        self.height = height
        self.xColumn = xColumn
        self.yColumn = yColumn
        self.colorColumn = colorColumn
        self.tags = tags
        self.folderId = folderId
    }
}

/// Count and mapped figure data for callers that preserve the legacy list envelope.
public struct FigureListInfo: Codable, Sendable {
    public let status: String
    public let count: Int
    public let figures: [FigureInfo]

    init(count: Int, figures: [FigureInfo]) {
        self.status = "ok"
        self.count = count
        self.figures = figures
    }
}

struct FigureExportWire: Decodable, Sendable {
    let path: String
    let sha256: String
    let mimeType: String
    let data: [UInt8]

    enum CodingKeys: String, CodingKey {
        case path, sha256, data
        case mimeType = "mime_type"
    }
}

/// Exact output of a canonical binary render. `byteCount` derives from the
/// returned bytes rather than a potentially stale file response.
public struct FigureExportResult: Sendable {
    public let path: String
    public let sha256: String
    public let mimeType: String
    public let data: Data
    public var byteCount: Int { data.count }

    fileprivate init(path: String, sha256: String, mimeType: String, data: Data) {
        self.path = path
        self.sha256 = sha256
        self.mimeType = mimeType
        self.data = data
    }
}
