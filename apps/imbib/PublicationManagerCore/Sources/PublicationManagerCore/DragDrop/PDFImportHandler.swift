//
//  PDFImportHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import OSLog

// MARK: - PDF Import Handler

/// Handles the workflow for importing PDFs as new publications.
///
/// Workflow:
/// 1. Extract metadata from PDF (title, author, DOI/arXiv)
/// 2. Enrich metadata via online sources (if identifier found)
/// 3. Check for duplicates
/// 4. Present preview to user
/// 5. Create publication and import PDF
@MainActor
@Observable
public final class PDFImportHandler {

    // MARK: - Singleton

    public static let shared = PDFImportHandler()

    // MARK: - Observable State

    /// Current previews being prepared
    public var previews: [PDFImportPreview] = []

    /// Whether preparation is in progress
    public var isPreparing = false

    /// Current item being processed
    public var currentItem: Int = 0

    /// Total items to process
    public var totalItems: Int = 0

    // MARK: - Dependencies

    private let metadataExtractor: PDFMetadataExtractor
    private let attachmentManager: AttachmentManager
    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    // MARK: - Initialization

    public init(
        metadataExtractor: PDFMetadataExtractor = .shared,
        attachmentManager: AttachmentManager = .shared
    ) {
        self.metadataExtractor = metadataExtractor
        self.attachmentManager = attachmentManager
    }

    // MARK: - Public Methods

    /// Prepare PDFs for import by extracting and enriching metadata.
    ///
    /// - Parameters:
    ///   - urls: URLs of PDF files to import
    ///   - target: The drop target (determines library/collection)
    /// - Returns: Array of import previews for user confirmation
    public func preparePDFImport(urls: [URL], target: DropTarget) async -> [PDFImportPreview] {
        Logger.files.infoCapture("Preparing \(urls.count) PDFs for import", category: "files")

        isPreparing = true
        previews = []
        totalItems = urls.count
        currentItem = 0

        defer {
            isPreparing = false
        }

        var results: [PDFImportPreview] = []

        for (index, url) in urls.enumerated() {
            currentItem = index + 1

            let preview = await prepareSinglePDF(url: url, target: target)
            results.append(preview)
            previews = results
        }

        return results
    }

    /// Commit a single PDF import.
    ///
    /// - Parameters:
    ///   - preview: The import preview to commit
    ///   - libraryID: Target library UUID
    /// - Returns: The UUID of the created/affected publication, or nil if skipped
    @discardableResult
    public func commitImport(_ preview: PDFImportPreview, to libraryID: UUID) async throws -> UUID? {
        Logger.files.infoCapture("Committing import for: \(preview.filename)", category: "files")

        guard store.getLibrary(id: libraryID) != nil else {
            throw DragDropError.libraryNotFound
        }

        switch preview.selectedAction {
        case .importAsNew:
            return try await createPublicationFromPreview(preview, libraryID: libraryID)

        case .attachToExisting:
            if let existingID = preview.existingPublication {
                try await attachToExistingPublication(preview, publicationID: existingID, libraryID: libraryID)
                return existingID
            } else {
                throw DragDropError.publicationNotFound
            }

        case .replace:
            if let existingID = preview.existingPublication {
                try await replaceExistingPublication(preview, publicationID: existingID, libraryID: libraryID)
                return existingID
            } else {
                throw DragDropError.publicationNotFound
            }

        case .skip:
            Logger.files.infoCapture("Skipping import: \(preview.filename)", category: "files")
            return nil
        }
    }

    // MARK: - Private Methods

    /// Prepare a single PDF for import.
    ///
    /// Enrichment cascade:
    /// 1. DOI -> Crossref DOI lookup (fetches full metadata)
    /// 2. arXiv ID -> arXiv API
    /// 3. Bibcode -> ADS API
    /// 4. Title -> Crossref title search (fallback when no identifiers)
    private func prepareSinglePDF(url: URL, target: DropTarget) async -> PDFImportPreview {
        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // Extract metadata from PDF
        let extractedMetadata = await metadataExtractor.extract(from: url)

        // Try to enrich via online sources using enrichment cascade
        var enrichedMetadata: EnrichedMetadata?

        if let doi = extractedMetadata?.extractedDOI {
            enrichedMetadata = await enrichFromCrossrefDOI(doi)
        }

        if enrichedMetadata == nil, let arxivID = extractedMetadata?.extractedArXivID {
            enrichedMetadata = await enrichFromArXiv(arxivID)
        }

        if enrichedMetadata == nil, let bibcode = extractedMetadata?.extractedBibcode {
            enrichedMetadata = await enrichFromADS(bibcode)
        }

        if enrichedMetadata == nil {
            let title = extractedMetadata?.heuristicTitle ?? extractedMetadata?.bestTitle
            let authors = extractedMetadata?.heuristicAuthors ?? []
            let year = extractedMetadata?.heuristicYear
            let firstPageText = extractedMetadata?.firstPageText

            if let title, title.count >= 20 {
                enrichedMetadata = await enrichFromADSSearch(
                    title: title,
                    authors: authors,
                    year: year,
                    abstract: firstPageText
                )
            }
        }

        if enrichedMetadata == nil {
            let title = extractedMetadata?.heuristicTitle ?? extractedMetadata?.bestTitle
            let authors = extractedMetadata?.heuristicAuthors ?? []
            if let title, title.count >= 20 {
                enrichedMetadata = await enrichFromTitleSearch(title, authors: authors)
            }
        }

        // Check for duplicates
        let (isDuplicate, existingID) = checkForDuplicate(
            doi: extractedMetadata?.extractedDOI ?? enrichedMetadata?.doi,
            arxivID: extractedMetadata?.extractedArXivID ?? enrichedMetadata?.arxivID,
            title: extractedMetadata?.bestTitle ?? enrichedMetadata?.title
        )

        let defaultAction: ImportAction
        if isDuplicate {
            defaultAction = .attachToExisting
        } else {
            defaultAction = .importAsNew
        }

        return PDFImportPreview(
            sourceURL: url,
            filename: filename,
            fileSize: fileSize,
            extractedMetadata: extractedMetadata,
            enrichedMetadata: enrichedMetadata,
            isDuplicate: isDuplicate,
            existingPublication: existingID,
            status: .ready,
            selectedAction: defaultAction
        )
    }

    /// Enrich metadata from DOI via Crossref API.
    public func enrichFromCrossrefDOI(_ doi: String) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Enriching from Crossref DOI: \(doi)", category: "files")

        do {
            let url = URL(string: "https://doi.org/\(doi)")!
            var request = URLRequest(url: url)
            request.setValue("application/x-bibtex", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                Logger.files.debugCapture("Crossref DOI lookup failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", category: "files")
                return nil
            }

            guard let bibtexString = String(data: data, encoding: .utf8) else {
                return nil
            }

            let parser = BibTeXParserFactory.createParser()
            let items = try parser.parse(bibtexString)

            guard let firstItem = items.first,
                  case .entry(let entry) = firstItem else {
                return EnrichedMetadata(doi: doi, source: "Crossref")
            }

            let title = entry.fields["title"]
            let authorsString = entry.fields["author"] ?? ""
            let authors = authorsString.components(separatedBy: " and ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let yearString = entry.fields["year"]
            let year = yearString.flatMap { Int($0) }
            let journal = entry.fields["journal"]
            let abstract = entry.fields["abstract"]

            return EnrichedMetadata(
                title: title,
                authors: authors,
                year: year,
                journal: journal,
                doi: doi,
                abstract: abstract,
                bibtex: bibtexString,
                source: "Crossref"
            )
        } catch {
            Logger.files.debugCapture("Crossref DOI lookup failed: \(error.localizedDescription)", category: "files")
        }

        return EnrichedMetadata(doi: doi, source: "DOI")
    }

    /// Enrich metadata from arXiv ID.
    public func enrichFromArXiv(_ arxivID: String) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Enriching from arXiv: \(arxivID)", category: "files")

        do {
            let arxiv = ArXivSource()
            let results = try await arxiv.search(query: arxivID)
            if let result = results.first {
                let bibtexEntry = try? await arxiv.fetchBibTeX(for: result)
                let bibtexString: String?
                if let entry = bibtexEntry {
                    bibtexString = entry.rawBibTeX ?? BibTeXExporter().export(entry)
                } else {
                    bibtexString = nil
                }
                return EnrichedMetadata(
                    title: result.title,
                    authors: result.authors,
                    year: result.year,
                    arxivID: arxivID,
                    abstract: result.abstract,
                    bibtex: bibtexString,
                    source: "arXiv"
                )
            }
        } catch {
            Logger.files.debugCapture("arXiv lookup failed: \(error.localizedDescription)", category: "files")
        }

        return nil
    }

    /// Enrich metadata from ADS bibcode.
    private func enrichFromADS(_ bibcode: String) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Enriching from ADS bibcode: \(bibcode)", category: "files")

        do {
            let ads = ADSSource()
            let results = try await ads.search(query: "bibcode:\(bibcode)")
            if let result = results.first {
                let bibtexEntry = try? await ads.fetchBibTeX(for: result)
                let bibtexString: String?
                if let entry = bibtexEntry {
                    bibtexString = entry.rawBibTeX ?? BibTeXExporter().export(entry)
                } else {
                    bibtexString = nil
                }
                return EnrichedMetadata(
                    title: result.title,
                    authors: result.authors,
                    year: result.year,
                    journal: result.venue,
                    doi: result.doi,
                    abstract: result.abstract,
                    bibtex: bibtexString,
                    source: "ADS"
                )
            }
        } catch {
            Logger.files.debugCapture("ADS lookup failed: \(error.localizedDescription)", category: "files")
        }

        return nil
    }

    /// Enrich metadata by searching ADS by title, author, and year.
    public func enrichFromADSSearch(
        title: String,
        authors: [String],
        year: Int?,
        abstract pdfText: String?
    ) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Searching ADS by title/author/year: \(title.prefix(50))...", category: "files")

        do {
            let ads = ADSSource()

            var queryParts: [String] = []

            let cleanTitle = title
                .replacingOccurrences(of: "\"", with: "")
                .prefix(150)
            queryParts.append("title:\"\(cleanTitle)\"")

            if let firstAuthor = authors.first {
                let lastName = extractLastName(from: firstAuthor)
                if !lastName.isEmpty {
                    queryParts.append("author:\"\(lastName)\"")
                }
            }

            if let year {
                queryParts.append("year:\(year)")
            }

            let query = queryParts.joined(separator: " ")
            Logger.files.debugCapture("ADS query: \(query)", category: "files")

            let results = try await ads.search(query: query, maxResults: 5)

            for result in results {
                let titleSimilarity = calculateTitleSimilarity(title, result.title)

                if titleSimilarity >= 0.90 {
                    Logger.files.debugCapture("ADS match (title: \(Int(titleSimilarity * 100))%): \(result.title.prefix(50))", category: "files")
                    return await buildEnrichedMetadata(from: result, using: ads, source: "ADS (title search)")
                }

                if titleSimilarity >= 0.70 {
                    if let pdfText, let resultAbstract = result.abstract {
                        let abstractSimilarity = calculateTextSimilarity(pdfText, resultAbstract)

                        if abstractSimilarity >= 0.50 {
                            Logger.files.debugCapture(
                                "ADS match (title: \(Int(titleSimilarity * 100))%, abstract: \(Int(abstractSimilarity * 100))%): \(result.title.prefix(50))",
                                category: "files"
                            )
                            return await buildEnrichedMetadata(from: result, using: ads, source: "ADS (title+abstract)")
                        }
                    }

                    if !authors.isEmpty && authorsOverlap(authors, result.authors) >= 0.5 {
                        Logger.files.debugCapture(
                            "ADS match (title: \(Int(titleSimilarity * 100))%, authors match): \(result.title.prefix(50))",
                            category: "files"
                        )
                        return await buildEnrichedMetadata(from: result, using: ads, source: "ADS (title+author)")
                    }
                }
            }

            Logger.files.debugCapture("No high-confidence ADS match found", category: "files")
        } catch SourceError.authenticationRequired {
            Logger.files.debugCapture("ADS search skipped: no API key configured", category: "files")
        } catch {
            Logger.files.debugCapture("ADS search failed: \(error.localizedDescription)", category: "files")
        }

        return nil
    }

    /// Build EnrichedMetadata from an ADS SearchResult.
    private func buildEnrichedMetadata(
        from result: SearchResult,
        using ads: ADSSource,
        source: String
    ) async -> EnrichedMetadata {
        let bibtexString: String?
        if let bibtexEntry = try? await ads.fetchBibTeX(for: result) {
            bibtexString = bibtexEntry.rawBibTeX ?? BibTeXExporter().export(bibtexEntry)
        } else {
            bibtexString = nil
        }

        return EnrichedMetadata(
            title: result.title,
            authors: result.authors,
            year: result.year,
            journal: result.venue,
            doi: result.doi,
            arxivID: result.arxivID,
            abstract: result.abstract,
            bibtex: bibtexString,
            source: source
        )
    }

    /// Extract last name from author string.
    private func extractLastName(from author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)

        if let commaIndex = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<commaIndex]).trimmingCharacters(in: .whitespaces)
        }

        let parts = trimmed.components(separatedBy: .whitespaces)
        return parts.last ?? trimmed
    }

    /// Calculate overlap between two author lists (0.0 to 1.0).
    private func authorsOverlap(_ authors1: [String], _ authors2: [String]) -> Double {
        guard !authors1.isEmpty && !authors2.isEmpty else { return 0 }

        let lastNames1 = Set(authors1.map { extractLastName(from: $0).lowercased() })
        let lastNames2 = Set(authors2.map { extractLastName(from: $0).lowercased() })

        let intersection = lastNames1.intersection(lastNames2).count
        let minCount = min(lastNames1.count, lastNames2.count)

        guard minCount > 0 else { return 0 }
        return Double(intersection) / Double(minCount)
    }

    /// Calculate text similarity using word overlap (Jaccard on significant words).
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let stopwords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
            "of", "with", "by", "from", "as", "is", "was", "are", "were", "been",
            "be", "have", "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "must", "shall", "can", "need",
            "we", "us", "our", "you", "your", "they", "them", "their", "it", "its",
            "this", "that", "these", "those", "which", "who", "whom", "whose"
        ]

        func extractWords(_ text: String) -> Set<String> {
            Set(
                text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 && !stopwords.contains($0) }
            )
        }

        let words1 = extractWords(text1)
        let words2 = extractWords(text2)

        guard !words1.isEmpty && !words2.isEmpty else { return 0 }

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Enrich metadata by searching Crossref by title.
    public func enrichFromTitleSearch(_ title: String, authors: [String]) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Searching Crossref by title: \(title.prefix(50))...", category: "files")

        do {
            let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
            let urlString = "https://api.crossref.org/works?query.title=\(encodedTitle)&rows=5"

            guard let url = URL(string: urlString) else {
                return nil
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("imbib/1.0 (mailto:support@imbib.app)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let items = message["items"] as? [[String: Any]] else {
                return nil
            }

            for item in items {
                guard let titles = item["title"] as? [String],
                      let resultTitle = titles.first else {
                    continue
                }

                let similarity = calculateTitleSimilarity(title, resultTitle)

                if similarity >= 0.85 {
                    let doi = item["DOI"] as? String
                    let resultAuthors = extractAuthorsFromCrossref(item)
                    let year = extractYearFromCrossref(item)
                    let journal = extractJournalFromCrossref(item)
                    let abstract = (item["abstract"] as? String)?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

                    Logger.files.debugCapture("Crossref title match: \(similarity * 100)% similarity", category: "files")

                    return EnrichedMetadata(
                        title: resultTitle,
                        authors: resultAuthors,
                        year: year,
                        journal: journal,
                        doi: doi,
                        abstract: abstract,
                        source: "Crossref (title search)"
                    )
                }
            }

            Logger.files.debugCapture("No high-confidence Crossref match for title", category: "files")
        } catch {
            Logger.files.debugCapture("Crossref title search failed: \(error.localizedDescription)", category: "files")
        }

        return nil
    }

    // MARK: - Crossref Helpers

    private func calculateTitleSimilarity(_ title1: String, _ title2: String) -> Double {
        let normalized1 = normalizeTitle(title1)
        let normalized2 = normalizeTitle(title2)

        let words1 = Set(normalized1.components(separatedBy: .whitespaces))
        let words2 = Set(normalized2.components(separatedBy: .whitespaces))

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func extractAuthorsFromCrossref(_ item: [String: Any]) -> [String] {
        guard let authors = item["author"] as? [[String: Any]] else {
            return []
        }

        return authors.compactMap { author -> String? in
            let family = author["family"] as? String ?? ""
            let given = author["given"] as? String ?? ""

            if !family.isEmpty && !given.isEmpty {
                return "\(family), \(given)"
            } else if !family.isEmpty {
                return family
            }
            return nil
        }
    }

    private func extractYearFromCrossref(_ item: [String: Any]) -> Int? {
        if let published = item["published-print"] as? [String: Any],
           let dateParts = published["date-parts"] as? [[Int]],
           let firstPart = dateParts.first,
           let year = firstPart.first {
            return year
        }

        if let published = item["published-online"] as? [String: Any],
           let dateParts = published["date-parts"] as? [[Int]],
           let firstPart = dateParts.first,
           let year = firstPart.first {
            return year
        }

        if let published = item["issued"] as? [String: Any],
           let dateParts = published["date-parts"] as? [[Int]],
           let firstPart = dateParts.first,
           let year = firstPart.first {
            return year
        }

        return nil
    }

    private func extractJournalFromCrossref(_ item: [String: Any]) -> String? {
        if let containerTitle = item["container-title"] as? [String] {
            return containerTitle.first
        }
        return nil
    }

    /// Check for duplicate publications via the Rust store.
    private func checkForDuplicate(doi: String?, arxivID: String?, title: String?) -> (isDuplicate: Bool, existingID: UUID?) {
        if let doi {
            let existing = store.findByDoi(doi: doi)
            if let first = existing.first {
                return (true, first.id)
            }
        }

        if let arxivID {
            let existing = store.findByArxiv(arxivId: arxivID)
            if let first = existing.first {
                return (true, first.id)
            }
        }

        if let title, !title.isEmpty {
            let results = store.searchPublications(query: title)
            let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            for existing in results.prefix(5) {
                let existingTitle = existing.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if existingTitle == normalizedTitle || existingTitle.contains(normalizedTitle) || normalizedTitle.contains(existingTitle) {
                    return (true, existing.id)
                }
            }
        }

        return (false, nil)
    }

    /// Create a new publication from preview via BibTeX import.
    @discardableResult
    private func createPublicationFromPreview(_ preview: PDFImportPreview, libraryID: UUID) async throws -> UUID {
        let bibtex: String
        if let enrichedBibtex = preview.enrichedMetadata?.bibtex {
            bibtex = enrichedBibtex
        } else {
            let citeKey = generateCiteKey(
                author: preview.effectiveAuthors.first,
                year: preview.effectiveYear,
                title: preview.effectiveTitle
            )
            let entryType = (preview.enrichedMetadata?.journal != nil) ? "article" : "misc"
            var fields: [String] = []
            if let title = preview.effectiveTitle {
                fields.append("  title = {\(title)}")
            }
            if !preview.effectiveAuthors.isEmpty {
                fields.append("  author = {\(preview.effectiveAuthors.joined(separator: " and "))}")
            }
            if let year = preview.effectiveYear {
                fields.append("  year = {\(year)}")
            }
            if let doi = preview.effectiveDOI {
                fields.append("  doi = {\(doi)}")
            }
            if let arxiv = preview.effectiveArXivID {
                fields.append("  eprint = {\(arxiv)}")
            }
            if let journal = preview.enrichedMetadata?.journal {
                fields.append("  journal = {\(journal)}")
            }
            if let abstract = preview.enrichedMetadata?.abstract ?? preview.extractedMetadata?.firstPageText?.prefix(500).description {
                let escaped = abstract.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
                fields.append("  abstract = {\(escaped)}")
            }
            bibtex = "@\(entryType){\(citeKey),\n\(fields.joined(separator: ",\n"))\n}"
        }

        let importedIDs = store.importBibTeX(bibtex, libraryId: libraryID)
        guard let newID = importedIDs.first else {
            throw DragDropError.importFailed
        }

        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: newID,
            in: libraryID
        )

        Logger.files.infoCapture("Created publication with PDF: \(newID)", category: "files")

        let pubID = newID
        let libID = libraryID
        Task.detached(priority: .utility) {
            await Self.processImportedPDF(
                linkedFileID: linkedFile.id,
                publicationID: pubID,
                libraryID: libID,
                sourceURL: preview.sourceURL
            )
        }

        return newID
    }

    /// Attach PDF to an existing publication.
    private func attachToExistingPublication(_ preview: PDFImportPreview, publicationID: UUID, libraryID: UUID) async throws {
        guard store.getPublication(id: publicationID) != nil else {
            throw DragDropError.publicationNotFound
        }

        store.movePublications(ids: [publicationID], toLibraryId: libraryID)

        let existingFiles = store.listLinkedFiles(publicationId: publicationID)
        let existingPDFs = existingFiles.filter { $0.isPDF }

        if !existingPDFs.isEmpty {
            if let duplicateResult = attachmentManager.checkForDuplicate(
                sourceURL: preview.sourceURL,
                in: publicationID
            ) {
                switch duplicateResult {
                case .duplicate(let existingFile, _):
                    Logger.files.infoCapture(
                        "Skipping duplicate PDF attachment: \(preview.filename) matches existing \(existingFile.filename)",
                        category: "files"
                    )
                    return

                case .noDuplicate(let precomputedHash):
                    let linkedFile = try attachmentManager.importAttachment(
                        from: preview.sourceURL,
                        for: publicationID,
                        in: libraryID,
                        precomputedHash: precomputedHash
                    )

                    Logger.files.infoCapture(
                        "Attached additional PDF to publication: \(publicationID) (now has \(existingPDFs.count + 1) PDFs)",
                        category: "files"
                    )

                    Task.detached(priority: .utility) {
                        await Self.processImportedPDF(
                            linkedFileID: linkedFile.id,
                            publicationID: publicationID,
                            libraryID: libraryID,
                            sourceURL: preview.sourceURL
                        )
                    }
                    return
                }
            }
        }

        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: publicationID,
            in: libraryID
        )

        Logger.files.infoCapture("Attached PDF to existing publication: \(publicationID)", category: "files")

        Task.detached(priority: .utility) {
            await Self.processImportedPDF(
                linkedFileID: linkedFile.id,
                publicationID: publicationID,
                libraryID: libraryID,
                sourceURL: preview.sourceURL
            )
        }
    }

    /// Replace existing publication's PDF.
    private func replaceExistingPublication(_ preview: PDFImportPreview, publicationID: UUID, libraryID: UUID) async throws {
        guard store.getPublication(id: publicationID) != nil else {
            throw DragDropError.publicationNotFound
        }

        let existingFiles = store.listLinkedFiles(publicationId: publicationID)
        for file in existingFiles where file.isPDF {
            await ThumbnailService.shared.removeCached(linkedFileId: file.id)
            try? attachmentManager.delete(file, in: libraryID)
        }

        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: publicationID,
            in: libraryID
        )

        Logger.files.infoCapture("Replaced PDF for publication: \(publicationID)", category: "files")

        Task.detached(priority: .utility) {
            await Self.processImportedPDF(
                linkedFileID: linkedFile.id,
                publicationID: publicationID,
                libraryID: libraryID,
                sourceURL: preview.sourceURL
            )
        }
    }

    private func generateCiteKey(author: String?, year: Int?, title: String?) -> String {
        let authorPart: String
        if let author {
            let parts = author.components(separatedBy: " ")
            authorPart = parts.last ?? "Unknown"
        } else {
            authorPart = "Unknown"
        }

        let yearPart = year.map { String($0) } ?? "NoYear"

        let titlePart: String
        if let title {
            let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !["the", "and", "for", "with"].contains($0.lowercased()) }
            titlePart = words.first?.capitalized ?? "Paper"
        } else {
            titlePart = "Paper"
        }

        return "\(authorPart)\(yearPart)\(titlePart)"
    }

    private func generateCiteKey(from filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        let sanitized = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()

        return sanitized.isEmpty ? "import\(UUID().uuidString.prefix(8))" : sanitized
    }

    // MARK: - Post-Import Processing

    private static func processImportedPDF(
        linkedFileID: UUID,
        publicationID: UUID,
        libraryID: UUID,
        sourceURL: URL
    ) async {
        Logger.files.info("Starting post-import processing for PDF")

        guard let pdfData = try? Data(contentsOf: sourceURL) else {
            Logger.files.warning("Could not read PDF data for post-import processing")
            return
        }

        await ThumbnailService.shared.generateThumbnail(
            from: pdfData,
            linkedFileId: linkedFileID
        )
        Logger.files.debug("Thumbnail generated for \(sourceURL.lastPathComponent)")

        await FullTextSearchService.shared.indexPublicationWithPDF(id: publicationID, pdfData: pdfData)
        Logger.files.debug("Full-text index updated for \(sourceURL.lastPathComponent)")

        Logger.files.info("Post-import processing complete for \(sourceURL.lastPathComponent)")
    }
}
