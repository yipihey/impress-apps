//
//  ThumbnailService.swift
//  PublicationManagerCore
//
//  PDF thumbnail service using Rust/pdfium for generation.
//  Provides disk caching and async API.
//

import Foundation
import OSLog
import CoreGraphics

#if canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

// MARK: - Thumbnail Service

/// Actor that manages PDF thumbnail generation and caching.
///
/// Uses the Rust pdfium implementation for consistent cross-platform rendering.
/// Thumbnails are cached on disk for fast retrieval.
public actor ThumbnailService {

    // MARK: - Singleton

    public static let shared = ThumbnailService()

    // MARK: - Configuration

    /// Default thumbnail width
    public static let defaultWidth: UInt32 = 200

    /// Default thumbnail height
    public static let defaultHeight: UInt32 = 280

    // MARK: - Properties

    private var cacheDirectory: URL?
    private var memoryCache: [String: PlatformImage] = [:]
    private let maxMemoryCacheSize = 50

    // MARK: - Initialization

    private init() {
        // Cache directory setup is lazy - happens on first access
    }

    /// Helper to call @MainActor RustStoreAdapter from actor context.
    private func withStore<T: Sendable>(_ operation: @MainActor @Sendable (RustStoreAdapter) -> T) async -> T {
        await MainActor.run { operation(RustStoreAdapter.shared) }
    }

    // MARK: - Public API

    /// Check if the thumbnail service is available.
    public var isAvailable: Bool {
        RustPDFService.isAvailable
    }

    /// Ensure the cache directory is set up.
    private func ensureCacheDirectory() {
        if cacheDirectory == nil {
            setupCacheDirectory()
        }
    }

    /// Get a thumbnail for a linked PDF file.
    ///
    /// Checks cache first, generates if needed.
    ///
    /// - Parameters:
    ///   - linkedFile: The linked file model
    ///   - libraryId: The library ID containing the file
    /// - Returns: Thumbnail image, or nil if generation fails
    public func thumbnail(
        for linkedFile: LinkedFileModel,
        in libraryId: UUID?
    ) async -> PlatformImage? {
        guard linkedFile.isPDF else {
            return nil
        }

        let cacheKey = linkedFile.id.uuidString

        // Check memory cache
        if let cached = memoryCache[cacheKey] {
            return cached
        }

        // Check disk cache
        if let cached = loadFromDiskCache(key: cacheKey) {
            memoryCache[cacheKey] = cached
            return cached
        }

        // Generate thumbnail
        guard let url = await MainActor.run(body: {
            AttachmentManager.shared.resolveURL(for: linkedFile, in: libraryId)
        }) else {
            Logger.files.warning("Could not resolve URL for linked file: \(linkedFile.id)")
            return nil
        }

        return await generateThumbnail(from: url, cacheKey: cacheKey)
    }

    /// Get a thumbnail for a publication's primary PDF.
    ///
    /// - Parameters:
    ///   - publicationId: The publication ID
    ///   - libraryId: The library ID containing the publication
    /// - Returns: Thumbnail image, or nil if no PDF or generation fails
    public func thumbnail(
        for publicationId: UUID,
        in libraryId: UUID?
    ) async -> PlatformImage? {
        let linkedFiles = await withStore { $0.listLinkedFiles(publicationId: publicationId) }

        guard let primaryPDF = linkedFiles.first(where: { $0.isPDF }) else {
            return nil
        }

        return await thumbnail(for: primaryPDF, in: libraryId)
    }

    /// Generate and cache a thumbnail from PDF data.
    ///
    /// Call this during PDF import to pre-generate thumbnails.
    @discardableResult
    public func generateThumbnail(
        from pdfData: Data,
        linkedFileId: UUID
    ) async -> PlatformImage? {
        let cacheKey = linkedFileId.uuidString

        // Check if already cached
        if let cached = memoryCache[cacheKey] {
            return cached
        }
        if let cached = loadFromDiskCache(key: cacheKey) {
            memoryCache[cacheKey] = cached
            return cached
        }

        // Generate
        do {
            let result = try RustPDFService.generateThumbnail(
                from: pdfData,
                width: Self.defaultWidth,
                height: Self.defaultHeight
            )

            guard let image = createImage(from: result) else {
                Logger.files.error("Failed to create image from thumbnail data")
                return nil
            }

            // Cache
            addToMemoryCache(key: cacheKey, image: image)
            saveToDiskCache(key: cacheKey, image: image)

            return image
        } catch {
            Logger.files.error("Failed to generate thumbnail: \(error.localizedDescription)")
            return nil
        }
    }

    /// Clear all cached thumbnails.
    public func clearCache() {
        memoryCache.removeAll()

        if let cacheDir = cacheDirectory {
            try? FileManager.default.removeItem(at: cacheDir)
            setupCacheDirectory()
        }

        Logger.files.info("Thumbnail cache cleared")
    }

    /// Remove cached thumbnail for a specific linked file.
    public func removeCached(linkedFileId: UUID) {
        let cacheKey = linkedFileId.uuidString
        memoryCache.removeValue(forKey: cacheKey)

        if let cacheDir = cacheDirectory {
            let fileURL = cacheDir.appendingPathComponent("\(cacheKey).png")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Private Methods

    private func setupCacheDirectory() {
        guard let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let thumbnailDir = cacheBase.appendingPathComponent("imbib/thumbnails", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: thumbnailDir, withIntermediateDirectories: true)
            cacheDirectory = thumbnailDir
        } catch {
            Logger.files.error("Failed to create thumbnail cache directory: \(error.localizedDescription)")
        }
    }

    private func generateThumbnail(from url: URL, cacheKey: String) async -> PlatformImage? {
        do {
            let result = try RustPDFService.generateThumbnail(
                from: url,
                width: Self.defaultWidth,
                height: Self.defaultHeight
            )

            guard let image = createImage(from: result) else {
                Logger.files.error("Failed to create image from thumbnail data")
                return nil
            }

            // Cache
            addToMemoryCache(key: cacheKey, image: image)
            saveToDiskCache(key: cacheKey, image: image)

            Logger.files.debug("Generated thumbnail for: \(url.lastPathComponent)")
            return image
        } catch {
            Logger.files.error("Failed to generate thumbnail for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func createImage(from result: PDFThumbnailResult) -> PlatformImage? {
        let width = Int(result.width)
        let height = Int(result.height)

        guard width > 0, height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let expectedSize = height * bytesPerRow

        guard result.rgbaBytes.count >= expectedSize else {
            Logger.files.error("RGBA data size mismatch: \(result.rgbaBytes.count) < \(expectedSize)")
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: result.rgbaBytes as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #endif
    }

    private func addToMemoryCache(key: String, image: PlatformImage) {
        if memoryCache.count >= maxMemoryCacheSize {
            if let firstKey = memoryCache.keys.first {
                memoryCache.removeValue(forKey: firstKey)
            }
        }
        memoryCache[key] = image
    }

    private func loadFromDiskCache(key: String) -> PlatformImage? {
        ensureCacheDirectory()
        guard let cacheDir = cacheDirectory else { return nil }

        let fileURL = cacheDir.appendingPathComponent("\(key).png")

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        #if canImport(AppKit)
        return NSImage(contentsOf: fileURL)
        #elseif canImport(UIKit)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
        #endif
    }

    private func saveToDiskCache(key: String, image: PlatformImage) {
        ensureCacheDirectory()
        guard let cacheDir = cacheDirectory else { return }

        let fileURL = cacheDir.appendingPathComponent("\(key).png")

        #if canImport(AppKit)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? pngData.write(to: fileURL)
        #elseif canImport(UIKit)
        guard let pngData = image.pngData() else { return }
        try? pngData.write(to: fileURL)
        #endif
    }
}
