//
//  AddPapersIntent.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//
//  AppIntents for PDFs and paper lookup (ADR-018).
//

import AppIntents
import Foundation
import PublicationManagerCore

// Adding papers by identifier is the generated
// `ImbibLibraryImportIdentifiersIntent` (VerbIntents/), dispatched through the
// `imbib-library-service_import-identifiers` verb so it passes the same
// policy, review and audit as every other caller. The hand-written
// AddPapers / AddPaperByDOI / AddPaperByArXiv / AddPaperByBibcode intents it
// replaces are retired.

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
