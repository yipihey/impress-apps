//
//  PlotAutomationHandler.swift
//  PublicationManagerCore
//
//  Agent-drivable native plotting (standing directive: every feature exposes
//  its capability surface over HTTP + MCP, so agents can drive imbib/imprint
//  without clicking). Shared by BOTH apps' HTTP routers:
//
//    POST /api/plot/render                      { spec }         → { svg, rasterized }
//    POST /api/manuscripts/{id}/plot-figure     { spec, name }   → { relPath, typstSnippet }
//
//  The spec JSON mirrors FfiPlotSpec:
//    { "title": "...", "x": {"scale":"linear"|"log","min":n?,"max":n?,"label":s?},
//      "y": {...}, "series": [{"kind":"line"|"scatter","xs":[...],"ys":[...],
//      "color":{"r":n,"g":n,"b":n}?}], "colormap":"viridis"?, "strategy":"auto"?,
//      "width":n?, "height":n?, "rasterThreshold":n? }
//
//  All real work is Rust-side (impress-plot via ImprintCore FFI); this file
//  only decodes JSON and shapes responses.

import Foundation
import ImprintCore

public enum PlotAutomationHandler {

    // MARK: - Endpoints

    /// POST /api/plot/render — render a spec (series-based `spec` OR direct
    /// z-grid `gridSpec`) to SVG.
    public static func renderPlot(json: [String: Any]) -> (body: [String: Any], status: Int) {
        if let gridJSON = json["gridSpec"] as? [String: Any] {
            guard let grid = decodeGridSpec(gridJSON) else {
                return (["error": "Invalid grid spec"], 400)
            }
            let out = renderGridSvg(spec: grid)
            if let e = out.error, !e.isEmpty {
                return (["error": e, "rasterized": out.rasterized], 422)
            }
            return (["svg": out.svg, "rasterized": out.rasterized], 200)
        }
        guard let spec = decodeSpec(json["spec"] as? [String: Any] ?? json) else {
            return (["error": "Invalid or missing plot spec"], 400)
        }
        let out = renderPlotSvg(spec: spec)
        if let e = out.error, !e.isEmpty {
            return (["error": e, "rasterized": out.rasterized], 422)
        }
        return (["svg": out.svg, "rasterized": out.rasterized], 200)
    }

    /// POST /api/manuscripts/{id}/plot-figure — save the spec's raster into the
    /// manuscript's app-group figures/ dir; returns the insertable snippet.
    public static func saveFigure(
        json: [String: Any], manuscriptID: UUID
    ) -> (body: [String: Any], status: Int) {
        let name = (json["name"] as? String) ?? "plot"
        let dir = ManuscriptFiguresDirectory.manuscriptRoot(for: manuscriptID).path
        let saved: FfiSavedFigure
        if let gridJSON = json["gridSpec"] as? [String: Any] {
            guard let grid = decodeGridSpec(gridJSON) else {
                return (["error": "Invalid grid spec"], 400)
            }
            saved = saveGridFigure(spec: grid, manuscriptDir: dir, name: name)
        } else {
            guard let spec = decodeSpec(json["spec"] as? [String: Any] ?? json) else {
                return (["error": "Invalid or missing plot spec"], 400)
            }
            saved = savePlotFigure(spec: spec, manuscriptDir: dir, name: name)
        }
        if let e = saved.error, !e.isEmpty {
            return (["error": e], 422)
        }
        return (["relPath": saved.relPath, "typstSnippet": saved.typstSnippet], 200)
    }

    // MARK: - Saved plot specs (store-backed)

    /// GET /api/plot/specs — list saved plot specs.
    @MainActor
    public static func listSpecs() -> (body: [String: Any], status: Int) {
        let rows = RustStoreAdapter.shared.listPlotSpecs().map { row -> [String: Any] in
            [
                "id": row.id, "name": row.name, "specKind": row.specKind,
                "dataSource": row.dataSource as Any, "dateModified": row.dateModified,
            ]
        }
        return (["specs": rows, "count": rows.count], 200)
    }

    /// POST /api/plot/specs {name, spec|gridSpec, dataSource?} — save a spec.
    @MainActor
    public static func saveSpec(json: [String: Any]) -> (body: [String: Any], status: Int) {
        let name = (json["name"] as? String) ?? "Untitled plot"
        let kind: String
        let specJSON: [String: Any]
        if let grid = json["gridSpec"] as? [String: Any] {
            guard decodeGridSpec(grid) != nil else { return (["error": "Invalid grid spec"], 400) }
            kind = "grid"
            specJSON = grid
        } else if let spec = json["spec"] as? [String: Any] {
            guard decodeSpec(spec) != nil else { return (["error": "Invalid plot spec"], 400) }
            kind = "series"
            specJSON = spec
        } else {
            return (["error": "Missing spec or gridSpec"], 400)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: specJSON),
            let jsonString = String(data: data, encoding: .utf8)
        else { return (["error": "Could not serialize spec"], 500) }
        guard let row = RustStoreAdapter.shared.savePlotSpec(
            name: name, specKind: kind, specJSON: jsonString,
            dataSource: json["dataSource"] as? String)
        else { return (["error": "Store save failed"], 500) }
        return (["id": row.id, "name": row.name, "specKind": row.specKind], 200)
    }

    /// GET /api/plot/specs/{id} — fetch one (full spec JSON included).
    @MainActor
    public static func getSpec(id: UUID) -> (body: [String: Any], status: Int) {
        guard let row = RustStoreAdapter.shared.getPlotSpec(id: id) else {
            return (["error": "Not found"], 404)
        }
        let spec = (row.specJson.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return ([
            "id": row.id, "name": row.name, "specKind": row.specKind,
            "spec": spec, "dataSource": row.dataSource as Any,
        ], 200)
    }

    /// POST /api/plot/render with {specId} — render a SAVED spec.
    @MainActor
    public static func renderSaved(id: UUID) -> (body: [String: Any], status: Int) {
        guard let row = RustStoreAdapter.shared.getPlotSpec(id: id) else {
            return (["error": "Not found"], 404)
        }
        guard let data = row.specJson.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (["error": "Stored spec unreadable"], 500) }
        if row.specKind == "grid" {
            return renderPlot(json: ["gridSpec": json])
        }
        return renderPlot(json: ["spec": json])
    }

    // MARK: - Spec decoding

    static func decodeSpec(_ json: [String: Any]?) -> FfiPlotSpec? {
        guard let json else { return nil }
        guard let seriesJSON = json["series"] as? [[String: Any]], !seriesJSON.isEmpty else {
            return nil
        }
        var series: [FfiSeries] = []
        for s in seriesJSON {
            guard let xs = doubles(s["xs"]), let ys = doubles(s["ys"]), !xs.isEmpty,
                xs.count == ys.count
            else { return nil }
            let kind: FfiSeriesKind
            switch (s["kind"] as? String)?.lowercased() {
            case "line": kind = .line
            case "contour": kind = .contour
            default: kind = .scatter
            }
            let c = s["color"] as? [String: Any]
            let color = FfiColor(
                r: UInt8(clamping: (c?["r"] as? Int) ?? 31),
                g: UInt8(clamping: (c?["g"] as? Int) ?? 111),
                b: UInt8(clamping: (c?["b"] as? Int) ?? 214)
            )
            series.append(FfiSeries(kind: kind, xs: xs, ys: ys, color: color))
        }
        return FfiPlotSpec(
            title: (json["title"] as? String) ?? "",
            x: decodeAxis(json["x"] as? [String: Any]),
            y: decodeAxis(json["y"] as? [String: Any]),
            series: series,
            strategy: decodeStrategy(json["strategy"] as? String),
            colormap: decodeColormap(json["colormap"] as? String),
            width: (json["width"] as? Double) ?? 340,
            height: (json["height"] as? Double) ?? 220,
            rasterThreshold: UInt32((json["rasterThreshold"] as? Int) ?? 0),
            contourLevels: UInt32((json["contourLevels"] as? Int) ?? 0),
            contourLabels: (json["contourLabels"] as? Bool) ?? true,
            contourLineStyles: decodeLineStyles(json["contourLineStyles"]),
            contourLevelValues: (json["contourLevelValues"] as? [Any]).flatMap(doubles) ?? []
        )
    }

    private static func decodeAxis(_ json: [String: Any]?) -> FfiAxis {
        FfiAxis(
            scale: (json?["scale"] as? String)?.lowercased() == "log" ? .log : .linear,
            min: json?["min"] as? Double,
            max: json?["max"] as? Double,
            label: json?["label"] as? String
        )
    }

    static func decodeGridSpec(_ json: [String: Any]) -> FfiGridSpec? {
        guard let values = doubles(json["values"]),
            let nx = json["nx"] as? Int, let ny = json["ny"] as? Int,
            nx > 1, ny > 1, values.count == nx * ny
        else { return nil }
        let style: FfiGridStyle
        switch (json["style"] as? String)?.lowercased() {
        case "heatmap": style = .heatmap
        case "contour": style = .contour
        default: style = .both
        }
        return FfiGridSpec(
            title: (json["title"] as? String) ?? "",
            values: values,
            nx: UInt32(nx),
            ny: UInt32(ny),
            xMin: (json["xMin"] as? Double) ?? 0,
            xMax: (json["xMax"] as? Double) ?? 1,
            yMin: (json["yMin"] as? Double) ?? 0,
            yMax: (json["yMax"] as? Double) ?? 1,
            xLabel: json["xLabel"] as? String,
            yLabel: json["yLabel"] as? String,
            style: style,
            colormap: decodeColormap(json["colormap"] as? String),
            logScale: (json["logScale"] as? Bool) ?? false,
            contourLevels: UInt32((json["contourLevels"] as? Int) ?? 0),
            contourLevelValues: (json["contourLevelValues"] as? [Any]).flatMap(doubles) ?? [],
            contourLabels: (json["contourLabels"] as? Bool) ?? true,
            contourLineStyles: decodeLineStyles(json["contourLineStyles"]),
            smoothSigma: (json["smoothSigma"] as? Double) ?? 0,
            width: (json["width"] as? Double) ?? 340,
            height: (json["height"] as? Double) ?? 240
        )
    }

    private static func decodeLineStyles(_ any: Any?) -> [FfiLineStyle] {
        guard let arr = any as? [String] else { return [] }
        return arr.compactMap { name in
            switch name.lowercased() {
            case "solid": return .solid
            case "dashed": return .dashed
            case "dotted": return .dotted
            case "dashdotted", "dash-dotted": return .dashDotted
            default: return nil
            }
        }
    }

    private static func decodeStrategy(_ s: String?) -> FfiStrategy {
        switch s?.lowercased() {
        case "vector": return .vector
        case "raster": return .raster
        default: return .auto
        }
    }

    private static func decodeColormap(_ s: String?) -> FfiColormap {
        switch s?.lowercased() {
        case "magma": return .magma
        case "plasma": return .plasma
        case "inferno": return .inferno
        case "cividis": return .cividis
        case "turbo": return .turbo
        case "greys", "grey", "gray": return .greys
        default: return .viridis
        }
    }

    private static func doubles(_ any: Any?) -> [Double]? {
        guard let arr = any as? [Any] else { return nil }
        var out: [Double] = []
        out.reserveCapacity(arr.count)
        for v in arr {
            if let d = v as? Double {
                out.append(d)
            } else if let i = v as? Int {
                out.append(Double(i))
            } else {
                return nil
            }
        }
        return out
    }
}
