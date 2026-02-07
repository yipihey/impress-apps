import AppIntents
import Foundation

// MARK: - List Documents

@available(macOS 14.0, iOS 17.0, *)
public struct ListDocumentsIntent: AppIntent {
    public static var title: LocalizedStringResource = "List Documents"
    public static var description = IntentDescription(
        "List all documents in the imprint workspace.",
        categoryName: "Documents"
    )

    @Parameter(title: "Limit", description: "Maximum number of documents to return", default: 20)
    public var limit: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("List up to \(\.$limit) documents")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[DocumentEntity]> {
        // TODO: Connect to DocumentRegistry to list documents
        return .result(value: [])
    }
}

// MARK: - Get Document Content

@available(macOS 14.0, iOS 17.0, *)
public struct GetDocumentContentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Document Content"
    public static var description = IntentDescription(
        "Get the Typst source content of a document.",
        categoryName: "Documents"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Get content of \(\.$document)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: Read document source from file system
        return .result(value: "")
    }
}

// MARK: - Create Document

@available(macOS 14.0, iOS 17.0, *)
public struct CreateDocumentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Create Document"
    public static var description = IntentDescription(
        "Create a new Typst document in the workspace.",
        categoryName: "Documents"
    )

    @Parameter(title: "Title", description: "The document title")
    public var title: String

    @Parameter(title: "Template", description: "Optional template to use")
    public var template: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Create document titled \(\.$title)") {
            \.$template
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<DocumentEntity> {
        // TODO: Create document via DocumentRegistry
        let doc = DocumentEntity(id: UUID(), title: title)
        return .result(value: doc)
    }
}

// MARK: - Compile Document

@available(macOS 14.0, iOS 17.0, *)
public struct CompileDocumentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Compile Document"
    public static var description = IntentDescription(
        "Compile a Typst document to PDF.",
        categoryName: "Documents"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Compile \(\.$document) to PDF")
    }

    public func perform() async throws -> some IntentResult {
        // TODO: Trigger compilation via TypstRenderer
        return .result()
    }
}

// MARK: - Insert Citation

@available(macOS 14.0, iOS 17.0, *)
public struct InsertCitationIntent: AppIntent {
    public static var title: LocalizedStringResource = "Insert Citation"
    public static var description = IntentDescription(
        "Insert a citation key into the active document.",
        categoryName: "Citations"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    @Parameter(title: "Cite Key", description: "The BibTeX cite key to insert")
    public var citeKey: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Insert @\(\.$citeKey) into \(\.$document)")
    }

    public func perform() async throws -> some IntentResult {
        // TODO: Insert citation via document editing service
        return .result()
    }
}

// MARK: - Search Document

@available(macOS 14.0, iOS 17.0, *)
public struct SearchDocumentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search Document"
    public static var description = IntentDescription(
        "Search for text within a document.",
        categoryName: "Documents"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    @Parameter(title: "Query", description: "Text to search for")
    public var query: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$document) for \(\.$query)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        // TODO: Search document content and return matching lines
        return .result(value: [])
    }
}

// MARK: - Export Document

@available(macOS 14.0, iOS 17.0, *)
public struct ExportDocumentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Export Document"
    public static var description = IntentDescription(
        "Export a document in the specified format.",
        categoryName: "Documents"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    @Parameter(title: "Format", description: "The export format", default: .typst)
    public var format: ImprintExportFormat

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$document) as \(\.$format)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: Export document via LatexConverter or direct source access
        return .result(value: "")
    }
}

// MARK: - Get Bibliography

@available(macOS 14.0, iOS 17.0, *)
public struct GetBibliographyIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Bibliography"
    public static var description = IntentDescription(
        "Get the BibTeX bibliography for a document.",
        categoryName: "Citations"
    )

    @Parameter(title: "Document")
    public var document: DocumentEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Get bibliography of \(\.$document)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // TODO: Extract bibliography from document's .bib data
        return .result(value: "")
    }
}
