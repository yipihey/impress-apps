//
//  AddPapersIntent.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  AppIntents for adding papers to the library (ADR-018).
//

import AppIntents
import Foundation

// MARK: - Add Papers Intent

/// Add papers to the library by identifier (DOI, arXiv, bibcode, etc.).
@available(iOS 16.0, macOS 13.0, *)
public struct AddPapersIntent: AppIntent {

    public static var title: LocalizedStringResource = "Add Papers to imbib"

    public static var description = IntentDescription(
        "Add papers to your imbib library using identifiers like DOI, arXiv ID, or bibcode.",
        categoryName: "Library",
        searchKeywords: ["add", "import", "paper", "article", "doi", "arxiv"]
    )

    public static var parameterSummary: some ParameterSummary {
        Summary("Add papers with identifiers \(\.$identifiers)") {
            \.$downloadPDFs
            \.$collection
        }
    }

    // MARK: - Parameters

    @Parameter(
        title: "Identifiers",
        description: "DOI, arXiv ID, or bibcode of papers to add (one per line or comma-separated)"
    )
    public var identifiers: [String]

    @Parameter(
        title: "Download PDFs",
        description: "Automatically download PDFs when available",
        default: true
    )
    public var downloadPDFs: Bool

    @Parameter(
        title: "Collection",
        description: "Collection to add papers to (optional)"
    )
    public var collection: CollectionEntity?

    // MARK: - Initialization

    public init() {}

    public init(identifiers: [String], downloadPDFs: Bool = true, collection: CollectionEntity? = nil) {
        self.identifiers = identifiers
        self.downloadPDFs = downloadPDFs
        self.collection = collection
    }

    // MARK: - Perform

    public func perform() async throws -> some IntentResult & ReturnsValue<[PaperEntity]> {
        // Check if automation is enabled
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        // Parse identifiers
        let paperIdentifiers = identifiers.map { PaperIdentifier.fromString($0) }

        // Add papers
        let result = try await AutomationService.shared.addPapers(
            identifiers: paperIdentifiers,
            collection: collection?.id,
            library: nil,
            downloadPDFs: downloadPDFs
        )

        // Convert to entities
        let entities = result.added.map { PaperEntity(from: $0) }

        return .result(value: entities)
    }
}

// MARK: - Add Paper by DOI Intent

/// Quick action to add a single paper by DOI.
@available(iOS 16.0, macOS 13.0, *)
public struct AddPaperByDOIIntent: AppIntent {

    public static var title: LocalizedStringResource = "Add Paper by DOI"

    public static var description = IntentDescription(
        "Add a paper to your library using its DOI.",
        categoryName: "Library"
    )

    @Parameter(title: "DOI", description: "The DOI of the paper (e.g., 10.1038/nature12373)")
    public var doi: String

    @Parameter(title: "Download PDF", default: true)
    public var downloadPDF: Bool

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<PaperEntity?> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let result = try await AutomationService.shared.addPapers(
            identifiers: [.doi(doi)],
            collection: nil,
            library: nil,
            downloadPDFs: downloadPDF
        )

        guard let added = result.added.first else {
            if !result.duplicates.isEmpty {
                // Paper already exists, try to fetch it
                if let existing = try await AutomationService.shared.getPaper(identifier: .doi(doi)) {
                    return .result(value: PaperEntity(from: existing))
                }
            }
            return .result(value: nil)
        }

        return .result(value: PaperEntity(from: added))
    }
}

// MARK: - Add Paper by arXiv Intent

/// Quick action to add a single paper by arXiv ID.
@available(iOS 16.0, macOS 13.0, *)
public struct AddPaperByArXivIntent: AppIntent {

    public static var title: LocalizedStringResource = "Add Paper by arXiv ID"

    public static var description = IntentDescription(
        "Add a paper to your library using its arXiv ID.",
        categoryName: "Library"
    )

    @Parameter(title: "arXiv ID", description: "The arXiv ID (e.g., 2301.12345 or hep-th/9901001)")
    public var arxivID: String

    @Parameter(title: "Download PDF", default: true)
    public var downloadPDF: Bool

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<PaperEntity?> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let result = try await AutomationService.shared.addPapers(
            identifiers: [.arxiv(arxivID)],
            collection: nil,
            library: nil,
            downloadPDFs: downloadPDF
        )

        guard let added = result.added.first else {
            if !result.duplicates.isEmpty {
                if let existing = try await AutomationService.shared.getPaper(identifier: .arxiv(arxivID)) {
                    return .result(value: PaperEntity(from: existing))
                }
            }
            return .result(value: nil)
        }

        return .result(value: PaperEntity(from: added))
    }
}

// MARK: - Add Paper by Bibcode Intent

/// Quick action to add a single paper by ADS bibcode.
@available(iOS 16.0, macOS 13.0, *)
public struct AddPaperByBibcodeIntent: AppIntent {

    public static var title: LocalizedStringResource = "Add Paper by Bibcode"

    public static var description = IntentDescription(
        "Add a paper to your library using its ADS bibcode.",
        categoryName: "Library"
    )

    @Parameter(title: "Bibcode", description: "The ADS bibcode (e.g., 2023ApJ...950L..22A)")
    public var bibcode: String

    @Parameter(title: "Download PDF", default: true)
    public var downloadPDF: Bool

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<PaperEntity?> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let result = try await AutomationService.shared.addPapers(
            identifiers: [.bibcode(bibcode)],
            collection: nil,
            library: nil,
            downloadPDFs: downloadPDF
        )

        guard let added = result.added.first else {
            if !result.duplicates.isEmpty {
                if let existing = try await AutomationService.shared.getPaper(identifier: .bibcode(bibcode)) {
                    return .result(value: PaperEntity(from: existing))
                }
            }
            return .result(value: nil)
        }

        return .result(value: PaperEntity(from: added))
    }
}

// MARK: - Download PDFs Intent

/// Download PDFs for papers in the library.
@available(iOS 16.0, macOS 13.0, *)
public struct DownloadPDFsIntent: AppIntent {

    public static var title: LocalizedStringResource = "Download PDFs"

    public static var description = IntentDescription(
        "Download PDFs for papers in your library.",
        categoryName: "Library"
    )

    @Parameter(title: "Papers", description: "Papers to download PDFs for")
    public var papers: [PaperEntity]

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let identifiers = papers.map { PaperIdentifier.uuid($0.id) }
        let result = try await AutomationService.shared.downloadPDFs(identifiers: identifiers)

        return .result(value: result.downloaded.count)
    }
}

// MARK: - Get Paper Intent

/// Get details of a specific paper.
@available(iOS 16.0, macOS 13.0, *)
public struct GetPaperIntent: AppIntent {

    public static var title: LocalizedStringResource = "Get Paper"

    public static var description = IntentDescription(
        "Get details of a paper by cite key, DOI, or other identifier.",
        categoryName: "Library"
    )

    @Parameter(title: "Identifier", description: "Cite key, DOI, arXiv ID, or bibcode")
    public var identifier: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<PaperEntity?> {
        let isEnabled = await AutomationSettingsStore.shared.isEnabled
        guard isEnabled else {
            throw IntentError.automationDisabled
        }

        let paperId = PaperIdentifier.fromString(identifier)
        guard let result = try await AutomationService.shared.getPaper(identifier: paperId) else {
            return .result(value: nil)
        }

        return .result(value: PaperEntity(from: result))
    }
}
