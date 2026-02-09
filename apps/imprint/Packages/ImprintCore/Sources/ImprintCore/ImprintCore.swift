import Foundation
import ImprintRustCore

/// ImprintCore provides Swift bindings to the imprint-core Rust library
///
/// This module wraps the UniFFI-generated bindings and provides a Swift-native
/// API for:
/// - Document creation and editing
/// - CRDT-based collaboration
/// - Typst rendering
/// - LaTeX export
/// - Bibliography management
///
/// # Usage
///
/// ```swift
/// import ImprintCore
///
/// // Create a new document
/// let doc = ImprintDocument()
/// doc.insertText(0, "Hello, academic world!")
///
/// // Render to PDF
/// let renderer = TypstRenderer()
/// let pdf = try await renderer.render(doc.source)
/// ```
///
/// # Architecture
///
/// The Rust core (imprint-core) provides:
/// - `ImprintDocument`: CRDT-based document using Automerge
/// - `Transaction`: Atomic editing operations
/// - `SelectionSet`: Multi-cursor support
/// - `SourceMap`: Source ↔ PDF position mapping
/// - `LatexConverter`: Bidirectional LaTeX ↔ Typst conversion
/// - `Bibliography`: Citation tracking
///
/// # Building
///
/// The Rust library must be compiled to an XCFramework:
///
/// ```bash
/// cd ../../.. # impress-apps root
/// ./build-rust.sh
/// ```
///
/// This generates `ImprintCoreFFI.xcframework` which is linked by this package.

// MARK: - Placeholder Types

// These types mirror the Rust API and will be replaced by UniFFI-generated code

/// Document error types
public enum ImprintError: Error {
    case documentError(String)
    case renderError(String)
    case exportError(String)
    case syncError(String)
}

/// Document metadata
public struct DocumentMetadata {
    public var title: String
    public var authors: [String]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(title: String = "", authors: [String] = [], createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.title = title
        self.authors = authors
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Edit modes for the document editor
public enum DocumentEditMode: String, CaseIterable {
    case directPdf = "direct_pdf"
    case splitView = "split_view"
    case textOnly = "text_only"

    public mutating func cycle() {
        switch self {
        case .directPdf: self = .splitView
        case .splitView: self = .textOnly
        case .textOnly: self = .directPdf
        }
    }
}

/// A selection in the document
public struct Selection {
    public var anchor: Int
    public var head: Int

    public init(anchor: Int, head: Int) {
        self.anchor = anchor
        self.head = head
    }

    public static func cursor(_ pos: Int) -> Selection {
        Selection(anchor: pos, head: pos)
    }

    public var start: Int { min(anchor, head) }
    public var end: Int { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
}

/// Set of selections (multi-cursor support)
public struct SelectionSet {
    public var selections: [Selection]
    public var primaryIndex: Int

    public init(primary: Selection) {
        self.selections = [primary]
        self.primaryIndex = 0
    }

    public var primary: Selection {
        selections[primaryIndex]
    }
}

/// Position in rendered PDF
public struct RenderPosition {
    public var page: Int
    public var x: Double
    public var y: Double

    public init(page: Int = 0, x: Double = 0, y: Double = 0) {
        self.page = page
        self.x = x
        self.y = y
    }
}

/// Source span in the document
public struct SourceSpan {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

// MARK: - Document API

/// Core document type (placeholder until UniFFI bindings are generated)
///
/// This will be replaced by the UniFFI-generated `ImprintDocument` type.
public class ImprintCoreDocument {
    private var _source: String = ""
    private var _metadata: DocumentMetadata
    private var _selections: SelectionSet
    private var _editMode: DocumentEditMode = .splitView

    public init() {
        _metadata = DocumentMetadata()
        _selections = SelectionSet(primary: .cursor(0))
    }

    public var source: String {
        get { _source }
        set { _source = newValue }
    }

    public var metadata: DocumentMetadata {
        get { _metadata }
        set { _metadata = newValue }
    }

    public var selections: SelectionSet {
        get { _selections }
        set { _selections = newValue }
    }

    public var editMode: DocumentEditMode {
        get { _editMode }
        set { _editMode = newValue }
    }

    public func insertText(_ text: String, at position: Int) {
        guard position >= 0 && position <= _source.count else { return }
        let index = _source.index(_source.startIndex, offsetBy: position)
        _source.insert(contentsOf: text, at: index)
    }

    public func deleteText(from: Int, to: Int) {
        guard from >= 0 && to <= _source.count && from < to else { return }
        let startIndex = _source.index(_source.startIndex, offsetBy: from)
        let endIndex = _source.index(_source.startIndex, offsetBy: to)
        _source.removeSubrange(startIndex..<endIndex)
    }

    public func toBytes() -> Data {
        // Placeholder: just return source as UTF-8
        return _source.data(using: .utf8) ?? Data()
    }

    public static func fromBytes(_ data: Data) throws -> ImprintCoreDocument {
        let doc = ImprintCoreDocument()
        if let source = String(data: data, encoding: .utf8) {
            doc._source = source
        }
        return doc
    }
}

// MARK: - Rendering API

/// Typst renderer options
public struct RenderOptions {
    public var pageSize: PageSize
    public var isDraft: Bool

    public init(pageSize: PageSize = .a4, isDraft: Bool = false) {
        self.pageSize = pageSize
        self.isDraft = isDraft
    }

    public enum PageSize: String, CaseIterable {
        case a4 = "a4"
        case letter = "us-letter"
        case a5 = "a5"
    }
}

/// Render output with PDF data and diagnostics
public struct RenderOutput {
    public var pdfData: Data
    public var pageCount: Int
    public var warnings: [String]
    public var errors: [String]
    public var sourceMapEntries: [SourceMapEntry]

    public var isSuccess: Bool { errors.isEmpty }
}

/// SVG render output — one SVG string per page
public struct SVGRenderOutput {
    public var svgPages: [String]
    public var pageCount: Int
    public var warnings: [String]
    public var errors: [String]
    public var sourceMapEntries: [SourceMapEntry]

    public var isSuccess: Bool { errors.isEmpty }
}

// MARK: - Source Map Types (ADR-004)

/// A source map entry linking source positions to rendered positions
public struct SourceMapEntry {
    /// Start byte offset in source
    public var sourceStart: Int
    /// End byte offset in source
    public var sourceEnd: Int
    /// Page number (0-indexed)
    public var page: Int
    /// Bounding box x coordinate
    public var x: Double
    /// Bounding box y coordinate
    public var y: Double
    /// Bounding box width
    public var width: Double
    /// Bounding box height
    public var height: Double
    /// Content type
    public var contentType: SourceMapContentType

    public init(sourceStart: Int, sourceEnd: Int, page: Int, x: Double, y: Double, width: Double, height: Double, contentType: SourceMapContentType) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.contentType = contentType
    }
}

/// Content type for source map entries
public enum SourceMapContentType: String {
    case text
    case heading
    case math
    case code
    case figure
    case table
    case citation
    case listItem
    case other
}

/// Result of looking up a click position in the source map
public struct SourceMapLookupResult {
    /// Source offset for the cursor
    public var sourceOffset: Int
    /// Whether a match was found
    public var found: Bool
    /// Content type at this position
    public var contentType: SourceMapContentType

    public init(sourceOffset: Int, found: Bool, contentType: SourceMapContentType) {
        self.sourceOffset = sourceOffset
        self.found = found
        self.contentType = contentType
    }
}

/// Source map utilities for click-to-edit functionality
///
/// These functions provide bidirectional mapping between source positions and
/// rendered PDF positions. They use a pure Swift implementation for simplicity
/// and to avoid FFI complexity for what is essentially coordinate matching.
public struct SourceMapUtils {
    /// Look up a click position in the source map to find the corresponding source location
    ///
    /// - Parameters:
    ///   - entries: Array of source map entries from compilation
    ///   - page: PDF page number (0-indexed)
    ///   - x: X coordinate in PDF points from left edge
    ///   - y: Y coordinate in PDF points from top edge
    /// - Returns: A SourceMapLookupResult with the source offset and whether a match was found
    public static func lookup(entries: [SourceMapEntry], page: Int, x: Double, y: Double) -> SourceMapLookupResult {
        // Find the entry whose bounding box contains the click position
        var bestMatch: SourceMapEntry? = nil
        var bestArea = Double.infinity

        for entry in entries {
            guard entry.page == page else { continue }

            // Check if point is inside bounding box
            if x >= entry.x && x <= entry.x + entry.width &&
               y >= entry.y && y <= entry.y + entry.height {
                let area = entry.width * entry.height
                // Prefer smaller (more specific) regions
                if area < bestArea {
                    bestArea = area
                    bestMatch = entry
                }
            }
        }

        if let entry = bestMatch {
            // Calculate position within the span based on x position
            let xRatio = (x - entry.x) / entry.width
            let spanLength = entry.sourceEnd - entry.sourceStart
            let offsetWithin = Int(Double(spanLength) * xRatio)

            return SourceMapLookupResult(
                sourceOffset: entry.sourceStart + offsetWithin,
                found: true,
                contentType: entry.contentType
            )
        } else {
            // No exact match - find nearest entry on the page
            var nearest: SourceMapEntry? = nil
            var minDistance = Double.infinity

            for entry in entries {
                guard entry.page == page else { continue }

                let centerX = entry.x + entry.width / 2.0
                let centerY = entry.y + entry.height / 2.0
                let distance = sqrt(pow(x - centerX, 2) + pow(y - centerY, 2))

                if distance < minDistance {
                    minDistance = distance
                    nearest = entry
                }
            }

            if let entry = nearest {
                // Place cursor at start or end based on position relative to center
                let centerX = entry.x + entry.width / 2.0
                let offset = x < centerX ? entry.sourceStart : entry.sourceEnd

                return SourceMapLookupResult(
                    sourceOffset: offset,
                    found: true,
                    contentType: entry.contentType
                )
            } else {
                return SourceMapLookupResult(
                    sourceOffset: 0,
                    found: false,
                    contentType: .other
                )
            }
        }
    }

    /// Look up a source position to find the corresponding render location
    ///
    /// This is the reverse of `lookup` - given a cursor position in the source,
    /// find where it appears in the rendered PDF. Used for cursor synchronization.
    ///
    /// - Parameters:
    ///   - entries: Array of source map entries from compilation
    ///   - sourceOffset: Byte offset in the source text
    /// - Returns: A RenderRegion if a match was found, nil otherwise
    public static func sourceToRender(entries: [SourceMapEntry], sourceOffset: Int) -> RenderRegion? {
        // Find entries that contain the source offset
        var bestMatch: SourceMapEntry? = nil
        var bestSpanLength = Int.max

        for entry in entries {
            // Check if the source offset is within this entry
            if sourceOffset >= entry.sourceStart && sourceOffset < entry.sourceEnd {
                let spanLength = entry.sourceEnd - entry.sourceStart
                // Prefer smaller (more specific) spans
                if spanLength < bestSpanLength {
                    bestSpanLength = spanLength
                    bestMatch = entry
                }
            }
        }

        // If no exact match, find the nearest entry
        if bestMatch == nil {
            var minDistance = Int.max

            for entry in entries {
                // Calculate distance to the nearest edge of this span
                let distance: Int
                if sourceOffset < entry.sourceStart {
                    distance = entry.sourceStart - sourceOffset
                } else if sourceOffset >= entry.sourceEnd {
                    distance = sourceOffset - entry.sourceEnd + 1
                } else {
                    distance = 0
                }

                if distance < minDistance {
                    minDistance = distance
                    bestMatch = entry
                }
            }
        }

        guard let entry = bestMatch else {
            return nil
        }

        return RenderRegion(
            page: entry.page,
            x: entry.x,
            y: entry.y,
            width: entry.width,
            height: entry.height
        )
    }
}

/// Render region in the PDF (result of source-to-render lookup)
public struct RenderRegion {
    public var page: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(page: Int, x: Double, y: Double, width: Double, height: Double) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: (x: Double, y: Double) {
        (x + width / 2.0, y + height / 2.0)
    }
}

/// Typst renderer using Rust backend when available
public actor TypstRenderer {
    public init() {}

    /// Check if native Typst rendering is available
    public static var isNativeAvailable: Bool {
        return ImprintRustCore.isTypstAvailable()
    }

    /// Get the Typst version string
    public static var typstVersion: String {
        return ImprintRustCore.getTypstVersion()
    }

    public func render(_ source: String, options: RenderOptions = RenderOptions()) async throws -> RenderOutput {
        // Use real Typst renderer via Rust FFI
        log("[ImprintCore] Using Rust Typst renderer")
        return try await renderWithRust(source, options: options)
    }

    /// Render Typst source to SVG (one SVG string per page)
    ///
    /// Uses the persistent Rust renderer for incremental compilation.
    /// Returns per-page SVG strings for faster preview updates on long documents.
    public func renderSVG(_ source: String, options: RenderOptions = RenderOptions()) async throws -> SVGRenderOutput {
        log("[ImprintCore] renderSVG called with source length: \(source.count)")

        let ffiPageSize: ImprintRustCore.FfiPageSize
        switch options.pageSize {
        case .a4: ffiPageSize = .a4
        case .letter: ffiPageSize = .letter
        case .a5: ffiPageSize = .a5
        }

        let compileOptions = ImprintRustCore.CompileOptions(
            pageSize: ffiPageSize,
            fontSize: 11.0,
            marginTop: 72.0,
            marginRight: 72.0,
            marginBottom: 72.0,
            marginLeft: 72.0
        )

        let result = await Task.detached(priority: .userInitiated) {
            return ImprintRustCore.compileTypstToSvg(source: source, options: compileOptions)
        }.value

        log("[ImprintCore] SVG compilation complete. Error: \(result.error ?? "none"), Pages: \(result.svgPages.count)")

        let sourceMapEntries = Self.generateSourceMapEntries(source: source, options: options)

        if let error = result.error {
            log("[ImprintCore] SVG compilation error: \(error)")
            return SVGRenderOutput(
                svgPages: [],
                pageCount: 0,
                warnings: result.warnings,
                errors: [error],
                sourceMapEntries: []
            )
        }

        log("[ImprintCore] SVG generated successfully, \(result.svgPages.count) pages")
        return SVGRenderOutput(
            svgPages: result.svgPages,
            pageCount: Int(result.pageCount),
            warnings: result.warnings,
            errors: [],
            sourceMapEntries: sourceMapEntries
        )
    }

    private func log(_ message: String) {
        let logMessage = "[\(Date())] \(message)\n"
        print(logMessage)
        // Also write to file for debugging UI tests
        let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("imprint_debug.log")
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private func renderWithRust(_ source: String, options: RenderOptions) async throws -> RenderOutput {
        log("[ImprintCore] renderWithRust called with source length: \(source.count)")

        // Convert options to FFI types
        let ffiPageSize: ImprintRustCore.FfiPageSize
        switch options.pageSize {
        case .a4: ffiPageSize = .a4
        case .letter: ffiPageSize = .letter
        case .a5: ffiPageSize = .a5
        }

        let compileOptions = ImprintRustCore.CompileOptions(
            pageSize: ffiPageSize,
            fontSize: 11.0,
            marginTop: 72.0,
            marginRight: 72.0,
            marginBottom: 72.0,
            marginLeft: 72.0
        )

        log("[ImprintCore] Calling Rust compileTypstToPdf on background thread...")

        // Run the blocking Rust call on a background thread
        let result = await Task.detached(priority: .userInitiated) {
            return ImprintRustCore.compileTypstToPdf(source: source, options: compileOptions)
        }.value

        log("[ImprintCore] Rust compilation complete. Error: \(result.error ?? "none"), PDF size: \(result.pdfData?.count ?? 0)")

        // Generate source map entries locally (until FFI exports them)
        let sourceMapEntries = Self.generateSourceMapEntries(source: source, options: options)
        log("[ImprintCore] Source map entries: \(sourceMapEntries.count)")

        if let error = result.error {
            log("[ImprintCore] Compilation error: \(error)")
            return RenderOutput(
                pdfData: Data(),
                pageCount: 0,
                warnings: result.warnings,
                errors: [error],
                sourceMapEntries: []
            )
        }

        guard let pdfData = result.pdfData else {
            log("[ImprintCore] No PDF data returned")
            return RenderOutput(
                pdfData: Data(),
                pageCount: 0,
                warnings: result.warnings,
                errors: ["No PDF data returned"],
                sourceMapEntries: []
            )
        }

        log("[ImprintCore] PDF generated successfully, \(pdfData.count) bytes, \(sourceMapEntries.count) source map entries")
        return RenderOutput(
            pdfData: pdfData,  // Already Data, no need to wrap
            pageCount: Int(result.pageCount),
            warnings: result.warnings,
            errors: [],
            sourceMapEntries: sourceMapEntries
        )
    }

    /// Generate source map entries by parsing the Typst source
    ///
    /// This is an approximation that identifies structural elements (headings, paragraphs)
    /// and estimates their positions in the rendered PDF. For precise mapping, we would
    /// need deeper integration with Typst's compiler internals.
    private static func generateSourceMapEntries(source: String, options: RenderOptions) -> [SourceMapEntry] {
        var entries: [SourceMapEntry] = []

        // Page dimensions and margins (assuming A4 for now, 72 pt margins)
        let marginTop = 72.0
        let marginRight = 72.0
        let marginLeft = 72.0
        let pageWidth = options.pageSize == .letter ? 612.0 : 595.0  // Letter vs A4
        let contentWidth = pageWidth - marginLeft - marginRight
        let fontSize = 11.0
        let lineHeight = fontSize * 1.4
        let headingHeight = fontSize * 2.0

        var currentY = marginTop
        var byteOffset = 0

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineBytes = line.utf8.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Empty line - paragraph break
                currentY += lineHeight * 0.5
            } else if trimmed.hasPrefix("= ") {
                // Level 1 heading
                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft,
                    y: currentY,
                    width: contentWidth,
                    height: headingHeight,
                    contentType: .heading
                ))
                currentY += headingHeight + lineHeight * 0.5
            } else if trimmed.hasPrefix("== ") || trimmed.hasPrefix("=== ") {
                // Level 2+ heading
                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft,
                    y: currentY,
                    width: contentWidth,
                    height: headingHeight * 0.8,
                    contentType: .heading
                ))
                currentY += headingHeight * 0.8 + lineHeight * 0.3
            } else if trimmed.hasPrefix("$") && trimmed.hasSuffix("$") {
                // Display math
                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft,
                    y: currentY,
                    width: contentWidth,
                    height: lineHeight * 1.5,
                    contentType: .math
                ))
                currentY += lineHeight * 2.0
            } else if trimmed.hasPrefix("```") {
                // Code block start/end
                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft,
                    y: currentY,
                    width: contentWidth,
                    height: lineHeight,
                    contentType: .code
                ))
                currentY += lineHeight
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("* ") {
                // List item
                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft + 20.0,
                    y: currentY,
                    width: contentWidth - 20.0,
                    height: lineHeight,
                    contentType: .listItem
                ))
                currentY += lineHeight
            } else {
                // Regular text paragraph
                let charsPerLine = Int(contentWidth / (fontSize * 0.5))
                let numLines = max(1, trimmed.count / charsPerLine)
                let paraHeight = lineHeight * Double(numLines)

                entries.append(SourceMapEntry(
                    sourceStart: byteOffset,
                    sourceEnd: byteOffset + lineBytes,
                    page: 0,
                    x: marginLeft,
                    y: currentY,
                    width: contentWidth,
                    height: paraHeight,
                    contentType: .text
                ))
                currentY += paraHeight
            }

            // Account for newline character
            byteOffset += lineBytes + 1
        }

        return entries
    }

}

// MARK: - LaTeX Conversion

/// LaTeX converter for import/export
public struct LatexConverter {
    public init() {}

    /// Convert Typst source to LaTeX
    public func typstToLatex(_ source: String, template: JournalTemplate = .generic) -> String {
        // Placeholder implementation
        var latex = "\\documentclass{article}\n\\begin{document}\n"
        latex += source
            .replacingOccurrences(of: "= ", with: "\\section{")
            .replacingOccurrences(of: "== ", with: "\\subsection{")
            .replacingOccurrences(of: "*", with: "\\textbf{")
            .replacingOccurrences(of: "_", with: "\\textit{")
            .replacingOccurrences(of: "@", with: "\\cite{")
        latex += "\n\\end{document}"
        return latex
    }

    /// Check if text looks like LaTeX
    public func isLatex(_ text: String) -> Bool {
        let patterns = ["\\begin{", "\\section{", "\\cite{", "\\textbf{"]
        return patterns.contains { text.contains($0) }
    }

    public enum JournalTemplate: String, CaseIterable {
        case generic = "article"
        case mnras = "mnras"
        case apj = "aastex"
        case aa = "aa"
        case physrevd = "revtex4"
        case jcap = "jcap"
    }
}

// MARK: - Citation API

/// Citation reference for cross-app transfer
public struct CitationReference: Identifiable, Hashable {
    public let id: UUID
    public let citeKey: String
    public let publicationId: String
    public let title: String
    public let authorsShort: String
    public let year: Int?
    public let bibtex: String

    public init(id: UUID = UUID(), citeKey: String, publicationId: String, title: String, authorsShort: String, year: Int?, bibtex: String) {
        self.id = id
        self.citeKey = citeKey
        self.publicationId = publicationId
        self.title = title
        self.authorsShort = authorsShort
        self.year = year
        self.bibtex = bibtex
    }

    public var typstCitation: String {
        "@\(citeKey)"
    }

    public var latexCitation: String {
        "\\cite{\(citeKey)}"
    }
}

// MARK: - Version Info

/// Library version information
public struct ImprintCoreVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0
    public static var string: String { "\(major).\(minor).\(patch)" }
}
