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

    /// POST /api/plot/render — render a spec to SVG.
    public static func renderPlot(json: [String: Any]) -> (body: [String: Any], status: Int) {
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
        guard let spec = decodeSpec(json["spec"] as? [String: Any] ?? json) else {
            return (["error": "Invalid or missing plot spec"], 400)
        }
        let name = (json["name"] as? String) ?? "plot"
        let dir = ManuscriptFiguresDirectory.manuscriptRoot(for: manuscriptID).path
        let saved = savePlotFigure(spec: spec, manuscriptDir: dir, name: name)
        if let e = saved.error, !e.isEmpty {
            return (["error": e], 422)
        }
        return (["relPath": saved.relPath, "typstSnippet": saved.typstSnippet], 200)
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
            contourLevels: UInt32((json["contourLevels"] as? Int) ?? 0)
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
