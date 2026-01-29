//
//  RMFileParser.swift
//  PublicationManagerCore
//
//  Parser for reMarkable .rm binary annotation files.
//  ADR-019: reMarkable Tablet Integration
//
//  Format documentation: https://remarkablewiki.com/tech/filesystem
//  Based on: https://github.com/juruen/rmapi (rmapi)
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "rmParser")

// MARK: - RM File Parser

/// Parser for reMarkable .rm binary files.
///
/// The .rm format stores stroke data in a binary format:
/// - Header line: "reMarkable .lines file, version=X"
/// - Number of layers (Int32)
/// - For each layer:
///   - Number of strokes (Int32)
///   - For each stroke:
///     - Pen type, color, unknown, width, unknown2 (Int32s and Float)
///     - Number of points (Int32)
///     - For each point: x, y, pressure, tiltX, tiltY, unknown (6 Floats)
public struct RMFileParser {

    // MARK: - Public API

    /// Parse a .rm file from data.
    ///
    /// - Parameter data: The raw .rm file data
    /// - Returns: Parsed RMFile structure
    /// - Throws: RMParseError if parsing fails
    public static func parse(_ data: Data) throws -> RMFile {
        var reader = BinaryReader(data: data)

        // Parse header
        let header = try reader.readLine()
        guard header.hasPrefix("reMarkable .lines file") else {
            logger.error("Invalid header: \(header)")
            throw RMParseError.invalidHeader
        }

        let version = try parseVersion(from: header)
        logger.debug("Parsing .rm file version \(version)")

        // Check supported versions (3, 5, 6 are common)
        // Version check is informational only - we try to parse anyway
        if version < 3 || version > 6 {
            logger.warning("Potentially unsupported version: \(version)")
        }

        // Parse layers
        let layerCount = try reader.readInt32()
        logger.debug("Layer count: \(layerCount)")

        var layers: [RMLayer] = []
        for layerIndex in 0..<layerCount {
            let layer = try parseLayer(&reader, version: version, index: Int(layerIndex))
            layers.append(layer)
        }

        return RMFile(version: version, layers: layers)
    }

    /// Parse a .rm file from a file URL.
    ///
    /// - Parameter url: URL to the .rm file
    /// - Returns: Parsed RMFile structure
    public static func parse(url: URL) throws -> RMFile {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    // MARK: - Private Parsing Methods

    private static func parseVersion(from header: String) throws -> Int {
        // Header format: "reMarkable .lines file, version=X"
        guard let versionRange = header.range(of: "version=") else {
            throw RMParseError.invalidHeader
        }

        let versionStr = header[versionRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let version = Int(versionStr) else {
            throw RMParseError.invalidHeader
        }

        return version
    }

    private static func parseLayer(
        _ reader: inout BinaryReader,
        version: Int,
        index: Int
    ) throws -> RMLayer {
        let strokeCount = try reader.readInt32()
        logger.debug("Layer \(index): \(strokeCount) strokes")

        var strokes: [RMStroke] = []
        for _ in 0..<strokeCount {
            let stroke = try parseStroke(&reader, version: version)
            strokes.append(stroke)
        }

        return RMLayer(name: "Layer \(index + 1)", strokes: strokes)
    }

    private static func parseStroke(_ reader: inout BinaryReader, version: Int) throws -> RMStroke {
        // Stroke header: pen (Int32), color (Int32), unknown (Int32), width (Float)
        let penRaw = try reader.readInt32()
        let colorRaw = try reader.readInt32()
        let _ = try reader.readInt32()  // Unknown field
        let width = try reader.readFloat()

        // Version 5+ has an extra unknown field
        if version >= 5 {
            let _ = try reader.readInt32()  // Unknown field
        }

        let pointCount = try reader.readInt32()

        // Parse pen type with fallback
        let pen = RMStroke.PenType(rawValue: Int(penRaw)) ?? .ballpoint

        // Parse color with fallback
        let color = RMStroke.StrokeColor(rawValue: Int(colorRaw)) ?? .black

        // Parse points
        var points: [RMPoint] = []
        for _ in 0..<pointCount {
            let point = try parsePoint(&reader, version: version)
            points.append(point)
        }

        return RMStroke(pen: pen, color: color, width: width, points: points)
    }

    private static func parsePoint(_ reader: inout BinaryReader, version: Int) throws -> RMPoint {
        // Point format: x, y, pressure, tiltX, tiltY, unknown (6 Floats)
        let x = try reader.readFloat()
        let y = try reader.readFloat()
        let pressure = try reader.readFloat()
        let tiltX = try reader.readFloat()
        let tiltY = try reader.readFloat()
        let _ = try reader.readFloat()  // Unknown (possibly speed)

        return RMPoint(x: x, y: y, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
    }
}

// MARK: - Binary Reader

/// Helper for reading binary data in little-endian format.
struct BinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    /// Current read position.
    var position: Int { offset }

    /// Remaining bytes to read.
    var remaining: Int { data.count - offset }

    /// Read a line of text (until newline or EOF).
    mutating func readLine() throws -> String {
        var bytes: [UInt8] = []
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            if byte == 0x0A {  // LF
                break
            }
            bytes.append(byte)
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw RMParseError.invalidData("Invalid UTF-8 in header")
        }
        return string
    }

    /// Read a 32-bit signed integer (little-endian).
    mutating func readInt32() throws -> Int32 {
        guard offset + 4 <= data.count else {
            throw RMParseError.unexpectedEOF
        }

        let value = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: Int32.self)
        }
        offset += 4
        return Int32(littleEndian: value)
    }

    /// Read a 32-bit float (little-endian).
    mutating func readFloat() throws -> Float {
        guard offset + 4 <= data.count else {
            throw RMParseError.unexpectedEOF
        }

        let bits = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return Float(bitPattern: UInt32(littleEndian: bits))
    }

    /// Skip a number of bytes.
    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw RMParseError.unexpectedEOF
        }
        offset += count
    }

    /// Read raw bytes.
    mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw RMParseError.unexpectedEOF
        }
        let bytes = data[offset..<offset + count]
        offset += count
        return bytes
    }
}
