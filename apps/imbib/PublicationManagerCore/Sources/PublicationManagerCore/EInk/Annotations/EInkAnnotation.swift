//
//  EInkAnnotation.swift
//  PublicationManagerCore
//
//  Unified annotation types for multi-device E-Ink integration.
//  Supports reMarkable, Supernote, and Kindle Scribe.
//

import Foundation
import CoreGraphics

// MARK: - Annotation Bounds

/// Codable representation of annotation bounds.
/// Named EInkAnnotationBounds to avoid conflict with CodableRect in RemarkableTypes.swift.
public struct EInkAnnotationBounds: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Check if this bounds intersects with another.
    public func intersects(_ other: EInkAnnotationBounds) -> Bool {
        cgRect.intersects(other.cgRect)
    }

    /// Check if this bounds contains a point.
    public func contains(x: Double, y: Double) -> Bool {
        cgRect.contains(CGPoint(x: x, y: y))
    }
}

// MARK: - Annotation Color

/// Color representation for E-Ink annotations.
/// Uses hexColorString property to avoid conflict with RMStroke.StrokeColor.hexColor.
public struct EInkAnnotationColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Convert to hex color string (e.g., "#FF0000").
    /// Named hexColorString to avoid conflict with existing hexColor properties.
    public var hexColorString: String {
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Initialize from a hex color string.
    public init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }

        guard hex.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgbValue) else { return nil }

        self.red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        self.green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        self.blue = Double(rgbValue & 0x0000FF) / 255.0
        self.alpha = 1.0
    }

    /// Convert to CGColor.
    public var cgColor: CGColor {
        CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    // MARK: - Predefined Colors

    public static let black = EInkAnnotationColor(red: 0, green: 0, blue: 0)
    public static let grey = EInkAnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
    public static let white = EInkAnnotationColor(red: 1, green: 1, blue: 1)
    public static let yellow = EInkAnnotationColor(red: 1, green: 1, blue: 0)
    public static let green = EInkAnnotationColor(red: 0, green: 0.8, blue: 0.2)
    public static let pink = EInkAnnotationColor(red: 1, green: 0.4, blue: 0.6)
    public static let blue = EInkAnnotationColor(red: 0.2, green: 0.4, blue: 1)
    public static let red = EInkAnnotationColor(red: 1, green: 0.2, blue: 0.2)
}

// MARK: - Annotation Type

/// Types of annotations from E-Ink devices.
public enum EInkAnnotationType: String, Codable, Sendable, CaseIterable {
    /// Highlight annotation (typically transparent overlay).
    case highlight

    /// Freehand ink stroke.
    case ink

    /// Text annotation (typed or recognized).
    case text

    /// Eraser stroke (used for deletion tracking).
    case eraser

    public var displayName: String {
        switch self {
        case .highlight: return "Highlight"
        case .ink: return "Ink"
        case .text: return "Text"
        case .eraser: return "Eraser"
        }
    }

    public var iconName: String {
        switch self {
        case .highlight: return "highlighter"
        case .ink: return "pencil.tip"
        case .text: return "text.cursor"
        case .eraser: return "eraser"
        }
    }
}

// MARK: - Unified Annotation

/// A unified annotation from any E-Ink device.
///
/// This type normalizes annotations from different devices (reMarkable, Supernote,
/// Kindle Scribe) into a common format for processing and display.
public struct EInkAnnotation: Codable, Identifiable, Sendable, Equatable {
    /// Unique identifier for this annotation.
    public let id: String

    /// The source device type.
    public let sourceDevice: EInkDeviceType

    /// Page number (0-indexed).
    public let pageNumber: Int

    /// Type of annotation.
    public let annotationType: EInkAnnotationType

    /// Bounding rectangle in PDF coordinates.
    public let bounds: EInkAnnotationBounds

    /// Color of the annotation (if applicable).
    public let color: EInkAnnotationColor?

    /// Raw stroke data for ink annotations.
    public let strokeData: Data?

    /// OCR text for handwritten annotations.
    public let ocrText: String?

    /// When the annotation was created on the device.
    public let dateCreated: Date

    /// Additional device-specific metadata.
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        sourceDevice: EInkDeviceType,
        pageNumber: Int,
        annotationType: EInkAnnotationType,
        bounds: EInkAnnotationBounds,
        color: EInkAnnotationColor? = nil,
        strokeData: Data? = nil,
        ocrText: String? = nil,
        dateCreated: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceDevice = sourceDevice
        self.pageNumber = pageNumber
        self.annotationType = annotationType
        self.bounds = bounds
        self.color = color
        self.strokeData = strokeData
        self.ocrText = ocrText
        self.dateCreated = dateCreated
        self.metadata = metadata
    }
}

// MARK: - Annotation Collection

/// A collection of annotations for a document.
public struct EInkAnnotationCollection: Codable, Sendable {
    /// Document identifier on the source device.
    public let documentID: String

    /// Source device type.
    public let sourceDevice: EInkDeviceType

    /// All annotations in this collection.
    public let annotations: [EInkAnnotation]

    /// When the annotations were last synced.
    public let syncDate: Date

    public init(
        documentID: String,
        sourceDevice: EInkDeviceType,
        annotations: [EInkAnnotation],
        syncDate: Date = Date()
    ) {
        self.documentID = documentID
        self.sourceDevice = sourceDevice
        self.annotations = annotations
        self.syncDate = syncDate
    }

    /// Annotations grouped by page number.
    public var annotationsByPage: [Int: [EInkAnnotation]] {
        Dictionary(grouping: annotations, by: \.pageNumber)
    }

    /// Total number of annotations.
    public var count: Int { annotations.count }

    /// Number of highlights.
    public var highlightCount: Int {
        annotations.filter { $0.annotationType == .highlight }.count
    }

    /// Number of ink annotations.
    public var inkCount: Int {
        annotations.filter { $0.annotationType == .ink }.count
    }

    /// Number of text annotations.
    public var textCount: Int {
        annotations.filter { $0.annotationType == .text }.count
    }

    /// Page numbers that have annotations.
    public var annotatedPages: [Int] {
        Array(Set(annotations.map(\.pageNumber))).sorted()
    }
}
