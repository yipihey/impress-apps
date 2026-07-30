//
//  ArtifactMetadataExtractor.swift
//  PublicationManagerCore
//
//  Extracts metadata from files and URLs for artifact capture.
//

import Foundation
import UniformTypeIdentifiers
import OSLog
import CoreGraphics
import ImageIO
import ImbibRustCore

/// Extracted metadata from a file or URL, ready for artifact creation.
nonisolated public struct ArtifactMetadata: Sendable {
    public var title: String?
    public var sourceURL: String?
    public var notes: String?
    public var artifactType: ArtifactType
    public var fileName: String?
    public var fileSize: Int64?
    public var fileMimeType: String?
    public var originalAuthor: String?
    public var eventName: String?
}

/// Extracts metadata from files and URLs for research artifact capture.
nonisolated public enum ArtifactMetadataExtractor {

    /// Extract metadata from a local file URL.
    public static func extractFromFile(url: URL) -> ArtifactMetadata {
        let fileName = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        let artifactType = inferArtifactType(from: url)

        var metadata = ArtifactMetadata(
            title: url.deletingPathExtension().lastPathComponent,
            artifactType: artifactType,
            fileName: fileName,
            fileSize: fileSize,
            fileMimeType: mimeType
        )

        // Try to extract title from PDF properties
        if artifactType == .presentation || url.pathExtension.lowercased() == "pdf" {
            if let pdfTitle = extractPDFTitle(from: url) {
                metadata.title = pdfTitle
            }
        }

        return metadata
    }

    /// Extract metadata from a web URL by fetching page title and OpenGraph tags.
    public static func extractFromURL(url: URL) async -> ArtifactMetadata {
        var metadata = ArtifactMetadata(
            title: url.host ?? url.absoluteString,
            sourceURL: url.absoluteString,
            artifactType: .webpage
        )

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               let mimeType = httpResponse.mimeType {
                metadata.fileMimeType = mimeType
            }

            if let html = String(data: data, encoding: .utf8) {
                // Extract <title>
                if let titleRange = html.range(of: "<title>"),
                   let endRange = html.range(of: "</title>", range: titleRange.upperBound..<html.endIndex) {
                    let title = String(html[titleRange.upperBound..<endRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        metadata.title = title
                    }
                }

                // Extract og:title (overrides <title>)
                if let ogTitle = extractMetaContent(from: html, property: "og:title") {
                    metadata.title = ogTitle
                }

                // Extract og:description as notes
                if let ogDesc = extractMetaContent(from: html, property: "og:description") {
                    metadata.notes = ogDesc
                }

                // Extract author
                if let author = extractMetaContent(from: html, name: "author") {
                    metadata.originalAuthor = author
                }
            }
        } catch {
            Logger.library.infoCapture("URL metadata fetch failed: \(error.localizedDescription)", category: "artifacts")
        }

        return metadata
    }

    /// Infer the artifact type from a file URL.
    ///
    /// Two halves, deliberately split (Stage 7 item 9): the filename hints
    /// (`slide`/`talk`/`presentation`/`lecture`/`poster`/`readme`/`codebook`/
    /// `dataset`) and the extension table are pure logic and live in
    /// `imbib-core`'s `pdf::infer_artifact_type_from_filename`, pinned by 43
    /// golden cases. The `UTType.conforms(to:)` fallback below is PLATFORM — it
    /// is what classifies a `.pdf`, a `.png` or an unknown extension — and stays
    /// here. Rust returns nil for exactly the inputs only `UTType` can decide,
    /// and its own test asserts it never answers `.general`, because `.general`
    /// is the *last* line of the platform block: collapsing "undecided" into it
    /// would type every dropped figure as generic while still passing the corpus.
    public static func inferArtifactType(from url: URL) -> ArtifactType {
        if let raw = ImbibRustCore.artifactTypeFromFilename(path: url.lastPathComponent),
           let decided = ArtifactType(rawValue: raw) {
            return decided
        }

        let ext = url.pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .image) || utType.conforms(to: .movie)
                || utType.conforms(to: .audio) {
                return .media
            }
            if utType.conforms(to: .sourceCode) {
                return .code
            }
            if utType.conforms(to: .plainText) {
                return .note
            }
            if utType.conforms(to: .presentation) {
                return .presentation
            }
            if utType.conforms(to: .spreadsheet) {
                return .dataset
            }
        }

        return .general
    }

    // MARK: - OCR Extraction

    /// Extract text from an image file using Vision OCR.
    /// Returns nil if the file is not an image or OCR fails.
    public static func extractOCRText(from imageURL: URL) async -> String? {
        let ext = imageURL.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)

        // Only process image files
        guard let utType, utType.conforms(to: .image) else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            Logger.library.infoCapture("OCR: Could not load image from \(imageURL.lastPathComponent)", category: "artifacts")
            return nil
        }

        do {
            let result = try await RemarkableOCRService.shared.recognizeText(from: cgImage)
            if result.text.isEmpty {
                Logger.library.infoCapture("OCR: No text found in \(imageURL.lastPathComponent)", category: "artifacts")
                return nil
            }
            Logger.library.infoCapture(
                "OCR: Extracted \(result.text.count) chars (confidence: \(String(format: "%.2f", result.confidence))) from \(imageURL.lastPathComponent)",
                category: "artifacts"
            )
            return result.text
        } catch {
            Logger.library.infoCapture("OCR failed for \(imageURL.lastPathComponent): \(error.localizedDescription)", category: "artifacts")
            return nil
        }
    }

    // MARK: - Private Helpers

    private static func extractPDFTitle(from url: URL) -> String? {
        guard let doc = CGPDFDocument(url as CFURL),
              let info = doc.info else { return nil }

        var titleRef: CGPDFStringRef?
        if CGPDFDictionaryGetString(info, "Title", &titleRef),
           let titleRef,
           let cfString = CGPDFStringCopyTextString(titleRef) {
            let title = cfString as String
            if !title.isEmpty && title != "Untitled" {
                return title
            }
        }
        return nil
    }

    // MARK: - HTML metadata (Rust)

    // Stage 7 item 9: the two `<meta>` scrapers moved to `imbib-core`'s
    // `pdf::artifact_meta`, pinned by 48 golden assertions over 16 HTML cases.
    // Two behaviours are preserved there with the reasoning spelled out:
    // `content=""` yields nil but `content="   "` yields `Some("")` — two
    // answers for two spellings of "no title", and the caller assigns on any
    // non-nil, so this decides `<title>` vs `og:title` for real pages — and the
    // `name:` form has no reversed-attribute-order pattern, so
    // `<meta content="…" name="author">` is not found.

    static func extractMetaContent(from html: String, property: String) -> String? {
        ImbibRustCore.htmlMetaProperty(html: html, property: property)
    }

    static func extractMetaContent(from html: String, name: String) -> String? {
        ImbibRustCore.htmlMetaName(html: html, name: name)
    }
}
