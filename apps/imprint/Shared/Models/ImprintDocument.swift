import SwiftUI
import UniformTypeIdentifiers

/// The document type for imprint files
///
/// ImprintDocument wraps the Rust CRDT document and handles:
/// - File I/O (reading/writing .imprint packages and .tex files)
/// - Undo/redo tracking
/// - Document metadata
extension UTType {
    /// The imprint document type
    static var imprintDocument: UTType {
        UTType(exportedAs: "com.imbib.imprint.document", conformingTo: .package)
    }

    /// LaTeX source files. The macOS UTI for `.tex` is `org.tug.tex`
    /// (registered by the TeX User Group). Spotlight, Open dialog, and
    /// Recent Documents all key off this identifier — declaring the
    /// non-existent `public.tex` (an old typo) breaks all three.
    static var latexSource: UTType {
        UTType(filenameExtension: "tex") ?? UTType("org.tug.tex") ?? .plainText
    }
}

/// A collaborative academic document
///
/// Uses Automerge CRDT for conflict-free merging when syncing between devices
/// or collaborating in real-time.
struct ImprintDocument: FileDocument, Equatable {
    // Equatable by ID - used for SwiftUI onChange tracking
    static func == (lhs: ImprintDocument, rhs: ImprintDocument) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Properties

    /// Stable document identifier (persists across renames/moves)
    var id: UUID

    /// The source content (Typst or LaTeX)
    var source: String

    /// Document format — Typst (.imprint/.typ) or LaTeX (.tex)
    var format: DocumentFormat = .typst

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

    /// UUID of the linked imbib manuscript, if any
    var linkedImbibManuscriptID: UUID?

    /// UUID of the imbib library that holds papers cited in this manuscript.
    /// Created on first save; populated by `ManuscriptLibraryCoordinator`.
    var linkedImbibLibraryID: String?

    /// Document snapshot for undo (CRDT bytes)
    private var automergeData: Data?

    /// Tracked Veusz plots (figures/*.vsz). Empty for documents that haven't
    /// added any plots yet, including all pre-v1.3 documents.
    var plots: [VeuszPlotRef] = []

    /// File contents under `figures/` in the package, keyed by name (e.g. "pulse.vsz").
    /// Carries every file in `figures/` through a read → write round-trip so manuscripts
    /// don't silently lose plot sources or rendered figures while Phase 1 lays the model
    /// groundwork. Phase 3 replaces this with a per-document working directory.
    var figureFiles: [String: Data] = [:]

    // FAIR attribution (ADR-0014 D54, schema v1.4+). All optional. `embargoUntil`
    // is informational only — no enforcement code paths.
    var orcid: String? = nil
    var affiliation: String? = nil
    var funder: String? = nil
    var license: String? = nil
    var embargoUntil: Date? = nil

    // MARK: - FileDocument

    static var readableContentTypes: [UTType] { [.imprintDocument, .latexSource, .plainText] }
    static var writableContentTypes: [UTType] { [.imprintDocument, .latexSource, .plainText] }

    init(configuration: ReadConfiguration) throws {
        // Tolerate a `.imprint` file that's actually a regular text file
        // (e.g. saved with the wrong format dropdown by a previous build
        // that didn't enforce the format/extension match). Detect the
        // mismatch by inspecting the file wrapper structure: a real
        // `.imprint` package has child wrappers; a misnamed regular file
        // does not. If we hit that case, fall through to the
        // plain-text/LaTeX recovery branch so the user can still
        // recover their source.
        let isMisnamedRegularFile = configuration.contentType == .imprintDocument
            && configuration.file.fileWrappers == nil
            && configuration.file.regularFileContents != nil

        if configuration.contentType == .imprintDocument && !isMisnamedRegularFile {
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
               let data = metadataWrapper.regularFileContents {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let metadata = try? decoder.decode(DocumentMetadata.self, from: data) {
                    id = metadata.id
                    title = metadata.title
                    authors = metadata.authors
                    createdAt = metadata.createdAt
                    modifiedAt = metadata.modifiedAt
                    linkedImbibManuscriptID = metadata.linkedImbibManuscriptID
                    linkedImbibLibraryID = metadata.linkedImbibLibraryID
                    plots = metadata.plots
                    // FAIR fields (ADR-0014 D54). Default to nil for older docs.
                    orcid = metadata.orcid
                    affiliation = metadata.affiliation
                    funder = metadata.funder
                    license = metadata.license
                    embargoUntil = metadata.embargoUntil

                    // Validate schema version
                    let checker = DocumentVersionChecker()
                    if !checker.canOpen(versionRaw: metadata.schemaVersion) {
                        throw DocumentMigrationError.newerVersion(documentVersion: metadata.schemaVersion)
                    }
                } else {
                    // Legacy format without schemaVersion - assign defaults
                    id = UUID()
                    title = "Untitled"
                    authors = []
                    createdAt = Date()
                    modifiedAt = Date()
                    linkedImbibManuscriptID = nil
                }
            } else {
                id = UUID()
                title = "Untitled"
                authors = []
                createdAt = Date()
                modifiedAt = Date()
                linkedImbibManuscriptID = nil
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

            // Read figures/ directory (Veusz plot sources + rendered outputs)
            if let figuresWrapper = wrapper["figures"],
               figuresWrapper.isDirectory,
               let children = figuresWrapper.fileWrappers {
                for (name, child) in children {
                    if let data = child.regularFileContents {
                        figureFiles[name] = data
                    }
                }
            }

            // Read RO-Crate overlay (ADR-0014 D55). When the overlay is
            // present, its FAIR fields take precedence over metadata.json's
            // — this lets an external editor mutate the overlay and have
            // those changes respected on next open.
            if let crateWrapper = wrapper[ROCrateBuilder.manifestFilename],
               let crateData = crateWrapper.regularFileContents,
               let lifted = ROCrateBuilder.readFAIRFields(from: crateData),
               !lifted.isEmpty {
                if let v = lifted.orcid { orcid = v }
                if let v = lifted.affiliation { affiliation = v }
                if let v = lifted.funder { funder = v }
                if let v = lifted.license { license = v }
                if let v = lifted.embargoUntil { embargoUntil = v }
            }

        } else {
            // Plain text, LaTeX import, or recovery from a misnamed
            // `.imprint` regular file. Detect format from content rather
            // than relying on the (possibly wrong) extension.
            guard let data = configuration.file.regularFileContents,
                  let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            id = UUID()
            source = text
            title = "Untitled"
            authors = []
            createdAt = Date()
            modifiedAt = Date()
            bibliography = [:]
            linkedImbibManuscriptID = nil

            // Detect LaTeX format from content type or content heuristics
            if configuration.contentType == .latexSource {
                format = .latex
            } else {
                format = DocumentFormat.detect(from: text)
            }
        }
    }

    init() {
        self.init(format: .typst)
    }

    /// Create a new empty document for the given format. Used by the
    /// "New" / "New LaTeX Document" File-menu commands so a fresh
    /// untitled buffer starts in the right syntax mode and with a
    /// matching starter template.
    init(format: DocumentFormat) {
        self.id = UUID()
        self.format = format
        self.source = format == .latex ? Self.defaultLatexTemplate : Self.defaultTemplate
        self.title = "Untitled"
        self.authors = []
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.bibliography = [:]
        self.linkedImbibManuscriptID = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Reject format/extension mismatches BEFORE writing — otherwise a
        // user creating a "New LaTeX Document" who hits Save without
        // changing the format dropdown ends up with a plain .tex file
        // wearing a `.imprint` extension. macOS then refuses to open it
        // because `.imprint` is registered as a package (directory) and
        // the file is not a directory.
        if format == .latex && configuration.contentType == .imprintDocument {
            throw NSError(
                domain: "imprint.save",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey: "Can't save a LaTeX document as an Imprint package.",
                    NSLocalizedRecoverySuggestionErrorKey: "In the Save panel, change the Format menu to \"LaTeX Source\" so the file is saved with a .tex extension."
                ]
            )
        }
        if format == .typst && configuration.contentType == .latexSource {
            throw NSError(
                domain: "imprint.save",
                code: 1002,
                userInfo: [
                    NSLocalizedDescriptionKey: "Can't save a Typst document as LaTeX Source.",
                    NSLocalizedRecoverySuggestionErrorKey: "In the Save panel, change the Format menu to \"Imprint Document\" so the file is saved with a .imprint extension."
                ]
            )
        }

        // LaTeX files: write as plain .tex file, not a package
        if format == .latex {
            guard let data = source.data(using: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // Notify listeners that a save occurred
            NotificationCenter.default.post(name: .imprintDocumentDidSave, object: nil, userInfo: ["documentID": id.uuidString])
            return FileWrapper(regularFileWithContents: data)
        }

        // Typst: Create package wrapper
        var wrappers: [String: FileWrapper] = [:]

        // Main source file
        if let sourceData = source.data(using: .utf8) {
            wrappers["main.typ"] = FileWrapper(regularFileWithContents: sourceData)
        }

        // Metadata
        var metadata = DocumentMetadata(
            schemaVersion: DocumentSchemaVersion.current.rawValue,
            id: id,
            title: title,
            authors: authors,
            createdAt: createdAt,
            modifiedAt: Date(),
            linkedImbibManuscriptID: linkedImbibManuscriptID,
            lastSavedByAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            plots: plots,
            orcid: orcid,
            affiliation: affiliation,
            funder: funder,
            license: license,
            embargoUntil: embargoUntil
        )
        metadata.linkedImbibLibraryID = linkedImbibLibraryID
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let metadataData = try? encoder.encode(metadata) {
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

        // figures/ directory (Veusz plot sources + rendered outputs).
        // Only emit the directory when there are figures to write so old
        // documents that never touched the feature stay byte-identical on disk.
        if !figureFiles.isEmpty {
            var figureWrappers: [String: FileWrapper] = [:]
            for (name, data) in figureFiles {
                let child = FileWrapper(regularFileWithContents: data)
                child.preferredFilename = name
                figureWrappers[name] = child
            }
            let figuresDirectory = FileWrapper(directoryWithFileWrappers: figureWrappers)
            figuresDirectory.preferredFilename = "figures"
            wrappers["figures"] = figuresDirectory
        }

        // RO-Crate metadata overlay (ADR-0014 D55). Regenerated on every save.
        // metadata.json stays authoritative; this is a FAIR-tool-readable view.
        let bibKeys = Array(bibliography.keys).sorted()
        if let crateData = ROCrateBuilder.build(for: self, bibKeys: bibKeys) {
            wrappers[ROCrateBuilder.manifestFilename] = FileWrapper(regularFileWithContents: crateData)
        }

        // Notify listeners that a save occurred
        NotificationCenter.default.post(name: .imprintDocumentDidSave, object: nil, userInfo: ["documentID": id.uuidString])

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

    /// Insert a citation reference at position (format-aware)
    mutating func insertCitation(key: String, at position: Int) {
        let cite = format.citationInsert
        insertText("\(cite.prefix)\(key)\(cite.suffix)", at: position)
    }

    // MARK: - Private

    private static let defaultTemplate = """
    // imprint document
    // A new academic paper

    = Introduction

    This is a new document created with imprint.

    Start writing here, or use Cmd+Shift+K to insert citations from imbib.
    """

    /// Minimal `article`-class LaTeX starter used by the "New LaTeX
    /// Document" File-menu command. Mirrors the Typst template's tone:
    /// a runnable skeleton with a hint about citation insertion.
    private static let defaultLatexTemplate = """
    \\documentclass{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage{amsmath, amssymb}

    \\title{Untitled}
    \\author{}
    \\date{\\today}

    \\begin{document}
    \\maketitle

    \\section{Introduction}

    This is a new LaTeX document created with imprint.

    Start writing here, or use Cmd+Shift+K to insert citations from imbib.

    \\bibliographystyle{plain}
    % \\bibliography{main}

    \\end{document}
    """

    private static func parseBibliography(_ content: String) -> [String: String] {
        // BibTeX parser - extract individual entries by key
        var result: [String: String] = [:]
        let pattern = #"@\w+\{([^,]+),"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return result }

        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

        for (i, match) in matches.enumerated() {
            guard let keyRange = Range(match.range(at: 1), in: content) else { continue }
            let key = String(content[keyRange])

            // Extract the entry from this match start to the next match start (or end of string)
            let entryStart = match.range.location
            let entryEnd: Int
            if i + 1 < matches.count {
                entryEnd = matches[i + 1].range.location
            } else {
                entryEnd = content.utf16.count
            }
            let entryNSRange = NSRange(location: entryStart, length: entryEnd - entryStart)
            if let entryRange = Range(entryNSRange, in: content) {
                result[key] = String(content[entryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}

// MARK: - Document Metadata

struct DocumentMetadata: Codable {
    /// Schema version of this document format.
    var schemaVersion: Int

    /// Stable document identifier (persists across renames/moves)
    let id: UUID

    let title: String
    let authors: [String]
    let createdAt: Date
    let modifiedAt: Date

    /// UUID of the linked imbib manuscript, if any
    var linkedImbibManuscriptID: UUID?

    /// UUID of the imbib library holding papers cited in this manuscript (created on first save).
    var linkedImbibLibraryID: String?

    /// App version that last saved this document.
    var lastSavedByAppVersion: String?

    /// Tracked Veusz plots. Empty for v1.2 and older documents.
    var plots: [VeuszPlotRef]

    // FAIR attribution (ADR-0014 D54, schema v1.4+). All optional.
    var orcid: String?
    var affiliation: String?
    var funder: String?
    var license: String?
    var embargoUntil: Date?

    init(
        schemaVersion: Int = DocumentSchemaVersion.current.rawValue,
        id: UUID = UUID(),
        title: String,
        authors: [String],
        createdAt: Date,
        modifiedAt: Date,
        linkedImbibManuscriptID: UUID? = nil,
        lastSavedByAppVersion: String? = nil,
        plots: [VeuszPlotRef] = [],
        orcid: String? = nil,
        affiliation: String? = nil,
        funder: String? = nil,
        license: String? = nil,
        embargoUntil: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.authors = authors
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.linkedImbibManuscriptID = linkedImbibManuscriptID
        self.lastSavedByAppVersion = lastSavedByAppVersion
        self.plots = plots
        self.orcid = orcid
        self.affiliation = affiliation
        self.funder = funder
        self.license = license
        self.embargoUntil = embargoUntil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, authors, createdAt, modifiedAt
        case linkedImbibManuscriptID, linkedImbibLibraryID, lastSavedByAppVersion, plots
        case orcid, affiliation, funder, license, embargoUntil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        authors = try c.decode([String].self, forKey: .authors)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        linkedImbibManuscriptID = try c.decodeIfPresent(UUID.self, forKey: .linkedImbibManuscriptID)
        linkedImbibLibraryID = try c.decodeIfPresent(String.self, forKey: .linkedImbibLibraryID)
        lastSavedByAppVersion = try c.decodeIfPresent(String.self, forKey: .lastSavedByAppVersion)
        plots = try c.decodeIfPresent([VeuszPlotRef].self, forKey: .plots) ?? []
        orcid = try c.decodeIfPresent(String.self, forKey: .orcid)
        affiliation = try c.decodeIfPresent(String.self, forKey: .affiliation)
        funder = try c.decodeIfPresent(String.self, forKey: .funder)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        embargoUntil = try c.decodeIfPresent(Date.self, forKey: .embargoUntil)
    }

    /// Get the schema version as an enum, if valid.
    var schemaVersionEnum: DocumentSchemaVersion? {
        DocumentSchemaVersion(rawValue: schemaVersion)
    }
}
