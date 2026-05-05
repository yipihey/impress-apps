//
//  ImploreHTTPRouter.swift
//  implore
//
//  HTTP API router for implore automation and MCP integration.
//  Provides endpoints for datasets, figures, and figure export.
//

import AppKit
import Foundation
import ImploreCore
import ImploreRustCore
import ImpressAutomation
import ImpressLogging

// MARK: - HTTP Automation Router

/// Routes HTTP requests to appropriate handlers for implore.
///
/// API Endpoints (GET):
/// - `GET /api/status` - Server health and app state
/// - `GET /api/datasets` - List open datasets
/// - `GET /api/datasets/{id}` - Get dataset details
/// - `GET /api/figures` - List all figures
/// - `GET /api/figures/{id}` - Get figure details
/// - `GET /api/figures/{id}/export` - Export figure (params: format, width, height, scale)
/// - `GET /api/logs` - Query log entries
///
/// API Endpoints (POST):
/// - `POST /api/figures` - Create a new figure
///
/// API Endpoints (PATCH):
/// - `PATCH /api/figures/{id}` - Update a figure
///
/// API Endpoints (DELETE):
/// - `DELETE /api/figures/{id}` - Delete a figure
///
/// - `OPTIONS /*` - CORS preflight
public actor ImploreHTTPRouter: HTTPRouter {

    // MARK: - Configuration

    /// Default HTTP server port
    public static let defaultPort: UInt16 = 23124

    // MARK: - Initialization

    public init() {}

    // MARK: - Routing

    /// Route a request to the appropriate handler.
    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return handleCORSPreflight()
        }

        let path = request.path.lowercased()
        let originalPath = request.path

        switch request.method {
        case "GET":
            return await routeGET(path: path, originalPath: originalPath, request: request)
        case "POST":
            return await routePOST(path: path, request: request)
        case "PATCH":
            return await routePATCH(path: path, originalPath: originalPath, request: request)
        case "DELETE":
            return await routeDELETE(path: path, originalPath: originalPath, request: request)
        default:
            return .badRequest("Method not allowed: \(request.method)")
        }
    }

    // MARK: - GET Routes

    private func routeGET(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/status" {
            return await handleStatus()
        }

        if path == "/api/datasets" {
            return await handleListDatasets()
        }

        // GET /api/datasets/{id}
        if path.hasPrefix("/api/datasets/") && !path.contains("/export") {
            let id = String(originalPath.dropFirst("/api/datasets/".count))
            return await handleGetDataset(id: id)
        }

        if path == "/api/figures" {
            return await handleListFigures(request)
        }

        // GET /api/figures/{id}/export
        if path.hasPrefix("/api/figures/") && path.hasSuffix("/export") {
            let id = String(originalPath.dropFirst("/api/figures/".count).dropLast("/export".count))
            return await handleExportFigure(id: id, request: request)
        }

        // GET /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleGetFigure(id: id)
        }

        // RG viewer endpoints
        if path == "/api/rg/state" {
            return await handleRgState()
        }
        if path == "/api/rg/slice/png" {
            return await handleRgSlicePng(request)
        }
        if path == "/api/rg/slice/raw" {
            return await handleRgSliceRaw(request)
        }
        if path == "/api/rg/statistics" {
            return await handleRgStatistics(request)
        }
        if path == "/api/rg/colormaps" {
            return handleRgColormaps()
        }

        // Plot endpoints
        if path == "/api/plot/svg" {
            return await handlePlotSvg(request)
        }
        if path == "/api/plot/histogram" {
            return await handlePlotHistogram(request)
        }
        if path == "/api/rg/cascade_plot" {
            return await handleRgCascadePlot()
        }

        if path == "/api/logs" {
            return await LogEndpointHandler.handle(request)
        }

        // Root path - return API info
        if path == "/" || path == "/api" {
            return handleAPIInfo()
        }

        return .notFound("Unknown endpoint: \(request.path)")
    }

    // MARK: - POST Routes

    private func routePOST(path: String, request: HTTPRequest) async -> HTTPResponse {
        if path == "/api/figures" {
            return await handleCreateFigure(request)
        }

        // RG viewer POST endpoints
        if path == "/api/rg/load" {
            return await handleRgLoad(request)
        }
        if path == "/api/rg/control" {
            return await handleRgControl(request)
        }
        if path == "/api/rg/slice/save" {
            return await handleRgSliceSave(request)
        }
        if path == "/api/rg/batch" {
            return await handleRgBatch(request)
        }

        return .notFound("Unknown POST endpoint: \(path)")
    }

    // MARK: - PATCH Routes

    private func routePATCH(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        // PATCH /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleUpdateFigure(id: id, request: request)
        }

        return .notFound("Unknown PATCH endpoint: \(path)")
    }

    // MARK: - DELETE Routes

    private func routeDELETE(path: String, originalPath: String, request: HTTPRequest) async -> HTTPResponse {
        // DELETE /api/figures/{id}
        if path.hasPrefix("/api/figures/") {
            let id = String(originalPath.dropFirst("/api/figures/".count))
            return await handleDeleteFigure(id: id)
        }

        return .notFound("Unknown DELETE endpoint: \(path)")
    }

    // MARK: - Status Handler

    /// GET /api/status
    @MainActor
    private func handleStatus() async -> HTTPResponse {
        let library = LibraryManager.shared.library

        var response: [String: Any] = [
            "status": "ok",
            "app": "implore",
            "version": "1.0.0",
            "port": Int(Self.defaultPort),
            "openDatasets": 0,
            "figureCount": library.figures.count,
            "folderCount": library.folders.count
        ]

        // Include RG viewer state if loaded
        if let viewer = AppState.shared?.rgViewerState {
            response["rgViewer"] = buildRgStateDict(viewer)
        }

        return .json(response)
    }

    // MARK: - Dataset Handlers

    /// GET /api/datasets
    private func handleListDatasets() async -> HTTPResponse {
        // For now, return empty - datasets are session-based and not yet fully integrated
        let response: [String: Any] = [
            "status": "ok",
            "count": 0,
            "datasets": [] as [[String: Any]]
        ]
        return .json(response)
    }

    /// GET /api/datasets/{id}
    private func handleGetDataset(id: String) async -> HTTPResponse {
        // For now, return not found - datasets are session-based
        return .notFound("Dataset not found: \(id)")
    }

    // MARK: - Figure Handlers

    /// GET /api/figures
    @MainActor
    private func handleListFigures(_ request: HTTPRequest) async -> HTTPResponse {
        let datasetFilter = request.queryParams["dataset"]

        let library = LibraryManager.shared.library
        var figures = library.figures

        // Filter by dataset if specified
        if let datasetId = datasetFilter {
            figures = figures.filter { $0.sessionId == datasetId }
        }

        let figureDicts = figures.map { figureToDict($0) }

        let response: [String: Any] = [
            "status": "ok",
            "count": figures.count,
            "figures": figureDicts
        ]

        return .json(response)
    }

    /// GET /api/figures/{id}
    @MainActor
    private func handleGetFigure(id: String) async -> HTTPResponse {
        let figure = LibraryManager.shared.figure(id: id)

        guard let figure = figure else {
            return .notFound("Figure not found: \(id)")
        }

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response)
    }

    /// POST /api/figures
    @MainActor
    private func handleCreateFigure(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let datasetId = json["datasetId"] as? String else {
            return .badRequest("Missing required field: datasetId")
        }

        guard let typeString = json["type"] as? String else {
            return .badRequest("Missing required field: type")
        }

        let name = json["name"] as? String ?? "Untitled Figure"
        let title = json["title"] as? String
        let xColumn = json["xColumn"] as? String
        let yColumn = json["yColumn"] as? String
        let colorColumn = json["colorColumn"] as? String
        let width = json["width"] as? Int ?? 800
        let height = json["height"] as? Int ?? 600

        // Create a minimal view state JSON
        var viewState: [String: Any] = [
            "type": typeString,
            "width": width,
            "height": height
        ]
        if let x = xColumn { viewState["xColumn"] = x }
        if let y = yColumn { viewState["yColumn"] = y }
        if let color = colorColumn { viewState["colorColumn"] = color }
        if let t = title { viewState["title"] = t }

        guard let viewStateData = try? JSONSerialization.data(withJSONObject: viewState),
              let viewStateJson = String(data: viewStateData, encoding: .utf8) else {
            return .serverError("Failed to serialize view state")
        }

        let now = ISO8601DateFormatter().string(from: Date())

        // Create the figure using ImploreCore types
        let figure = LibraryFigure(
            id: UUID().uuidString,
            title: name,
            thumbnail: nil,
            sessionId: datasetId,
            viewStateSnapshot: viewStateJson,
            datasetSource: .inMemory(format: "generated"),
            imprintLinks: [],
            tags: [],
            folderId: nil,
            createdAt: now,
            modifiedAt: now
        )

        LibraryManager.shared.addFigure(figure)

        logInfo("Created figure: \(figure.id)", category: "figure-api")

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response, status: 201)
    }

    /// PATCH /api/figures/{id}
    @MainActor
    private func handleUpdateFigure(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard var figure = LibraryManager.shared.figure(id: id) else {
            return .notFound("Figure not found: \(id)")
        }

        // Update mutable fields
        if let name = json["name"] as? String {
            figure.title = name
        }

        // Parse and update view state if needed
        if var viewState = try? JSONSerialization.jsonObject(with: Data(figure.viewStateSnapshot.utf8)) as? [String: Any] {
            var updated = false

            if let type = json["type"] as? String {
                viewState["type"] = type
                updated = true
            }
            if let xColumn = json["xColumn"] as? String {
                viewState["xColumn"] = xColumn
                updated = true
            }
            if let yColumn = json["yColumn"] as? String {
                viewState["yColumn"] = yColumn
                updated = true
            }
            if let colorColumn = json["colorColumn"] as? String {
                viewState["colorColumn"] = colorColumn
                updated = true
            }
            if let title = json["title"] as? String {
                viewState["title"] = title
                updated = true
            }
            if let width = json["width"] as? Int {
                viewState["width"] = width
                updated = true
            }
            if let height = json["height"] as? Int {
                viewState["height"] = height
                updated = true
            }

            if updated {
                if let data = try? JSONSerialization.data(withJSONObject: viewState),
                   let jsonString = String(data: data, encoding: .utf8) {
                    figure.viewStateSnapshot = jsonString
                }
            }
        }

        figure.modifiedAt = ISO8601DateFormatter().string(from: Date())

        LibraryManager.shared.updateFigure(figure)

        let response: [String: Any] = [
            "status": "ok",
            "figure": figureToDict(figure)
        ]

        return .json(response)
    }

    /// DELETE /api/figures/{id}
    @MainActor
    private func handleDeleteFigure(id: String) async -> HTTPResponse {
        let exists = LibraryManager.shared.figure(id: id) != nil

        if !exists {
            return .notFound("Figure not found: \(id)")
        }

        LibraryManager.shared.removeFigure(id: id)

        logInfo("Deleted figure: \(id)", category: "figure-api")

        let response: [String: Any] = [
            "status": "ok",
            "deleted": true
        ]

        return .json(response)
    }

    /// GET /api/figures/{id}/export
    @MainActor
    private func handleExportFigure(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let _ = LibraryManager.shared.figure(id: id) else {
            return .notFound("Figure not found: \(id)")
        }

        let format = request.queryParams["format"] ?? "png"
        let width = request.queryParams["width"].flatMap { Int($0) } ?? 800
        let height = request.queryParams["height"].flatMap { Int($0) } ?? 600
        let scale = request.queryParams["scale"].flatMap { Double($0) } ?? 1.0

        guard ["png", "svg", "pdf"].contains(format) else {
            return .badRequest("Unsupported format: \(format). Use 'png', 'svg', or 'pdf'.")
        }

        // For now, return a placeholder response indicating export capability
        // Full implementation would render the figure using Metal/Core Graphics
        let response: [String: Any] = [
            "status": "ok",
            "id": id,
            "format": format,
            "width": Int(Double(width) * scale),
            "height": Int(Double(height) * scale),
            "data": "" // TODO: Generate actual export data
        ]

        logInfo("Export requested for figure \(id) as \(format)", category: "figure-api")

        return .json(response)
    }

    // MARK: - RG Viewer Handlers

    /// POST /api/rg/load — Load an .npz file by path.
    @MainActor
    private func handleRgLoad(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request),
              let path = json["path"] as? String else {
            return .badRequest("Missing required field: path")
        }

        logInfo("RG load: \(path)", category: "rg-api")

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .notFound("File not found: \(path)")
        }

        guard let appState = AppState.shared else {
            return .serverError("AppState not initialized")
        }

        await appState.loadDataset(url: url)

        if let error = appState.errorMessage {
            return .serverError(error)
        }

        guard let viewer = appState.rgViewerState else {
            return .serverError("Failed to initialize RG viewer")
        }

        logInfo("RG loaded: grid=\(viewer.info.gridSize), quantities=\(viewer.info.availableQuantities.count)", category: "rg-api")

        return .json([
            "status": "ok",
            "dataset": buildDatasetInfoDict(viewer)
        ] as [String: Any])
    }

    /// GET /api/rg/state — Current viewer state + dataset info.
    @MainActor
    private func handleRgState() async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .json([
                "status": "ok",
                "loaded": false
            ] as [String: Any])
        }

        return .json([
            "status": "ok",
            "loaded": true,
            "viewer": buildRgStateDict(viewer),
            "dataset": buildDatasetInfoDict(viewer)
        ] as [String: Any])
    }

    /// POST /api/rg/control — Change quantity/axis/position/colormap.
    @MainActor
    private func handleRgControl(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        logInfo("RG control: \(json)", category: "rg-api")

        // Apply in order: quantity → axis (resets position) → position → colormap
        if let quantity = json["quantity"] as? String {
            guard viewer.info.availableQuantities.contains(quantity) else {
                return .badRequest("Unknown quantity: \(quantity). Available: \(viewer.info.availableQuantities.joined(separator: ", "))")
            }
            viewer.quantity = quantity
        }

        if let axis = json["axis"] as? String {
            viewer.setAxis(axis)
        }

        if let position = json["position"] as? Int {
            viewer.setPosition(position)
        }

        if let colormap = json["colormap"] as? String {
            guard RgViewerState.availableColormaps.contains(colormap) else {
                return .badRequest("Unknown colormap: \(colormap). Available: \(RgViewerState.availableColormaps.joined(separator: ", "))")
            }
            viewer.colormap = colormap
        }

        viewer.updateSlice()

        logInfo("RG control result: \(viewer.quantity) \(viewer.axis)=\(viewer.slicePosition) colormap=\(viewer.colormap)", category: "rg-api")

        return .json([
            "status": "ok",
            "viewer": buildRgStateDict(viewer)
        ] as [String: Any])
    }

    /// GET /api/rg/slice/png — Export current slice as PNG image.
    @MainActor
    private func handleRgSlicePng(_ request: HTTPRequest) async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        let format = request.queryParams["format"]

        // Support ad-hoc slice parameters without changing viewer state
        let slice: SliceData
        if let q = request.queryParams["quantity"],
           let a = request.queryParams["axis"],
           let pStr = request.queryParams["position"],
           let p = UInt32(pStr) {
            let cmap = request.queryParams["colormap"] ?? viewer.colormap
            do {
                slice = try viewer.dataset.getSlice(quantity: q, axis: a, position: p, colormap: cmap)
            } catch {
                return .serverError("Failed to compute slice: \(error)")
            }
        } else if let current = viewer.currentSlice {
            slice = current
        } else {
            return .serverError("No current slice available")
        }

        guard let pngData = rgbaToPNG(rgba: [UInt8](slice.rgbaBytes), width: Int(slice.width), height: Int(slice.height)) else {
            return .serverError("Failed to encode PNG")
        }

        logInfo("RG slice PNG: \(slice.width)x\(slice.height), \(pngData.count) bytes", category: "rg-api")

        if format == "base64" {
            let b64 = pngData.base64EncodedString()
            return .json([
                "status": "ok",
                "width": Int(slice.width),
                "height": Int(slice.height),
                "png_base64": b64,
                "min": slice.minValue,
                "max": slice.maxValue
            ] as [String: Any])
        }

        // Return raw PNG bytes
        return .png(pngData)
    }

    /// POST /api/rg/slice/save — Save current slice PNG to disk.
    @MainActor
    private func handleRgSliceSave(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request),
              let path = json["path"] as? String else {
            return .badRequest("Missing required field: path")
        }

        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        guard let slice = viewer.currentSlice else {
            return .serverError("No current slice available")
        }

        guard let pngData = rgbaToPNG(rgba: [UInt8](slice.rgbaBytes), width: Int(slice.width), height: Int(slice.height)) else {
            return .serverError("Failed to encode PNG")
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: path))
        } catch {
            return .serverError("Failed to write file: \(error.localizedDescription)")
        }

        logInfo("RG slice saved: \(path) (\(pngData.count) bytes)", category: "rg-api")

        return .json([
            "status": "ok",
            "path": path,
            "size": pngData.count,
            "width": Int(slice.width),
            "height": Int(slice.height)
        ] as [String: Any])
    }

    /// GET /api/rg/slice/raw — Raw f32 values of current or ad-hoc slice.
    @MainActor
    private func handleRgSliceRaw(_ request: HTTPRequest) async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        let q = request.queryParams["quantity"] ?? viewer.quantity
        let a = request.queryParams["axis"] ?? viewer.axis
        let p = request.queryParams["position"].flatMap { UInt32($0) } ?? UInt32(viewer.slicePosition)
        let downsample = request.queryParams["downsample"].flatMap { Int($0) } ?? 1

        logInfo("RG raw slice: \(q) \(a)=\(p) downsample=\(downsample)", category: "rg-api")

        do {
            let raw = try viewer.dataset.getRawSlice(quantity: q, axis: a, position: p)

            var values = raw.values.map { Double($0) }
            var width = Int(raw.width)
            var height = Int(raw.height)

            // Downsample if requested
            if downsample > 1 {
                var downsampled: [Double] = []
                let newW = width / downsample
                let newH = height / downsample
                for iy in 0..<newH {
                    for ix in 0..<newW {
                        downsampled.append(values[iy * downsample * width + ix * downsample])
                    }
                }
                values = downsampled
                width = newW
                height = newH
            }

            return .json([
                "status": "ok",
                "width": width,
                "height": height,
                "values": values,
                "min": Double(raw.minValue),
                "max": Double(raw.maxValue),
                "mean": Double(raw.meanValue),
                "std": Double(raw.stdValue)
            ] as [String: Any])
        } catch {
            return .serverError("Failed to get raw slice: \(error)")
        }
    }

    /// GET /api/rg/statistics — Slice or field statistics.
    @MainActor
    private func handleRgStatistics(_ request: HTTPRequest) async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        let scope = request.queryParams["scope"] ?? "slice"
        let q = request.queryParams["quantity"] ?? viewer.quantity

        logInfo("RG statistics: \(q) scope=\(scope)", category: "rg-api")

        if scope == "field" {
            do {
                let stats = try viewer.dataset.getFieldStatistics(quantity: q)
                return .json([
                    "status": "ok",
                    "scope": "field",
                    "quantity": stats.quantity,
                    "min": Double(stats.minValue),
                    "max": Double(stats.maxValue),
                    "mean": Double(stats.meanValue),
                    "std": Double(stats.stdValue),
                    "nanCount": stats.nanCount,
                    "infCount": stats.infCount,
                    "totalCount": stats.totalCount
                ] as [String: Any])
            } catch {
                return .serverError("Failed to compute field statistics: \(error)")
            }
        } else {
            // Slice scope
            let a = request.queryParams["axis"] ?? viewer.axis
            let p = request.queryParams["position"].flatMap { UInt32($0) } ?? UInt32(viewer.slicePosition)

            do {
                let raw = try viewer.dataset.getRawSlice(quantity: q, axis: a, position: p)
                return .json([
                    "status": "ok",
                    "scope": "slice",
                    "quantity": q,
                    "axis": a,
                    "position": Int(p),
                    "width": Int(raw.width),
                    "height": Int(raw.height),
                    "min": Double(raw.minValue),
                    "max": Double(raw.maxValue),
                    "mean": Double(raw.meanValue),
                    "std": Double(raw.stdValue)
                ] as [String: Any])
            } catch {
                return .serverError("Failed to compute slice statistics: \(error)")
            }
        }
    }

    /// POST /api/rg/batch — Capture multiple positions at once.
    @MainActor
    private func handleRgBatch(_ request: HTTPRequest) async -> HTTPResponse {
        guard let json = parseJSONBody(request) else {
            return .badRequest("Invalid JSON body")
        }

        guard let positions = json["positions"] as? [Int] else {
            return .badRequest("Missing required field: positions (array of ints)")
        }

        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        let q = json["quantity"] as? String ?? viewer.quantity
        let a = json["axis"] as? String ?? viewer.axis
        let cmap = json["colormap"] as? String ?? viewer.colormap

        logInfo("RG batch: \(positions.count) positions, \(q) \(a) \(cmap)", category: "rg-api")

        var results: [[String: Any]] = []

        for pos in positions {
            do {
                let slice = try viewer.dataset.getSlice(
                    quantity: q, axis: a, position: UInt32(pos), colormap: cmap
                )
                var entry: [String: Any] = [
                    "position": pos,
                    "min": Double(slice.minValue),
                    "max": Double(slice.maxValue),
                    "width": Int(slice.width),
                    "height": Int(slice.height)
                ]
                if let pngData = rgbaToPNG(rgba: [UInt8](slice.rgbaBytes), width: Int(slice.width), height: Int(slice.height)) {
                    entry["png_base64"] = pngData.base64EncodedString()
                }
                results.append(entry)
            } catch {
                results.append([
                    "position": pos,
                    "error": "\(error)"
                ])
            }
        }

        logInfo("RG batch complete: \(results.count) slices", category: "rg-api")

        return .json([
            "status": "ok",
            "quantity": q,
            "axis": a,
            "colormap": cmap,
            "slices": results
        ] as [String: Any])
    }

    /// GET /api/rg/colormaps — List available colormap names.
    private func handleRgColormaps() -> HTTPResponse {
        .json([
            "status": "ok",
            "colormaps": RgViewerState.availableColormaps
        ] as [String: Any])
    }

    // MARK: - Plot Handlers

    /// GET /api/plot/svg — Render data series as SVG.
    /// Query params: series (comma-separated names), title (optional).
    @MainActor
    private func handlePlotSvg(_ request: HTTPRequest) async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        guard let seriesParam = request.queryParams["series"] else {
            return .badRequest("Missing required query param: series (comma-separated names)")
        }

        let names = seriesParam.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        let title = request.queryParams["title"] ?? "\(names.count) series"

        logInfo("Plot SVG: \(names.joined(separator: ", "))", category: "plot-api")

        do {
            let svg = try viewer.dataset.plotDataSeries(names: names, title: title)
            return .svg(svg)
        } catch {
            return .serverError("Failed to render plot: \(error)")
        }
    }

    /// GET /api/plot/histogram — Render a field histogram as SVG.
    /// Query params: quantity (default: current), bins (default: auto).
    @MainActor
    private func handlePlotHistogram(_ request: HTTPRequest) async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        let quantity = request.queryParams["quantity"] ?? viewer.quantity
        let bins = request.queryParams["bins"].flatMap { UInt32($0) } ?? 0

        logInfo("Plot histogram: \(quantity) bins=\(bins)", category: "plot-api")

        do {
            let svg = try viewer.dataset.plotFieldHistogram(quantity: quantity, numBins: bins)
            return .svg(svg)
        } catch {
            return .serverError("Failed to render histogram: \(error)")
        }
    }

    /// GET /api/rg/cascade_plot — Canonical mu-vs-level cascade statistics SVG.
    @MainActor
    private func handleRgCascadePlot() async -> HTTPResponse {
        guard let viewer = AppState.shared?.rgViewerState else {
            return .badRequest("No RG dataset loaded")
        }

        guard let svg = viewer.dataset.plotCascadeStats() else {
            return .badRequest("No cascade statistics available in loaded dataset")
        }

        logInfo("Cascade plot rendered via HTTP", category: "plot-api")
        return .svg(svg)
    }

    // MARK: - RG Helpers

    /// Build viewer state dictionary for JSON responses.
    @MainActor
    private func buildRgStateDict(_ viewer: RgViewerState) -> [String: Any] {
        var dict: [String: Any] = [
            "quantity": viewer.quantity,
            "axis": viewer.axis,
            "slicePosition": viewer.slicePosition,
            "maxPosition": Int(viewer.info.gridSize) - 1,
            "colormap": viewer.colormap,
            "sliceVersion": viewer.sliceVersion
        ]

        if let slice = viewer.currentSlice {
            dict["sliceSize"] = [
                "width": Int(slice.width),
                "height": Int(slice.height)
            ]
            dict["valueRange"] = [
                "min": Double(slice.minValue),
                "max": Double(slice.maxValue)
            ]
        }

        return dict
    }

    /// Build dataset info dictionary for JSON responses.
    @MainActor
    private func buildDatasetInfoDict(_ viewer: RgViewerState) -> [String: Any] {
        [
            "gridSize": Int(viewer.info.gridSize),
            "levels": viewer.info.levels.map { Int($0) },
            "time": Double(viewer.info.time),
            "domainSize": Double(viewer.info.domainSize),
            "viscosity": Double(viewer.info.viscosity),
            "availableQuantities": viewer.info.availableQuantities
        ]
    }

    /// Convert RGBA bytes to PNG data (CPU-only, no Metal required).
    nonisolated private func rgbaToPNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var mutableRGBA = rgba
        guard let context = CGContext(
            data: &mutableRGBA,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
        let cgImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - CORS Handler

    /// CORS preflight response.
    private func handleCORSPreflight() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            statusText: "No Content",
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ]
        )
    }

    // MARK: - API Info

    /// Root API info response.
    private func handleAPIInfo() -> HTTPResponse {
        let info: [String: Any] = [
            "name": "implore HTTP API",
            "version": "1.0.0",
            "endpoints": [
                // GET endpoints
                "GET /api/status": "Server health and app state (includes RG viewer state if loaded)",
                "GET /api/datasets": "List open datasets",
                "GET /api/datasets/{id}": "Get dataset details with columns",
                "GET /api/figures": "List all figures (params: dataset)",
                "GET /api/figures/{id}": "Get figure configuration",
                "GET /api/figures/{id}/export": "Export figure (params: format, width, height, scale)",
                "GET /api/rg/state": "Current RG viewer state + dataset info",
                "GET /api/rg/slice/png": "Export current slice as PNG (?format=base64 for JSON)",
                "GET /api/rg/slice/raw": "Raw f32 values (?quantity, ?axis, ?position, ?downsample)",
                "GET /api/rg/statistics": "Slice or field statistics (?quantity, ?scope=slice|field)",
                "GET /api/rg/colormaps": "List available colormap names",
                "GET /api/rg/cascade_plot": "Canonical mu-vs-level cascade statistics SVG",
                "GET /api/plot/svg": "Render data series as SVG (?series=a,b&title=...)",
                "GET /api/plot/histogram": "Render field histogram as SVG (?quantity, ?bins)",
                "GET /api/logs": "Query log entries (params: limit, level, category, search, after)",
                // POST endpoints
                "POST /api/figures": "Create a figure (body: datasetId, type, xColumn?, yColumn?, ...)",
                "POST /api/rg/load": "Load .npz file (body: {path})",
                "POST /api/rg/control": "Change viewer params (body: {quantity?, axis?, position?, colormap?})",
                "POST /api/rg/slice/save": "Save current slice PNG to disk (body: {path})",
                "POST /api/rg/batch": "Capture multiple positions (body: {positions, quantity?, axis?, colormap?})",
                // PATCH endpoints
                "PATCH /api/figures/{id}": "Update a figure",
                // DELETE endpoints
                "DELETE /api/figures/{id}": "Delete a figure"
            ],
            "documentation": "https://github.com/yipihey/impress-apps/wiki/implore-HTTP-API"
        ]
        return .json(info)
    }

    // MARK: - Helpers

    /// Parse JSON body from an HTTP request.
    nonisolated private func parseJSONBody(_ request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body, !body.isEmpty,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Convert a LibraryFigure to a dictionary for JSON serialization.
    nonisolated private func figureToDict(_ figure: LibraryFigure) -> [String: Any] {
        var viewState: [String: Any] = [:]
        if let data = figure.viewStateSnapshot.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            viewState = parsed
        }

        var dict: [String: Any] = [
            "id": figure.id,
            "name": figure.title,
            "datasetId": figure.sessionId,
            "type": viewState["type"] as? String ?? "custom",
            "width": viewState["width"] as? Int ?? 800,
            "height": viewState["height"] as? Int ?? 600,
            "createdAt": figure.createdAt,
            "modifiedAt": figure.modifiedAt
        ]

        if let xColumn = viewState["xColumn"] as? String {
            dict["xColumn"] = xColumn
        }
        if let yColumn = viewState["yColumn"] as? String {
            dict["yColumn"] = yColumn
        }
        if let colorColumn = viewState["colorColumn"] as? String {
            dict["colorColumn"] = colorColumn
        }
        if let title = viewState["title"] as? String {
            dict["title"] = title
        }
        if !figure.tags.isEmpty {
            dict["tags"] = figure.tags
        }
        if let folderId = figure.folderId {
            dict["folderId"] = folderId
        }

        return dict
    }
}

// MARK: - HTTPResponse PNG Extension

extension HTTPResponse {
    /// Create a PNG image response.
    static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: ["Content-Type": "image/png"],
            body: data
        )
    }

    /// Create an SVG image response.
    static func svg(_ content: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            statusText: "OK",
            headers: [
                "Content-Type": "image/svg+xml; charset=utf-8",
                "Access-Control-Allow-Origin": "*",
            ],
            body: content.data(using: .utf8) ?? Data()
        )
    }
}
