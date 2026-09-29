import Foundation

/// Typed bridge for communicating with implore (data visualization) via its HTTP API.
public struct ImploreBridge: Sendable {

    /// List figures.
    public static func listFigures(limit: Int = 50) async throws -> [FigureInfo] {
        try await SiblingBridge.shared.get(
            "/api/figures",
            from: .implore,
            query: ["limit": String(limit)]
        )
    }

    /// Get a specific figure.
    public static func getFigure(id: String) async throws -> FigureInfo? {
        do {
            return try await SiblingBridge.shared.get("/api/figures/\(id)", from: .implore)
        } catch SiblingBridgeError.httpError(statusCode: 404) {
            return nil
        }
    }

    /// Export a figure in a specific format.
    public static func exportFigure(id: String, format: String = "png") async throws -> Data {
        let result = try await exportFigureResult(id: id, format: format)
        return result.data
    }

    /// Export rendered bytes and the renderer's local path/hash/MIME metadata.
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

    /// Create a rendered figure from the same fields accepted by the HTTP route.
    /// `series` must be JSON for an array; `spec` must be JSON for an object.
    public static func createFigure(
        datasetID: String,
        plotType: String,
        x: String,
        y: String? = nil,
        name: String? = nil,
        series: Data? = nil,
        spec: Data? = nil,
        svg: String? = nil,
        width: Int64? = nil,
        height: Int64? = nil,
        title: String? = nil,
        colorColumn: String? = nil,
        viewState: String? = nil
    ) async throws -> FigureWriteResult {
        try await createFigure(
            datasetID: datasetID, plotType: plotType, x: x, y: y, name: name,
            series: series, spec: spec, svg: svg, width: width, height: height,
            title: title, colorColumn: colorColumn, viewState: viewState, using: .shared)
    }

    static func createFigure(
        datasetID: String,
        plotType: String,
        x: String,
        y: String?,
        name: String?,
        series: Data?,
        spec: Data?,
        svg: String?,
        width: Int64?,
        height: Int64?,
        title: String?,
        colorColumn: String?,
        viewState: String?,
        using bridge: SiblingBridge
    ) async throws -> FigureWriteResult {
        let arguments: [String: Any] = [
            "dataset_id": datasetID,
            "plot_type": plotType,
            "x": x,
            "y": y as Any? ?? NSNull(),
            "name": name as Any? ?? NSNull(),
            "series": try jsonArgument(series, expected: .array),
            "spec": try jsonArgument(spec, expected: .object),
            "svg": svg as Any? ?? NSNull(),
            "width": width as Any? ?? NSNull(),
            "height": height as Any? ?? NSNull(),
            "title": title as Any? ?? NSNull(),
            "color_column": colorColumn as Any? ?? NSNull(),
            "view_state": viewState as Any? ?? NSNull(),
        ]
        let wire: CreateFigureWire = try await bridge.callVerb(
            "implore-service_create-figure", on: .implore, arguments: arguments)
        return try FigureWriteResult(create: wire)
    }

    /// Partially update a figure. A successful response includes the rerendered artifact.
    public static func updateFigure(
        id: String,
        name: String? = nil,
        plotType: String? = nil,
        x: String? = nil,
        y: String? = nil,
        colorColumn: String? = nil,
        title: String? = nil,
        width: Int64? = nil,
        height: Int64? = nil,
        series: Data? = nil,
        spec: Data? = nil,
        svg: String? = nil,
        viewState: String? = nil
    ) async throws -> FigureWriteResult {
        try await updateFigure(
            id: id, name: name, plotType: plotType, x: x, y: y, colorColumn: colorColumn,
            title: title, width: width, height: height, series: series, spec: spec,
            svg: svg, viewState: viewState, using: .shared)
    }

    static func updateFigure(
        id: String,
        name: String?,
        plotType: String?,
        x: String?,
        y: String?,
        colorColumn: String?,
        title: String?,
        width: Int64?,
        height: Int64?,
        series: Data?,
        spec: Data?,
        svg: String?,
        viewState: String?,
        using bridge: SiblingBridge
    ) async throws -> FigureWriteResult {
        let arguments: [String: Any] = [
            "figure_id": id,
            "name": name as Any? ?? NSNull(),
            "plot_type": plotType as Any? ?? NSNull(),
            "x": x as Any? ?? NSNull(),
            "y": y as Any? ?? NSNull(),
            "color_column": colorColumn as Any? ?? NSNull(),
            "title": title as Any? ?? NSNull(),
            "width": width as Any? ?? NSNull(),
            "height": height as Any? ?? NSNull(),
            "series": try jsonArgument(series, expected: .array),
            "spec": try jsonArgument(spec, expected: .object),
            "svg": svg as Any? ?? NSNull(),
            "view_state": viewState as Any? ?? NSNull(),
        ]
        let wire: UpdateFigureWire = try await bridge.callVerb(
            "implore-service_update-figure", on: .implore, arguments: arguments)
        return try FigureWriteResult(update: wire)
    }

    /// Delete a figure and its unreferenced export/artifact files.
    public static func deleteFigure(id: String) async throws -> Bool {
        try await deleteFigure(id: id, using: .shared)
    }

    static func deleteFigure(id: String, using bridge: SiblingBridge) async throws -> Bool {
        try await bridge.callVerb(
            "implore-service_delete-figure", on: .implore, arguments: ["figure_id": id])
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

    private enum JSONArgumentKind { case array, object }

    private static func jsonArgument(_ data: Data?, expected kind: JSONArgumentKind) throws -> Any {
        guard let data else { return NSNull() }
        let value = try JSONSerialization.jsonObject(with: data)
        switch kind {
        case .array where value is [Any]: return value
        case .object where value is [String: Any]: return value
        default: throw SiblingBridgeError.invalidResponse
        }
    }
}

// MARK: - Result Types

/// Basic figure information from implore.
public struct FigureInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String?
    public let datasetName: String?
    public let format: String?
    public let createdAt: Date?
    public let modifiedAt: Date?
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

/// Exact output of a canonical binary render. `byteCount` is derived from the
/// returned bytes, rather than copied from a potentially stale file response.
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

struct FigureWriteFigureWire: Decodable, Sendable {
    let id: String?
    let name: String?
    let datasetId: String?
    let figureType: String?
    let title: String?
    let width: Int64?
    let height: Int64?
    let xColumn: String?
    let yColumn: String?
    let colorColumn: String?
    let createdAt: String?
    let modifiedAt: String?
    let tags: [String]?
    let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, width, height, tags
        case datasetId = "dataset_id"
        case figureType = "figure_type"
        case xColumn = "x_column"
        case yColumn = "y_column"
        case colorColumn = "color_column"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case folderId = "folder_id"
    }
}

struct FigureArtifactWire: Decodable, Sendable {
    let dataHash: String
    let format: String
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case format, width, height
        case dataHash = "data_hash"
    }
}

struct CreateFigureWire: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let id: String?
    let name: String?
    let datasetId: String?
    let figureType: String?
    let title: String?
    let width: Int64?
    let height: Int64?
    let xColumn: String?
    let yColumn: String?
    let colorColumn: String?
    let createdAt: String?
    let modifiedAt: String?
    let tags: [String]?
    let folderId: String?
    let artifact: FigureArtifactWire?
    let drawnFrom: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, id, name, title, width, height, tags, artifact
        case datasetId = "dataset_id"
        case figureType = "figure_type"
        case xColumn = "x_column"
        case yColumn = "y_column"
        case colorColumn = "color_column"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case folderId = "folder_id"
        case drawnFrom = "drawn_from"
    }
}

struct UpdateFigureWire: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let figure: FigureWriteFigureWire?
    let artifact: FigureArtifactWire?
}

/// Stable mutation result with structured refusals retained for callers.
public struct FigureWriteResult: Sendable {
    public let ok: Bool
    public let error: String?
    public let figure: FigureConfiguration?
    public let artifact: FigureArtifactInfo?
    public let drawnFrom: String?

    init(create wire: CreateFigureWire) throws {
        guard !wire.ok || (wire.id != nil && wire.artifact != nil) else {
            throw SiblingBridgeError.invalidResponse
        }
        self.ok = wire.ok
        self.error = wire.error
        self.figure = wire.id.map {
            FigureConfiguration(
                id: $0, name: wire.name, datasetId: wire.datasetId,
                figureType: wire.figureType, title: wire.title, width: wire.width,
                height: wire.height, xColumn: wire.xColumn, yColumn: wire.yColumn,
                colorColumn: wire.colorColumn, createdAt: wire.createdAt,
                modifiedAt: wire.modifiedAt, tags: wire.tags, folderId: wire.folderId)
        }
        self.artifact = wire.artifact.map(FigureArtifactInfo.init(wire:))
        self.drawnFrom = wire.drawnFrom
    }

    init(update wire: UpdateFigureWire) throws {
        guard !wire.ok || (wire.figure?.id != nil && wire.artifact != nil) else {
            throw SiblingBridgeError.invalidResponse
        }
        self.ok = wire.ok
        self.error = wire.error
        self.figure = wire.figure.flatMap(FigureConfiguration.init(wire:))
        self.artifact = wire.artifact.map(FigureArtifactInfo.init(wire:))
        self.drawnFrom = nil
    }
}

public struct FigureConfiguration: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let datasetId: String?
    public let figureType: String?
    public let title: String?
    public let width: Int64?
    public let height: Int64?
    public let xColumn: String?
    public let yColumn: String?
    public let colorColumn: String?
    public let createdAt: String?
    public let modifiedAt: String?
    public let tags: [String]?
    public let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, width, height, createdAt, modifiedAt, tags, folderId
        case datasetId, xColumn, yColumn, colorColumn
        case figureType = "type"
    }

    fileprivate init(
        id: String, name: String?, datasetId: String?, figureType: String?, title: String?,
        width: Int64?, height: Int64?, xColumn: String?, yColumn: String?, colorColumn: String?,
        createdAt: String?, modifiedAt: String?, tags: [String]?, folderId: String?
    ) {
        self.id = id
        self.name = name
        self.datasetId = datasetId
        self.figureType = figureType
        self.title = title
        self.width = width
        self.height = height
        self.xColumn = xColumn
        self.yColumn = yColumn
        self.colorColumn = colorColumn
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tags = tags
        self.folderId = folderId
    }

    fileprivate init?(wire: FigureWriteFigureWire) {
        guard let id = wire.id else { return nil }
        self.init(
            id: id, name: wire.name, datasetId: wire.datasetId,
            figureType: wire.figureType, title: wire.title, width: wire.width,
            height: wire.height, xColumn: wire.xColumn, yColumn: wire.yColumn,
            colorColumn: wire.colorColumn, createdAt: wire.createdAt,
            modifiedAt: wire.modifiedAt, tags: wire.tags, folderId: wire.folderId)
    }
}

public struct FigureArtifactInfo: Codable, Sendable {
    public let dataHash: String
    public let format: String
    public let width: Int
    public let height: Int

    fileprivate init(wire: FigureArtifactWire) {
        self.dataHash = wire.dataHash
        self.format = wire.format
        self.width = wire.width
        self.height = wire.height
    }
}
