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
