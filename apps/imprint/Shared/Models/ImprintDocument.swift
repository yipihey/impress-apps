import SwiftUI
import UniformTypeIdentifiers

/// The document type for imprint files
///
/// ImprintDocument wraps the Rust CRDT document and handles:
/// - File I/O (reading/writing .imprint packages)
/// - Undo/redo tracking
/// - Document metadata
extension UTType {
    /// The imprint document type
    static var imprintDocument: UTType {
        UTType(exportedAs: "com.imbib.imprint.document", conformingTo: .package)
    }
}

/// A collaborative academic document
///
/// Uses Automerge CRDT for conflict-free merging when syncing between devices
/// or collaborating in real-time.
struct ImprintDocument: FileDocument {
    // MARK: - Properties

    /// The Typst source content
    var source: String

    /// Document title (from metadata or first heading)
    var title: String

    /// Author list
    var authors: [String]

    /// Creation timestamp
    var createdAt: Date

    /// Last modified timestamp
    var modifiedAt: Date

    /// Bibliography entries (cite key -> BibTeX)
    var bibliography: [String: String]

    /// Document snapshot for undo (CRDT bytes)
    private var automergeData: Data?

    // MARK: - FileDocument

    static var readableContentTypes: [UTType] { [.imprintDocument, .plainText] }
    static var writableContentTypes: [UTType] { [.imprintDocument] }

    init(configuration: ReadConfiguration) throws {
        if configuration.contentType == .imprintDocument {
            // Read from .imprint package
            guard let wrapper = configuration.file.fileWrappers else {
                throw CocoaError(.fileReadCorruptFile)
            }

            // Read main source file
            if let sourceWrapper = wrapper["main.typ"],
               let data = sourceWrapper.regularFileContents,
               let text = String(data: data, encoding: .utf8) {
                source = text
            } else {
                source = ""
            }

            // Read metadata
            if let metadataWrapper = wrapper["metadata.json"],
               let data = metadataWrapper.regularFileContents,
               let metadata = try? JSONDecoder().decode(DocumentMetadata.self, from: data) {
                title = metadata.title
                authors = metadata.authors
                createdAt = metadata.createdAt
                modifiedAt = metadata.modifiedAt
            } else {
                title = "Untitled"
                authors = []
                createdAt = Date()
                modifiedAt = Date()
            }

            // Read bibliography
            if let bibWrapper = wrapper["bibliography.bib"],
               let data = bibWrapper.regularFileContents,
               let text = String(data: data, encoding: .utf8) {
                bibliography = Self.parseBibliography(text)
            } else {
                bibliography = [:]
            }

            // Read CRDT state
            if let crdtWrapper = wrapper["document.crdt"],
               let data = crdtWrapper.regularFileContents {
                automergeData = data
            }

        } else {
            // Plain text import
            guard let data = configuration.file.regularFileContents,
                  let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            source = text
            title = "Untitled"
            authors = []
            createdAt = Date()
            modifiedAt = Date()
            bibliography = [:]
        }
    }

    init() {
        source = Self.defaultTemplate
        title = "Untitled"
        authors = []
        createdAt = Date()
        modifiedAt = Date()
        bibliography = [:]
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Create package wrapper
        var wrappers: [String: FileWrapper] = [:]

        // Main source file
        if let sourceData = source.data(using: .utf8) {
            wrappers["main.typ"] = FileWrapper(regularFileWithContents: sourceData)
        }

        // Metadata
        let metadata = DocumentMetadata(
            title: title,
            authors: authors,
            createdAt: createdAt,
            modifiedAt: Date()
        )
        if let metadataData = try? JSONEncoder().encode(metadata) {
            wrappers["metadata.json"] = FileWrapper(regularFileWithContents: metadataData)
        }

        // Bibliography
        if !bibliography.isEmpty {
            let bibContent = bibliography.values.joined(separator: "\n\n")
            if let bibData = bibContent.data(using: .utf8) {
                wrappers["bibliography.bib"] = FileWrapper(regularFileWithContents: bibData)
            }
        }

        // CRDT state (if available)
        if let crdtData = automergeData {
            wrappers["document.crdt"] = FileWrapper(regularFileWithContents: crdtData)
        }

        return FileWrapper(directoryWithFileWrappers: wrappers)
    }

    // MARK: - Document Operations

    /// Insert text at the cursor position
    mutating func insertText(_ text: String, at position: Int) {
        let index = source.index(source.startIndex, offsetBy: min(position, source.count))
        source.insert(contentsOf: text, at: index)
        modifiedAt = Date()
    }

    /// Delete text in a range
    mutating func deleteText(in range: Range<Int>) {
        let startIndex = source.index(source.startIndex, offsetBy: range.lowerBound)
        let endIndex = source.index(source.startIndex, offsetBy: min(range.upperBound, source.count))
        source.removeSubrange(startIndex..<endIndex)
        modifiedAt = Date()
    }

    /// Add a citation to the bibliography
    mutating func addCitation(key: String, bibtex: String) {
        bibliography[key] = bibtex
        modifiedAt = Date()
    }

    /// Insert a citation reference at position
    mutating func insertCitation(key: String, at position: Int) {
        insertText("@\(key)", at: position)
    }

    // MARK: - Private

    private static let defaultTemplate = """
    // imprint document
    // A new academic paper

    = Introduction

    This is a new document created with imprint.

    Start writing here, or use Cmd+Shift+K to insert citations from imbib.
    """

    private static func parseBibliography(_ content: String) -> [String: String] {
        // Simple BibTeX parser - extract entries by key
        var result: [String: String] = [:]
        let pattern = #"@\w+\{([^,]+),"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        let matches = regex?.matches(in: content, range: NSRange(content.startIndex..., in: content)) ?? []

        for match in matches {
            if let keyRange = Range(match.range(at: 1), in: content) {
                let key = String(content[keyRange])
                // Find the full entry (simplified - just store entire content for now)
                result[key] = content
            }
        }

        return result
    }
}

// MARK: - Document Metadata

private struct DocumentMetadata: Codable {
    let title: String
    let authors: [String]
    let createdAt: Date
    let modifiedAt: Date
}
