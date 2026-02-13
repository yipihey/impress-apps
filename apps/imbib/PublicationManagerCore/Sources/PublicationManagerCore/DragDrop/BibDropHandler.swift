//
//  BibDropHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import OSLog

// MARK: - Bib Drop Handler

/// Handles the workflow for importing .bib and .ris files.
///
/// Workflow:
/// 1. Parse the file to extract entries
/// 2. Check for duplicates
/// 3. Present preview to user
/// 4. Import selected entries
@MainActor
@Observable
public final class BibDropHandler {

    // MARK: - Singleton

    public static let shared = BibDropHandler()

    // MARK: - Observable State

    /// Current preview being prepared
    public var currentPreview: BibImportPreview?

    /// Whether preparation is in progress
    public var isPreparing = false

    // MARK: - Dependencies

    private let store: RustStoreAdapter

    // MARK: - Initialization

    public init(store: RustStoreAdapter = .shared) {
        self.store = store
    }

    // MARK: - Public Methods

    /// Prepare a BibTeX/RIS file for import.
    ///
    /// - Parameters:
    ///   - url: URL of the file to import
    ///   - target: The drop target (determines library)
    /// - Returns: Import preview for user confirmation
    public func prepareBibImport(url: URL, target: DropTarget) async throws -> BibImportPreview {
        Logger.files.infoCapture("Preparing bib import from: \(url.lastPathComponent)", category: "files")

        isPreparing = true
        defer { isPreparing = false }

        let ext = url.pathExtension.lowercased()

        // Determine format
        let format: BibFileFormat
        if ext == "ris" {
            format = .ris
        } else {
            format = .bibtex
        }

        // Parse file
        let (entries, errors) = await parseFile(url: url, format: format)

        // Check for duplicates
        let checkedEntries = checkDuplicates(entries)

        let preview = BibImportPreview(
            sourceURL: url,
            format: format,
            entries: checkedEntries,
            parseErrors: errors
        )

        currentPreview = preview
        return preview
    }

    /// Commit a BibTeX/RIS import.
    ///
    /// - Parameters:
    ///   - preview: The import preview to commit
    ///   - libraryID: Target library UUID
    /// - Returns: IDs of successfully imported publications
    @discardableResult
    public func commitImport(_ preview: BibImportPreview, to libraryID: UUID) async throws -> [UUID] {
        Logger.files.infoCapture("Committing bib import: \(preview.entries.filter { $0.isSelected }.count) entries", category: "files")

        guard store.getLibrary(id: libraryID) != nil else {
            throw DragDropError.libraryNotFound
        }

        // Import selected entries
        var importedIDs: [UUID] = []
        for entry in preview.entries where entry.isSelected {
            if entry.isDuplicate {
                // Skip duplicates unless explicitly enabled
                continue
            }

            do {
                let ids = try importEntry(entry, preview: preview, to: libraryID)
                importedIDs.append(contentsOf: ids)
            } catch {
                Logger.files.errorCapture("Failed to import \(entry.citeKey): \(error.localizedDescription)", category: "files")
            }
        }

        currentPreview = nil

        Logger.files.infoCapture("Imported \(importedIDs.count) entries from \(preview.sourceURL.lastPathComponent)", category: "files")
        return importedIDs
    }

    // MARK: - Private Methods

    /// Parse a BibTeX or RIS file.
    private func parseFile(url: URL, format: BibFileFormat) async -> (entries: [BibImportEntry], errors: [String]) {
        var entries: [BibImportEntry] = []
        var errors: [String] = []

        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            switch format {
            case .bibtex:
                let parser = BibTeXParserFactory.createParser()
                let items = try parser.parse(content)

                for item in items {
                    if case .entry(let entry) = item {
                        let importEntry = BibImportEntry(
                            citeKey: entry.citeKey,
                            entryType: entry.entryType,
                            title: entry.title,
                            authors: parseAuthors(entry.fields["author"]),
                            year: parseYear(entry.fields["year"]),
                            isSelected: true,
                            rawContent: entry.rawBibTeX
                        )
                        entries.append(importEntry)
                    }
                }

            case .ris:
                let parser = RISParserFactory.createParser()
                let risEntries = try parser.parse(content)

                for risEntry in risEntries {
                    // Generate a cite key from RIS entry
                    let citeKey = generateCiteKeyFromRIS(risEntry)

                    let importEntry = BibImportEntry(
                        citeKey: citeKey,
                        entryType: risEntry.type.bibTeXEquivalent,
                        title: risEntry.title,
                        authors: risEntry.authors,
                        year: risEntry.year,
                        isSelected: true,
                        rawContent: risEntry.rawRIS
                    )
                    entries.append(importEntry)
                }
            }
        } catch {
            errors.append("Parse error: \(error.localizedDescription)")
        }

        return (entries, errors)
    }

    /// Check entries for duplicates via the Rust store.
    private func checkDuplicates(_ entries: [BibImportEntry]) -> [BibImportEntry] {
        return entries.map { entry in
            // Check by cite key
            if let existing = store.findByCiteKey(citeKey: entry.citeKey) {
                return BibImportEntry(
                    id: entry.id,
                    citeKey: entry.citeKey,
                    entryType: entry.entryType,
                    title: entry.title,
                    authors: entry.authors,
                    year: entry.year,
                    isSelected: false,  // Deselect duplicates by default
                    isDuplicate: true,
                    existingPublicationID: existing.id,
                    rawContent: entry.rawContent
                )
            }

            return entry
        }
    }

    /// Import a single entry via BibTeX import into the Rust store.
    @discardableResult
    private func importEntry(_ entry: BibImportEntry, preview: BibImportPreview, to libraryID: UUID) throws -> [UUID] {
        // Build BibTeX string for the entry
        let bibtex: String
        if let rawContent = entry.rawContent, preview.format == .bibtex {
            bibtex = rawContent
        } else {
            // Construct minimal BibTeX from entry data
            var fields: [String] = []
            if let title = entry.title {
                fields.append("  title = {\(title)}")
            }
            if !entry.authors.isEmpty {
                fields.append("  author = {\(entry.authors.joined(separator: " and "))}")
            }
            if let year = entry.year {
                fields.append("  year = {\(year)}")
            }
            bibtex = "@\(entry.entryType){\(entry.citeKey),\n\(fields.joined(separator: ",\n"))\n}"
        }

        let importedIDs = store.importBibTeX(bibtex, libraryId: libraryID)
        if importedIDs.isEmpty {
            throw DragDropError.importFailed
        }
        return importedIDs
    }

    /// Parse authors from BibTeX author field.
    private func parseAuthors(_ authorField: String?) -> [String] {
        guard let authorField else { return [] }

        return authorField
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Parse year from BibTeX year field.
    private func parseYear(_ yearField: String?) -> Int? {
        guard let yearField else { return nil }

        // Extract 4-digit year
        let pattern = #"(19|20)\d{2}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: yearField, range: NSRange(yearField.startIndex..., in: yearField)),
           let range = Range(match.range, in: yearField) {
            return Int(yearField[range])
        }

        return Int(yearField)
    }

    /// Generate a cite key from RIS entry.
    private func generateCiteKeyFromRIS(_ entry: RISEntry) -> String {
        // Use reference ID if available
        if let refID = entry.referenceID, !refID.isEmpty {
            return refID
        }

        // Generate from author, year, title
        let authorPart: String
        if let firstAuthor = entry.authors.first {
            // Extract last name
            let parts = firstAuthor.components(separatedBy: ",")
            if let lastName = parts.first?.trimmingCharacters(in: .whitespaces) {
                authorPart = lastName
            } else {
                let nameParts = firstAuthor.components(separatedBy: " ")
                authorPart = nameParts.last ?? "Unknown"
            }
        } else {
            authorPart = "Unknown"
        }

        let yearPart = entry.year.map { String($0) } ?? "NoYear"

        let titlePart: String
        if let title = entry.title {
            let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !["the", "and", "for", "with", "from"].contains($0.lowercased()) }
            titlePart = words.first?.capitalized ?? "Paper"
        } else {
            titlePart = "Paper"
        }

        return "\(authorPart)\(yearPart)\(titlePart)"
    }
}
