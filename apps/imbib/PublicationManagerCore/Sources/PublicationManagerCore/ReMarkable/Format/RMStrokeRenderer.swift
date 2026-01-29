//
//  RMStrokeRenderer.swift
//  PublicationManagerCore
//
//  Renders reMarkable strokes to images using Core Graphics.
//  ADR-019: reMarkable Tablet Integration
//

import Foundation
import CoreGraphics
import OSLog

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.imbib.app", category: "rmRenderer")

// MARK: - Stroke Renderer

/// Renders reMarkable strokes to CGImage or PNG data.
public struct RMStrokeRenderer {

    // MARK: - Rendering Options

    /// Options for controlling stroke rendering.
    public struct RenderOptions: Sendable {
        /// Scale factor (1.0 = native resolution, 2.0 = 2x).
        public var scale: CGFloat = 2.0

        /// Background color (nil for transparent).
        public var backgroundColor: CGColor?

        /// Whether to render highlighter strokes with transparency.
        public var useHighlighterBlending: Bool = true

        /// Minimum stroke width to prevent hairline strokes.
        public var minimumStrokeWidth: CGFloat = 0.5

        public init(
            scale: CGFloat = 2.0,
            backgroundColor: CGColor? = nil,
            useHighlighterBlending: Bool = true,
            minimumStrokeWidth: CGFloat = 0.5
        ) {
            self.scale = scale
            self.backgroundColor = backgroundColor
            self.useHighlighterBlending = useHighlighterBlending
            self.minimumStrokeWidth = minimumStrokeWidth
        }

        /// Default options for preview rendering.
        public static let preview = RenderOptions(scale: 1.0)

        /// Options for high-quality export.
        public static let export = RenderOptions(scale: 3.0)
    }

    // MARK: - Public API

    /// Render an .rm file to a CGImage.
    ///
    /// - Parameters:
    ///   - rmFile: The parsed .rm file
    ///   - options: Rendering options
    /// - Returns: Rendered CGImage, or nil if rendering fails
    public static func render(_ rmFile: RMFile, options: RenderOptions = RenderOptions()) -> CGImage? {
        let width = Int(RMPageDimensions.width * options.scale)
        let height = Int(RMPageDimensions.height * options.scale)

        guard let context = createContext(width: width, height: height, backgroundColor: options.backgroundColor) else {
            logger.error("Failed to create graphics context")
            return nil
        }

        // Apply scale transform
        context.scaleBy(x: options.scale, y: options.scale)

        // Render each layer
        for layer in rmFile.layers {
            renderLayer(layer, in: context, options: options)
        }

        return context.makeImage()
    }

    /// Render an .rm file to PNG data.
    ///
    /// - Parameters:
    ///   - rmFile: The parsed .rm file
    ///   - options: Rendering options
    /// - Returns: PNG data, or nil if rendering fails
    public static func renderToPNG(_ rmFile: RMFile, options: RenderOptions = RenderOptions()) -> Data? {
        guard let image = render(rmFile, options: options) else {
            return nil
        }

        return imageToPNG(image)
    }

    /// Render a single stroke to a CGImage.
    ///
    /// - Parameters:
    ///   - stroke: The stroke to render
    ///   - options: Rendering options
    /// - Returns: Rendered CGImage sized to the stroke's bounds
    public static func render(stroke: RMStroke, options: RenderOptions = RenderOptions()) -> CGImage? {
        let bounds = stroke.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return nil }

        // Add padding for stroke width
        let padding = CGFloat(stroke.width) * 2
        let width = Int((bounds.width + padding * 2) * options.scale)
        let height = Int((bounds.height + padding * 2) * options.scale)

        guard let context = createContext(width: width, height: height, backgroundColor: options.backgroundColor) else {
            return nil
        }

        // Transform to center stroke
        context.scaleBy(x: options.scale, y: options.scale)
        context.translateBy(x: -bounds.origin.x + padding, y: -bounds.origin.y + padding)

        // Render the stroke
        renderStroke(stroke, in: context, options: options)

        return context.makeImage()
    }

    // MARK: - Private Rendering

    private static func createContext(width: Int, height: Int, backgroundColor: CGColor?) -> CGContext? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Fill background if specified
        if let bgColor = backgroundColor {
            context.setFillColor(bgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        return context
    }

    private static func renderLayer(_ layer: RMLayer, in context: CGContext, options: RenderOptions) {
        for stroke in layer.strokes {
            // Skip eraser strokes (they modify other strokes, not draw)
            if stroke.isEraser { continue }

            renderStroke(stroke, in: context, options: options)
        }
    }

    private static func renderStroke(_ stroke: RMStroke, in context: CGContext, options: RenderOptions) {
        guard stroke.points.count >= 2 else { return }

        // Set stroke color
        context.setStrokeColor(stroke.color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Configure blending for highlighter
        if stroke.pen == .highlighter && options.useHighlighterBlending {
            context.setBlendMode(.multiply)
            context.setAlpha(0.4)
        } else {
            context.setBlendMode(.normal)
            context.setAlpha(1.0)
        }

        // Draw stroke segments with pressure-sensitive width
        for i in 1..<stroke.points.count {
            let p0 = stroke.points[i - 1]
            let p1 = stroke.points[i]

            // Calculate width based on pen type and pressure
            let baseWidth = baseWidth(for: stroke.pen)
            let width = max(options.minimumStrokeWidth, baseWidth * CGFloat(stroke.width) * CGFloat(p1.pressure))

            context.setLineWidth(width)
            context.move(to: p0.cgPoint)
            context.addLine(to: p1.cgPoint)
            context.strokePath()
        }

        // Reset blend mode
        context.setBlendMode(.normal)
        context.setAlpha(1.0)
    }

    private static func baseWidth(for pen: RMStroke.PenType) -> CGFloat {
        switch pen {
        case .ballpoint: return 1.5
        case .marker: return 3.5
        case .fineliner: return 1.0
        case .highlighter: return 18.0
        case .eraser: return 12.0
        case .pencilSharp: return 1.2
        case .eraserArea: return 20.0
        case .brush: return 5.0
        case .pencilTilt: return 2.0
        case .calligraphy: return 3.0
        }
    }

    // MARK: - Image Conversion

    private static func imageToPNG(_ image: CGImage) -> Data? {
        #if canImport(AppKit)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
        #elseif canImport(UIKit)
        return UIImage(cgImage: image).pngData()
        #else
        // Fallback: Create PNG using ImageIO
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
        #endif
    }
}

// MARK: - Convenience Extensions

public extension RMFile {
    /// Render this file to PNG data.
    func renderToPNG(scale: CGFloat = 2.0) -> Data? {
        let options = RMStrokeRenderer.RenderOptions(scale: scale)
        return RMStrokeRenderer.renderToPNG(self, options: options)
    }

    /// Render this file to a CGImage.
    func render(scale: CGFloat = 2.0) -> CGImage? {
        let options = RMStrokeRenderer.RenderOptions(scale: scale)
        return RMStrokeRenderer.render(self, options: options)
    }
}
