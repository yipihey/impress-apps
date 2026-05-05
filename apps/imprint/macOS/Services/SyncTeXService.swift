import Foundation
import Compression
import ImpressLogging
import OSLog

/// Box wrapper for passing SyncTeXPosition through NotificationCenter.
final class SyncTeXPositionBox: @unchecked Sendable {
    let position: SyncTeXPosition
    init(_ position: SyncTeXPosition) { self.position = position }
}

/// A position in the PDF identified by SyncTeX forward sync.
struct SyncTeXPosition: Sendable, Equatable {
    var page: Int       // 1-indexed
    var x: Double       // points from left
    var y: Double       // points from top
    var width: Double
    var height: Double
}

/// A source location identified by SyncTeX inverse sync.
struct SyncTeXSourceLocation: Sendable {
    var file: String
    var line: Int
    var column: Int
}

/// Parses and queries SyncTeX data for bidirectional source ↔ PDF mapping.
///
/// SyncTeX files are gzipped text files produced by pdflatex/xelatex/lualatex
/// with the `-synctex=1` flag. They contain records mapping source positions
/// to PDF page coordinates.
actor SyncTeXService {
    static let shared = SyncTeXService()

    private var document: SyncTeXDocument?

    /// Load and parse a `.synctex.gz` file.
    func load(from url: URL) throws {
        let compressedData = try Data(contentsOf: url)

        // Decompress gzip
        let decompressed: Data
        if url.pathExtension == "gz" {
            decompressed = try decompressGzip(compressedData)
        } else {
            decompressed = compressedData
        }

        guard let text = String(data: decompressed, encoding: .utf8) else {
            throw SyncTeXError.invalidFormat("Could not decode SyncTeX data as UTF-8")
        }

        document = try SyncTeXParser.parse(text)
        Logger.synctex.infoCapture("Loaded SyncTeX: \(self.document?.inputs.count ?? 0) inputs, \(self.document?.sheets.count ?? 0) sheets", category: "synctex")
        // Diagnostic: show what file IDs and line ranges are in the data
        if let doc = document {
            var fileStats: [Int: (count: Int, minLine: Int, maxLine: Int)] = [:]
            for sheet in doc.sheets {
                for node in sheet.nodes {
                    if var stat = fileStats[node.fileID] {
                        stat.count += 1
                        stat.minLine = min(stat.minLine, node.line)
                        stat.maxLine = max(stat.maxLine, node.line)
                        fileStats[node.fileID] = stat
                    } else {
                        fileStats[node.fileID] = (1, node.line, node.line)
                    }
                }
            }
            for (id, stat) in fileStats.sorted(by: { $0.key < $1.key }).prefix(5) {
                let name = doc.inputs.first { $0.id == id }?.path ?? "?"
                Logger.synctex.infoCapture("  fileID=\(id): \(stat.count) nodes, lines \(stat.minLine)...\(stat.maxLine), path=\((name as NSString).lastPathComponent)", category: "synctex")
            }
        }
    }

    /// Forward sync: source position → PDF position(s).
    func forwardSync(file: String, line: Int, column: Int) -> [SyncTeXPosition] {
        guard let doc = document else {
            Logger.synctex.infoCapture("Forward sync: no SyncTeX document loaded", category: "synctex")
            return []
        }

        // Resolve file to input ID
        guard let inputID = doc.inputID(for: file) else {
            let inputNames = doc.inputs.map { "[\($0.id)]\(($0.path as NSString).lastPathComponent)" }
            Logger.synctex.infoCapture("Forward sync: file '\(file)' not found in inputs: \(inputNames.prefix(10))", category: "synctex")
            return []
        }
        Logger.synctex.infoCapture("Forward sync: file=\(file) → inputID=\(inputID), looking for line=\(line)", category: "synctex")

        var results: [SyncTeXPosition] = []

        // Collect all lines for this file to find the nearest if exact match fails
        var allLines: Set<Int> = []
        for sheet in doc.sheets {
            for node in sheet.nodes where node.fileID == inputID {
                allLines.insert(node.line)
                if node.line == line {
                    results.append(SyncTeXPosition(
                        page: sheet.page,
                        x: node.x,
                        y: node.y,
                        width: node.width,
                        height: node.height
                    ))
                }
            }
        }

        // If exact line not found, find the closest line at or after the target.
        // This ensures we scroll to the content that follows the section heading.
        if results.isEmpty && !allLines.isEmpty {
            let sortedLines = allLines.sorted()
            // Prefer the first SyncTeX line at or after the target
            let nearest = sortedLines.first(where: { $0 >= line })
                ?? sortedLines.last! // fallback to last if target is past all nodes
            Logger.synctex.infoCapture("Forward sync: exact line \(line) not in SyncTeX, nearest=\(nearest), range=\(sortedLines.first ?? 0)...\(sortedLines.last ?? 0)", category: "synctex")

            for sheet in doc.sheets {
                for node in sheet.nodes where node.fileID == inputID && node.line == nearest {
                    results.append(SyncTeXPosition(
                        page: sheet.page,
                        x: node.x,
                        y: node.y,
                        width: node.width,
                        height: node.height
                    ))
                }
            }
        }

        return results
    }

    /// Inverse sync: PDF position → source location.
    func inverseSync(page: Int, x: Double, y: Double) -> SyncTeXSourceLocation? {
        guard let doc = document else { return nil }

        guard let sheet = doc.sheets.first(where: { $0.page == page }) else { return nil }

        // Find the nearest node to the click point
        var bestNode: SyncTeXNode?
        var bestDistance = Double.infinity

        for node in sheet.nodes {
            // Check if point is inside the node's bounding box
            let nodeBottom = node.y + node.height + node.depth
            if x >= node.x && x <= node.x + node.width &&
               y >= node.y && y <= nodeBottom {
                // Inside — prefer this over distance-based
                let area = node.width * (node.height + node.depth)
                if area < bestDistance || bestNode == nil {
                    bestDistance = area
                    bestNode = node
                }
            }
        }

        // If no containing node, find nearest
        if bestNode == nil {
            bestDistance = Double.infinity
            for node in sheet.nodes {
                let centerX = node.x + node.width / 2
                let centerY = node.y + node.height / 2
                let dist = (x - centerX) * (x - centerX) + (y - centerY) * (y - centerY)
                if dist < bestDistance {
                    bestDistance = dist
                    bestNode = node
                }
            }
        }

        guard let node = bestNode,
              let filePath = doc.filePath(for: node.fileID) else { return nil }

        return SyncTeXSourceLocation(
            file: filePath,
            line: node.line,
            column: node.column
        )
    }

    /// Clear cached SyncTeX data.
    func clear() {
        document = nil
    }

    // MARK: - Gzip Decompression

    private func decompressGzip(_ data: Data) throws -> Data {
        guard data.count > 18,
              data[data.startIndex] == 0x1f,
              data[data.startIndex + 1] == 0x8b else {
            throw SyncTeXError.invalidFormat("Not a gzip file (missing magic number)")
        }

        // Parse gzip header to find start of deflate stream
        var offset = 10  // minimum gzip header size
        let flags = data[data.startIndex + 3]

        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 < data.count else {
                throw SyncTeXError.invalidFormat("Truncated gzip FEXTRA")
            }
            let xlen = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {  // FNAME — null-terminated string
            if let nullIdx = data[(data.startIndex + offset)...].firstIndex(of: 0) {
                offset = nullIdx - data.startIndex + 1
            }
        }
        if flags & 0x10 != 0 {  // FCOMMENT — null-terminated string
            if let nullIdx = data[(data.startIndex + offset)...].firstIndex(of: 0) {
                offset = nullIdx - data.startIndex + 1
            }
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }

        guard offset < data.count - 8 else {
            throw SyncTeXError.invalidFormat("Gzip header exceeds data size")
        }

        // Extract raw deflate payload (strip gzip header and 8-byte trailer)
        let compressed = data[(data.startIndex + offset)..<(data.endIndex - 8)]
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }
}

// MARK: - Data Model

struct SyncTeXDocument {
    var inputs: [SyncTeXInput]   // file_id → file_path
    var sheets: [SyncTeXSheet]   // per-page records

    func inputID(for file: String) -> Int? {
        // Match by exact path or by filename
        let fileName = (file as NSString).lastPathComponent
        return inputs.first { input in
            input.path == file ||
            (input.path as NSString).lastPathComponent == fileName ||
            input.path.hasSuffix(file)
        }?.id
    }

    func filePath(for id: Int) -> String? {
        inputs.first { $0.id == id }?.path
    }
}

struct SyncTeXInput {
    var id: Int
    var path: String
}

struct SyncTeXSheet {
    var page: Int
    var nodes: [SyncTeXNode]
}

struct SyncTeXNode {
    var fileID: Int
    var line: Int
    var column: Int
    var x: Double       // scaled points → points
    var y: Double
    var width: Double
    var height: Double
    var depth: Double
}

// MARK: - Parser

enum SyncTeXParser {
    /// Parse SyncTeX text format into a structured document.
    static func parse(_ text: String) throws -> SyncTeXDocument {
        var inputs: [SyncTeXInput] = []
        var sheets: [SyncTeXSheet] = []
        var currentSheet: SyncTeXSheet?
        var parsedNodeCount = 0
        var skippedNodeCount = 0

        // SyncTeX uses scaled points (sp): 1 pt = 65536 sp
        let spToPoints: Double = 1.0 / 65536.0

        // Track magnification and unit from header
        var magnification: Double = 1000.0
        var unit: Double = 1.0

        let lines = text.components(separatedBy: "\n")

        for line in lines {
            if line.isEmpty { continue }

            // Input declarations: "Input:ID:PATH"
            if line.hasPrefix("Input:") {
                let parts = line.dropFirst(6).split(separator: ":", maxSplits: 1)
                if parts.count == 2, let id = Int(parts[0]) {
                    inputs.append(SyncTeXInput(id: id, path: String(parts[1])))
                }
                continue
            }

            // Magnification: "Magnification:1000"
            if line.hasPrefix("Magnification:") {
                if let val = Double(line.dropFirst("Magnification:".count)) {
                    magnification = val
                }
                continue
            }

            // Unit: "Unit:1"
            if line.hasPrefix("Unit:") {
                if let val = Double(line.dropFirst("Unit:".count)) {
                    unit = val
                }
                continue
            }

            // Sheet start: "{PAGE" (page is 1-indexed)
            if line.hasPrefix("{") {
                if let page = Int(line.dropFirst(1)) {
                    // Save previous sheet
                    if let sheet = currentSheet {
                        sheets.append(sheet)
                    }
                    currentSheet = SyncTeXSheet(page: page, nodes: [])
                }
                continue
            }

            // Sheet end: "}"
            if line == "}" {
                if let sheet = currentSheet {
                    sheets.append(sheet)
                    currentSheet = nil
                }
                continue
            }

            // Node records: type followed by colon-separated values
            // SyncTeX v1: "h FILE_ID:LINE:COL:X:Y:W:H:D" (space after type)
            // SyncTeX v2: "hFILE_ID,LINE,COL:X,Y,W,H,D" (comma-separated in some versions)
            let firstChar = line.first
            guard firstChar == "h" || firstChar == "v" || firstChar == "k" ||
                  firstChar == "g" || firstChar == "x" || firstChar == "$" ||
                  firstChar == "[" || firstChar == "]" || firstChar == "(" || firstChar == ")" else {
                continue
            }

            // Parse h (hbox), v (vbox), k (kern), g (glue), x (current) — all carry position info
            guard firstChar == "h" || firstChar == "v" || firstChar == "k" || firstChar == "g" || firstChar == "x" else { continue }

            let data = line.dropFirst(1) // drop the type character

            // SyncTeX record format: hFILEID,LINE:X,Y:W,H,D
            // Colons separate groups, commas separate values within groups
            let groups = data.split(separator: ":", maxSplits: 2).map(String.init)
            guard groups.count >= 2 else {
                skippedNodeCount += 1
                continue
            }

            // Group 1: fileID,line (and optionally ,column)
            let idLineParts = groups[0].split(separator: ",").map(String.init)
            guard idLineParts.count >= 2,
                  let fileID = Int(idLineParts[0]),
                  let lineNum = Int(idLineParts[1]) else {
                skippedNodeCount += 1
                continue
            }

            // Group 2: x,y
            let xyParts = groups[1].split(separator: ",").map(String.init)
            guard xyParts.count >= 2,
                  let rawX = Double(xyParts[0]),
                  let rawY = Double(xyParts[1]) else {
                skippedNodeCount += 1
                continue
            }

            // Group 3: w,h,d (optional — some records only have position)
            var rawW = 0.0, rawH = 0.0, rawD = 0.0
            if groups.count >= 3 {
                let whdParts = groups[2].split(separator: ",").map(String.init)
                if whdParts.count >= 1 { rawW = Double(whdParts[0]) ?? 0 }
                if whdParts.count >= 2 { rawH = Double(whdParts[1]) ?? 0 }
                if whdParts.count >= 3 { rawD = Double(whdParts[2]) ?? 0 }
            }

            parsedNodeCount += 1

            // Convert from SyncTeX units to points
            let scale = unit * magnification / 1000.0 * spToPoints
            let col = idLineParts.count >= 3 ? (Int(idLineParts[2]) ?? 0) : 0
            let node = SyncTeXNode(
                fileID: fileID,
                line: lineNum,
                column: col,
                x: rawX * scale,
                y: rawY * scale,
                width: rawW * scale,
                height: rawH * scale,
                depth: rawD * scale
            )

            currentSheet?.nodes.append(node)
        }

        // Don't forget the last sheet
        if let sheet = currentSheet {
            sheets.append(sheet)
        }

        let totalNodes = sheets.reduce(0) { $0 + $1.nodes.count }
        Logger.synctex.infoCapture("SyncTeX parse: \(parsedNodeCount) nodes parsed, \(skippedNodeCount) skipped, \(totalNodes) in sheets, \(sheets.count) sheets", category: "synctex")
        return SyncTeXDocument(inputs: inputs, sheets: sheets)
    }
}

// MARK: - Errors

enum SyncTeXError: LocalizedError {
    case invalidFormat(String)
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): "Invalid SyncTeX format: \(msg)"
        case .fileNotFound(let path): "SyncTeX file not found: \(path)"
        }
    }
}
