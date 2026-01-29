//
//  RMTypes.swift
//  PublicationManagerCore
//
//  Data structures for reMarkable .rm file format.
//  ADR-019: reMarkable Tablet Integration
//
//  Format documentation: https://remarkablewiki.com/tech/filesystem
//

import Foundation
import CoreGraphics

// MARK: - RM File

/// Represents a parsed .rm annotation file.
public struct RMFile: Sendable {
    /// File format version (typically 3, 5, or 6).
    public let version: Int

    /// Layers containing strokes (typically named "Layer 1", etc.).
    public let layers: [RMLayer]

    public init(version: Int, layers: [RMLayer]) {
        self.version = version
        self.layers = layers
    }

    /// Total stroke count across all layers.
    public var totalStrokeCount: Int {
        layers.reduce(0) { $0 + $1.strokes.count }
    }

    /// Whether this file has any strokes.
    public var isEmpty: Bool {
        layers.allSatisfy { $0.strokes.isEmpty }
    }
}

// MARK: - RM Layer

/// A layer within an .rm file (reMarkable supports multiple layers).
public struct RMLayer: Sendable {
    /// Layer name (may be empty for default layer).
    public let name: String

    /// Strokes in this layer.
    public let strokes: [RMStroke]

    public init(name: String, strokes: [RMStroke]) {
        self.name = name
        self.strokes = strokes
    }
}

// MARK: - RM Stroke

/// A single stroke (pen/highlighter mark) in an .rm file.
public struct RMStroke: Sendable {
    /// Pen type used for this stroke.
    public let pen: PenType

    /// Color of the stroke.
    public let color: StrokeColor

    /// Base width multiplier.
    public let width: Float

    /// Individual points that make up the stroke.
    public let points: [RMPoint]

    public init(pen: PenType, color: StrokeColor, width: Float, points: [RMPoint]) {
        self.pen = pen
        self.color = color
        self.width = width
        self.points = points
    }

    /// Calculate the bounding box of this stroke.
    public var bounds: CGRect {
        guard !points.isEmpty else { return .zero }

        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude

        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }

        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX),
            height: CGFloat(maxY - minY)
        )
    }

    /// Whether this is a highlighter stroke.
    public var isHighlight: Bool {
        pen == .highlighter
    }

    /// Whether this is an eraser stroke.
    public var isEraser: Bool {
        pen == .eraser || pen == .eraserArea
    }

    // MARK: - Pen Types

    /// reMarkable pen tool types (firmware v2.x+).
    public enum PenType: Int, Sendable, CaseIterable {
        case ballpoint = 2
        case marker = 3
        case fineliner = 4
        case highlighter = 5
        case eraser = 6
        case pencilSharp = 7        // Mechanical pencil (sharp)
        case eraserArea = 8
        case brush = 12
        case pencilTilt = 13        // Mechanical pencil (tilt)
        case calligraphy = 21

        /// Display name for UI.
        public var displayName: String {
            switch self {
            case .ballpoint: return "Ballpoint"
            case .marker: return "Marker"
            case .fineliner: return "Fineliner"
            case .highlighter: return "Highlighter"
            case .eraser: return "Eraser"
            case .pencilSharp: return "Pencil"
            case .eraserArea: return "Area Eraser"
            case .brush: return "Brush"
            case .pencilTilt: return "Pencil (Tilt)"
            case .calligraphy: return "Calligraphy"
            }
        }
    }

    // MARK: - Stroke Colors

    /// reMarkable stroke colors.
    public enum StrokeColor: Int, Sendable, CaseIterable {
        case black = 0
        case grey = 1
        case white = 2
        case yellow = 3
        case green = 4
        case pink = 5
        case blue = 6
        case red = 7
        case greyOverlap = 8  // Used for overlapping grey strokes

        /// Convert to hex color string.
        public var hexColor: String {
            switch self {
            case .black: return "#000000"
            case .grey, .greyOverlap: return "#808080"
            case .white: return "#FFFFFF"
            case .yellow: return "#FFFF00"
            case .green: return "#00CC33"
            case .pink: return "#FF6699"
            case .blue: return "#3366FF"
            case .red: return "#FF3333"
            }
        }

        /// Convert to CGColor.
        public var cgColor: CGColor {
            switch self {
            case .black: return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            case .grey, .greyOverlap: return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            case .yellow: return CGColor(red: 1, green: 1, blue: 0, alpha: 1)
            case .green: return CGColor(red: 0, green: 0.8, blue: 0.2, alpha: 1)
            case .pink: return CGColor(red: 1, green: 0.4, blue: 0.6, alpha: 1)
            case .blue: return CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)
            case .red: return CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
            }
        }
    }
}

// MARK: - RM Point

/// A single point in a stroke with pressure and tilt data.
public struct RMPoint: Sendable {
    /// X coordinate (in reMarkable units, 0-1404).
    public let x: Float

    /// Y coordinate (in reMarkable units, 0-1872).
    public let y: Float

    /// Pen pressure (0.0-1.0).
    public let pressure: Float

    /// Tilt in X direction.
    public let tiltX: Float

    /// Tilt in Y direction.
    public let tiltY: Float

    public init(x: Float, y: Float, pressure: Float, tiltX: Float, tiltY: Float) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
    }

    /// Convert to CGPoint.
    public var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

// MARK: - Page Dimensions

/// reMarkable page dimensions in device units.
public enum RMPageDimensions {
    /// Page width in device units.
    public static let width: CGFloat = 1404

    /// Page height in device units.
    public static let height: CGFloat = 1872

    /// Aspect ratio (height/width).
    public static let aspectRatio: CGFloat = height / width

    /// Convert device units to PDF points at given scale.
    public static func toPDFPoints(deviceUnits: CGFloat, scale: CGFloat = 1.0) -> CGFloat {
        deviceUnits * scale
    }
}

// MARK: - Parse Errors

/// Errors that can occur while parsing .rm files.
public enum RMParseError: LocalizedError, Sendable {
    case invalidHeader
    case unsupportedVersion(Int)
    case unexpectedEOF
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid .rm file header"
        case .unsupportedVersion(let version):
            return "Unsupported .rm file version: \(version)"
        case .unexpectedEOF:
            return "Unexpected end of file"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        }
    }
}
