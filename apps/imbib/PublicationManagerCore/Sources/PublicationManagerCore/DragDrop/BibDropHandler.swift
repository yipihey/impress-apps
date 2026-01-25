//
//  BibDropHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
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
public final class BibDropHandler: ObservableObject {

    // MARK: - Singleton

    public static let shared = BibDropHandler()

    // MARK: - Published State

    /// Current preview being prepared
    @Published public var currentPreview: BibImportPreview?

    /// Whether preparation is in progress
    @Published public var isPreparing = false

    // MARK: - Dependencies

    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
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
        let checkedEntries = await checkDuplicates(entries)

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
    public func commitImport(_ preview: BibImportPreview, to libraryID: UUID) async throws {
        Logger.files.infoCapture("Committing bib import: \(preview.entries.filter { $0.isSelected }.count) entries", category: "files")

        let context = persistenceController.viewContext

        // Fetch library
        let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
        libraryRequest.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
        libraryRequest.fetchLimit = 1

        guard let library = try? context.fetch(libraryRequest).first else {
            throw DragDropError.libraryNotFound
        }

        // Import selected entries
        var imported = 0
        for entry in preview.entries where entry.isSelected {
            if entry.isDuplicate {
                // Skip duplicates unless explicitly enabled
                continue
            }

            do {
                try await importEntry(entry, preview: preview, to: library)
                imported += 1
            } catch {
                Logger.files.errorCapture("Failed to import \(entry.citeKey): \(error.localizedDescription)", category: "files")
            }
        }

        try context.save()
        currentPreview = nil

        Logger.files.infoCapture("Imported \(imported) entries from \(preview.sourceURL.lastPathComponent)", category: "files")
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

    /// Check entries for duplicates.
    private func checkDuplicates(_ entries: [BibImportEntry]) async -> [BibImportEntry] {
        let context = persistenceController.viewContext

        return entries.map { entry in
            var checked = entry

            // Check by cite key
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", entry.citeKey)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                checked = BibImportEntry(
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

            return checked
        }
    }

    /// Import a single entry.
    private func importEntry(_ entry: BibImportEntry, preview: BibImportPreview, to library: CDLibrary) async throws {
        let context = persistenceController.viewContext

        // Create publication
        let publication = CDPublication(context: context)
        publication.id = UUID()
        publication.citeKey = entry.citeKey
        publication.entryType = entry.entryType
        publication.title = entry.title
        publication.year = Int16(entry.year ?? 0)
        publication.dateAdded = Date()
        publication.dateModified = Date()

        // Set authors
        if !entry.authors.isEmpty {
            publication.fields["author"] = entry.authors.joined(separator: " and ")
        }

        // Store raw content for round-trip
        publication.rawBibTeX = entry.rawContent

        // Add to library
        publication.addToLibrary(library)

        // Parse full entry if we have raw content for additional fields
        if let rawContent = entry.rawContent, preview.format == .bibtex {
            try? parseBibTeXFields(rawContent, into: publication)
        }
    }

    /// Parse additional fields from raw BibTeX.
    private func parseBibTeXFields(_ rawBibTeX: String, into publication: CDPublication) throws {
        let parser = BibTeXParserFactory.createParser()
        let items = try parser.parse(rawBibTeX)

        guard case .entry(let entry) = items.first else {
            return
        }

        // Copy all fields
        for (key, value) in entry.fields {
            // Skip fields we've already set
            if key == "author" { continue }

            publication.fields[key] = value

            // Extract special fields
            switch key.lowercased() {
            case "doi":
                publication.doi = value
            case "eprint", "arxivid", "arxiv":
                // arxivID is computed from fields["eprint"], set the field directly
                publication.fields["eprint"] = value
            case "journal":
                publication.fields["journal"] = value
            case "abstract":
                publication.fields["abstract"] = value
            default:
                break
            }
        }
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
