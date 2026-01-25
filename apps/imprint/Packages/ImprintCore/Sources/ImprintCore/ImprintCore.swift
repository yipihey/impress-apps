import Foundation

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

    public var isSuccess: Bool { errors.isEmpty }
}

/// Typst renderer (placeholder)
public actor TypstRenderer {
    public init() {}

    public func render(_ source: String, options: RenderOptions = RenderOptions()) async throws -> RenderOutput {
        // Placeholder: return minimal PDF
        // In real implementation, call Rust via UniFFI
        return RenderOutput(
            pdfData: createMinimalPDF(),
            pageCount: 1,
            warnings: [],
            errors: []
        )
    }

    private func createMinimalPDF() -> Data {
        let content = """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >> endobj
        xref
        0 4
        0000000000 65535 f
        0000000009 00000 n
        0000000058 00000 n
        0000000115 00000 n
        trailer << /Size 4 /Root 1 0 R >>
        startxref
        193
        %%EOF
        """
        return content.data(using: .utf8) ?? Data()
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
