//
//  ManuscriptLibraryCoordinator.swift
//  imprint
//
//  Creates and maintains an imbib library that holds all papers cited in
//  a given manuscript. When new citations are inserted (via the inline
//  palette or any other flow), they are added to this library automatically.
//
//  The library UUID is stored on the ImprintDocument (`linkedImbibLibraryID`)
//  and persists across saves.
//

import Foundation
import ImpressLogging

/// Coordinates the lifecycle of the manuscript-local imbib library.
@MainActor
final class ManuscriptLibraryCoordinator {

    static let shared = ManuscriptLibraryCoordinator()

    private init() {}

    /// Ensure the given document has a linked imbib library. Creates one if needed.
    ///
    /// - Parameters:
    ///   - document: The document (its `linkedImbibLibraryID` is updated in place).
    /// - Returns: The library UUID (new or existing), or nil if the shared store is unavailable.
    @discardableResult
    func ensureLibrary(for document: inout ImprintDocument) -> String? {
        if let existing = document.linkedImbibLibraryID, !existing.isEmpty {
            return existing
        }
        guard ImprintPublicationService.shared.isReady else {
            logInfo("ManuscriptLibraryCoordinator: store not ready, skipping library creation", category: "manuscript-library")
            return nil
        }
        let name = suggestedLibraryName(for: document)
        do {
            let libraryID = try ImprintPublicationService.shared.createLibrary(name: name)
            document.linkedImbibLibraryID = libraryID
            logInfo("ManuscriptLibraryCoordinator: created library '\(name)' → \(libraryID)", category: "manuscript-library")
            return libraryID
        } catch {
            logInfo("ManuscriptLibraryCoordinator: createLibrary failed: \(error.localizedDescription)", category: "manuscript-library")
            return nil
        }
    }

    /// Add a publication to the document's library. Creates the library first if needed.
    ///
    /// - Parameters:
    ///   - publicationID: UUID of the publication in imbib
    ///   - document: The document (its `linkedImbibLibraryID` may be mutated)
    func addPublication(publicationID: String, to document: inout ImprintDocument) {
        guard let libraryID = ensureLibrary(for: &document) else { return }
        do {
            try ImprintPublicationService.shared.addPublicationsToLibrary(
                libraryID: libraryID,
                publicationIDs: [publicationID]
            )
            logInfo("ManuscriptLibraryCoordinator: added \(publicationID) to library \(libraryID)", category: "manuscript-library")
        } catch {
            logInfo("ManuscriptLibraryCoordinator: addPublicationsToLibrary failed: \(error.localizedDescription)", category: "manuscript-library")
        }
    }

    /// Suggested library name based on document title. Used both on creation
    /// and by `UnfoundPaperRow` for its "New Library..." default.
    func suggestedLibraryName(for document: ImprintDocument) -> String {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return "Manuscript References"
        }
        return "References: \(title)"
    }
}
