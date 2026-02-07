import AppIntents
import Foundation

// MARK: - Service Locator

/// Protocol for providing document services to App Intents.
/// The main app target registers a concrete implementation at launch.
@available(macOS 14.0, iOS 17.0, *)
public protocol ImprintIntentService: Sendable {
    func listDocuments(limit: Int) async throws -> [DocumentEntity]
    func getDocumentContent(id: UUID) async throws -> String
    func createDocument(title: String, template: String?) async throws -> DocumentEntity
    func compileDocument(id: UUID) async throws
    func searchDocument(id: UUID, query: String) async throws -> [String]
    func exportDocument(id: UUID, format: String) async throws -> String
    func getBibliography(id: UUID) async throws -> String
    func documentsForIds(_ ids: [UUID]) async throws -> [DocumentEntity]
    func searchDocumentsByTitle(_ query: String) async throws -> [DocumentEntity]
}

/// Global service locator — set by the app at launch.
@available(macOS 14.0, iOS 17.0, *)
public enum ImprintIntentServiceLocator {
    @MainActor public static var service: (any ImprintIntentService)?
}

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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let documents = try await service.listDocuments(limit: limit)
        return .result(value: documents)
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let content = try await service.getDocumentContent(id: document.id)
        return .result(value: content)
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let doc = try await service.createDocument(title: title, template: template)
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        try await service.compileDocument(id: document.id)
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
        // Citation insertion requires active editor focus — post notification for the app to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("insertCitationFromIntent"),
                object: nil,
                userInfo: ["documentId": document.id.uuidString, "citeKey": citeKey]
            )
        }
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let matches = try await service.searchDocument(id: document.id, query: query)
        return .result(value: matches)
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let content = try await service.exportDocument(id: document.id, format: format.rawValue)
        return .result(value: content)
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
        guard let service = await ImprintIntentServiceLocator.service else {
            throw ImprintIntentError.automationDisabled
        }
        let bibliography = try await service.getBibliography(id: document.id)
        return .result(value: bibliography)
    }
}
