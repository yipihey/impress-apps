//
//  PDFImportHandler.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
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
    private let persistenceController: PersistenceController

    // MARK: - Initialization

    public init(
        metadataExtractor: PDFMetadataExtractor = .shared,
        attachmentManager: AttachmentManager = .shared,
        persistenceController: PersistenceController = .shared
    ) {
        self.metadataExtractor = metadataExtractor
        self.attachmentManager = attachmentManager
        self.persistenceController = persistenceController
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

        let context = persistenceController.viewContext

        // Fetch library
        let libraryRequest = NSFetchRequest<CDLibrary>(entityName: "Library")
        libraryRequest.predicate = NSPredicate(format: "id == %@", libraryID as CVarArg)
        libraryRequest.fetchLimit = 1

        guard let library = try? context.fetch(libraryRequest).first else {
            throw DragDropError.libraryNotFound
        }

        switch preview.selectedAction {
        case .importAsNew:
            return try await createPublicationFromPreview(preview, in: library)

        case .attachToExisting:
            if let existingID = preview.existingPublication {
                try await attachToExistingPublication(preview, publicationID: existingID, in: library)
                return existingID
            } else {
                throw DragDropError.publicationNotFound
            }

        case .replace:
            if let existingID = preview.existingPublication {
                try await replaceExistingPublication(preview, publicationID: existingID, in: library)
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
    /// 1. DOI → Crossref DOI lookup (fetches full metadata)
    /// 2. arXiv ID → arXiv API
    /// 3. Bibcode → ADS API
    /// 4. Title → Crossref title search (fallback when no identifiers)
    private func prepareSinglePDF(url: URL, target: DropTarget) async -> PDFImportPreview {
        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        // Extract metadata from PDF
        let extractedMetadata = await metadataExtractor.extract(from: url)

        // Try to enrich via online sources using enrichment cascade
        var enrichedMetadata: EnrichedMetadata?

        if let doi = extractedMetadata?.extractedDOI {
            // 1. DOI → Crossref DOI lookup (full metadata)
            enrichedMetadata = await enrichFromCrossrefDOI(doi)
        }

        if enrichedMetadata == nil, let arxivID = extractedMetadata?.extractedArXivID {
            // 2. arXiv ID → arXiv API
            enrichedMetadata = await enrichFromArXiv(arxivID)
        }

        if enrichedMetadata == nil, let bibcode = extractedMetadata?.extractedBibcode {
            // 3. Bibcode → ADS API
            enrichedMetadata = await enrichFromADS(bibcode)
        }

        if enrichedMetadata == nil {
            // 4. Title+Author+Year → ADS search (high precision for scientific papers)
            // ADS has powerful fuzzy matching and we can validate with abstract similarity
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
            // 5. Title → Crossref title search (final fallback)
            // Used when ADS search fails or no API key available
            let title = extractedMetadata?.heuristicTitle ?? extractedMetadata?.bestTitle
            let authors = extractedMetadata?.heuristicAuthors ?? []
            if let title, title.count >= 20 {
                enrichedMetadata = await enrichFromTitleSearch(title, authors: authors)
            }
        }

        // Check for duplicates
        let (isDuplicate, existingID) = await checkForDuplicate(
            doi: extractedMetadata?.extractedDOI ?? enrichedMetadata?.doi,
            arxivID: extractedMetadata?.extractedArXivID ?? enrichedMetadata?.arxivID,
            title: extractedMetadata?.bestTitle ?? enrichedMetadata?.title
        )

        // Determine default action
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
    ///
    /// Uses the Crossref API to fetch full metadata for a DOI.
    public func enrichFromCrossrefDOI(_ doi: String) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Enriching from Crossref DOI: \(doi)", category: "files")

        do {
            // Use DOI content negotiation to get BibTeX directly
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

            // Parse the BibTeX to extract fields
            let parser = BibTeXParserFactory.createParser()
            let items = try parser.parse(bibtexString)

            guard let firstItem = items.first,
                  case .entry(let entry) = firstItem else {
                // Still return basic metadata with DOI even if parsing fails
                return EnrichedMetadata(doi: doi, source: "Crossref")
            }

            // Extract metadata from BibTeX entry
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

        // Fallback: return basic metadata with DOI
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
                // Use rawBibTeX if available, otherwise export the entry
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
    ///
    /// ADS provides powerful search capabilities for scientific papers:
    /// - Fuzzy title matching
    /// - Author name normalization
    /// - Year filtering
    /// - Abstract text for similarity validation
    ///
    /// This is preferred over Crossref for physics/astronomy papers.
    ///
    /// - Parameters:
    ///   - title: Heuristically extracted title
    ///   - authors: Heuristically extracted authors (may be empty)
    ///   - year: Heuristically extracted year (may be nil)
    ///   - abstract: Abstract or first page text for similarity check (optional)
    /// - Returns: EnrichedMetadata if a high-confidence match is found
    public func enrichFromADSSearch(
        title: String,
        authors: [String],
        year: Int?,
        abstract pdfText: String?
    ) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Searching ADS by title/author/year: \(title.prefix(50))...", category: "files")

        do {
            let ads = ADSSource()

            // Build ADS query
            // ADS query syntax: title:"..." author:"..." year:YYYY
            var queryParts: [String] = []

            // Title search - use quotes for phrase matching
            // Escape quotes in title and limit length
            let cleanTitle = title
                .replacingOccurrences(of: "\"", with: "")
                .prefix(150)
            queryParts.append("title:\"\(cleanTitle)\"")

            // Add first author if available (most reliable)
            if let firstAuthor = authors.first {
                // Extract last name for author search
                let lastName = extractLastName(from: firstAuthor)
                if !lastName.isEmpty {
                    queryParts.append("author:\"\(lastName)\"")
                }
            }

            // Add year if available
            if let year {
                queryParts.append("year:\(year)")
            }

            let query = queryParts.joined(separator: " ")
            Logger.files.debugCapture("ADS query: \(query)", category: "files")

            let results = try await ads.search(query: query, maxResults: 5)

            // Find best match with validation
            for result in results {
                // Calculate title similarity
                let titleSimilarity = calculateTitleSimilarity(title, result.title)

                // If title similarity is very high (>90%), accept immediately
                if titleSimilarity >= 0.90 {
                    Logger.files.debugCapture("ADS match (title: \(Int(titleSimilarity * 100))%): \(result.title.prefix(50))", category: "files")
                    return await buildEnrichedMetadata(from: result, using: ads, source: "ADS (title search)")
                }

                // For moderate title similarity (70-90%), validate with abstract
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

                    // If no abstract to compare but authors match, accept
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
        // Try to fetch BibTeX for complete metadata
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
    ///
    /// Handles formats like:
    /// - "Einstein, Albert" → "Einstein"
    /// - "Albert Einstein" → "Einstein"
    private func extractLastName(from author: String) -> String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)

        // If comma-separated (LastName, FirstName), take first part
        if let commaIndex = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<commaIndex]).trimmingCharacters(in: .whitespaces)
        }

        // Otherwise assume last word is last name
        let parts = trimmed.components(separatedBy: .whitespaces)
        return parts.last ?? trimmed
    }

    /// Calculate overlap between two author lists (0.0 to 1.0).
    ///
    /// Uses last name matching to handle format variations.
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
    ///
    /// Filters out common stopwords for better comparison.
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
    ///
    /// Searches Crossref works API with the title and validates against authors.
    /// Only returns a match if confidence is high enough (title similarity > 85%).
    public func enrichFromTitleSearch(_ title: String, authors: [String]) async -> EnrichedMetadata? {
        Logger.files.infoCapture("Searching Crossref by title: \(title.prefix(50))...", category: "files")

        do {
            // Crossref works API query
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

            // Parse JSON response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let items = message["items"] as? [[String: Any]] else {
                return nil
            }

            // Find best match
            for item in items {
                guard let titles = item["title"] as? [String],
                      let resultTitle = titles.first else {
                    continue
                }

                // Calculate title similarity
                let similarity = calculateTitleSimilarity(title, resultTitle)

                if similarity >= 0.85 {
                    // Good match - extract metadata
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

    /// Calculate similarity between two titles (0.0 to 1.0).
    private func calculateTitleSimilarity(_ title1: String, _ title2: String) -> Double {
        let normalized1 = normalizeTitle(title1)
        let normalized2 = normalizeTitle(title2)

        // Simple Jaccard similarity on words
        let words1 = Set(normalized1.components(separatedBy: .whitespaces))
        let words2 = Set(normalized2.components(separatedBy: .whitespaces))

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count

        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Normalize title for comparison.
    private func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Extract authors from Crossref item.
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

    /// Extract year from Crossref item.
    private func extractYearFromCrossref(_ item: [String: Any]) -> Int? {
        // Try published-print first, then published-online
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

    /// Extract journal from Crossref item.
    private func extractJournalFromCrossref(_ item: [String: Any]) -> String? {
        if let containerTitle = item["container-title"] as? [String] {
            return containerTitle.first
        }
        return nil
    }

    /// Check for duplicate publications.
    private func checkForDuplicate(doi: String?, arxivID: String?, title: String?) async -> (isDuplicate: Bool, existingID: UUID?) {
        let context = persistenceController.viewContext

        // Check by DOI
        if let doi {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "doi == %@", doi)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                return (true, existing.id)
            }
        }

        // Check by arXiv ID
        if let arxivID {
            let normalizedID = IdentifierExtractor.normalizeArXivID(arxivID)
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Check the normalized arXiv ID field (arxivID is a computed property, not a Core Data attribute)
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "arxivIDNormalized == %@", normalizedID),
                NSPredicate(format: "arxivIDNormalized == %@", arxivID),
            ])
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                return (true, existing.id)
            }
        }

        // Fuzzy match by title (last resort)
        if let title, !title.isEmpty {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            // Case-insensitive contains match
            request.predicate = NSPredicate(format: "title CONTAINS[cd] %@", title)
            request.fetchLimit = 5

            if let results = try? context.fetch(request) {
                // Check for close title match
                let normalizedTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                for existing in results {
                    let existingTitle = (existing.title ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if existingTitle == normalizedTitle || existingTitle.contains(normalizedTitle) || normalizedTitle.contains(existingTitle) {
                        return (true, existing.id)
                    }
                }
            }
        }

        return (false, nil)
    }

    /// Create a new publication from preview.
    /// - Returns: The UUID of the created publication
    @discardableResult
    private func createPublicationFromPreview(_ preview: PDFImportPreview, in library: CDLibrary) async throws -> UUID {
        let context = persistenceController.viewContext

        // Create publication
        let publication = CDPublication(context: context)
        let newID = UUID()
        publication.id = newID
        publication.dateAdded = Date()
        publication.dateModified = Date()

        // Use enriched metadata if available, fall back to extracted
        if let enriched = preview.enrichedMetadata {
            publication.title = enriched.title
            publication.year = Int16(enriched.year ?? 0)
            publication.doi = enriched.doi
            // arxivID is computed from fields["eprint"], set the field directly
            if let arxiv = enriched.arxivID {
                publication.fields["eprint"] = arxiv
            }

            // Set entry type and journal if available
            if let journal = enriched.journal {
                publication.fields["journal"] = journal
                publication.entryType = "article"
            } else {
                publication.entryType = "misc"
            }

            // Set authors
            if !enriched.authors.isEmpty {
                publication.fields["author"] = enriched.authors.joined(separator: " and ")
            }

            // Set abstract
            if let abstract = enriched.abstract {
                publication.fields["abstract"] = abstract
            }

            // Generate cite key
            publication.citeKey = generateCiteKey(
                author: enriched.authors.first,
                year: enriched.year,
                title: enriched.title
            )
        } else if let extracted = preview.extractedMetadata {
            publication.title = extracted.bestTitle ?? preview.filename
            publication.doi = extracted.extractedDOI
            // arxivID is computed from fields["eprint"], set the field directly
            if let arxiv = extracted.extractedArXivID {
                publication.fields["eprint"] = arxiv
            }
            publication.entryType = "misc"

            // Generate cite key from filename if no metadata
            publication.citeKey = generateCiteKey(from: preview.filename)
        } else {
            // No metadata - use filename
            publication.title = preview.filename
            publication.entryType = "misc"
            publication.citeKey = generateCiteKey(from: preview.filename)
        }

        // Add to library
        publication.addToLibrary(library)

        // Save first to get a valid publication
        try context.save()

        // Import the PDF
        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: publication,
            in: library
        )

        // Save again with PDF link
        try context.save()

        Logger.files.infoCapture("Created publication: \(publication.citeKey) with PDF", category: "files")

        // Post-import processing: thumbnail generation and text extraction for search indexing
        // Run asynchronously to not block the import UI
        let pubID = publication.id
        let libID = library.id
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
    ///
    /// Checks if the PDF is already attached (by SHA256 hash) before importing.
    /// Skips attachment if an identical file already exists, but still adds the
    /// publication to the target library if not already there.
    private func attachToExistingPublication(_ preview: PDFImportPreview, publicationID: UUID, in library: CDLibrary) async throws {
        let context = persistenceController.viewContext

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first else {
            throw DragDropError.publicationNotFound
        }

        // Ensure publication is in the target library (it may exist in a different library)
        let isInTargetLibrary = publication.libraries?.contains(library) ?? false
        if !isInTargetLibrary {
            publication.addToLibrary(library)
            Logger.files.infoCapture(
                "Added existing publication '\(publication.citeKey)' to library '\(library.displayName)'",
                category: "files"
            )
        }

        // Check if this PDF is already attached (by hash comparison)
        let existingPDFs = (publication.linkedFiles ?? []).filter { $0.isPDF }

        if !existingPDFs.isEmpty {
            // Use AttachmentManager's duplicate detection
            if let duplicateResult = attachmentManager.checkForDuplicate(
                sourceURL: preview.sourceURL,
                in: publication
            ) {
                switch duplicateResult {
                case .duplicate(let existingFile, _):
                    Logger.files.infoCapture(
                        "Skipping duplicate PDF attachment: \(preview.filename) matches existing \(existingFile.filename)",
                        category: "files"
                    )
                    // Already attached - save any library changes and return
                    try context.save()
                    return

                case .noDuplicate(let precomputedHash):
                    // Different PDF - proceed with attachment using precomputed hash
                    let linkedFile = try attachmentManager.importAttachment(
                        from: preview.sourceURL,
                        for: publication,
                        in: library,
                        precomputedHash: precomputedHash
                    )

                    try context.save()

                    Logger.files.infoCapture(
                        "Attached additional PDF to publication: \(publication.citeKey) (now has \(existingPDFs.count + 1) PDFs)",
                        category: "files"
                    )

                    // Post-import processing
                    let libID = library.id
                    Task.detached(priority: .utility) {
                        await Self.processImportedPDF(
                            linkedFileID: linkedFile.id,
                            publicationID: publicationID,
                            libraryID: libID,
                            sourceURL: preview.sourceURL
                        )
                    }
                    return
                }
            }
        }

        // No existing PDFs - just import
        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: publication,
            in: library
        )

        try context.save()

        Logger.files.infoCapture("Attached PDF to existing publication: \(publication.citeKey)", category: "files")

        // Post-import processing
        let libID = library.id
        Task.detached(priority: .utility) {
            await Self.processImportedPDF(
                linkedFileID: linkedFile.id,
                publicationID: publicationID,
                libraryID: libID,
                sourceURL: preview.sourceURL
            )
        }
    }

    /// Replace existing publication's PDF.
    private func replaceExistingPublication(_ preview: PDFImportPreview, publicationID: UUID, in library: CDLibrary) async throws {
        let context = persistenceController.viewContext

        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
        request.fetchLimit = 1

        guard let publication = try? context.fetch(request).first else {
            throw DragDropError.publicationNotFound
        }

        // Delete existing PDFs and their cached thumbnails
        if let linkedFiles = publication.linkedFiles {
            for file in linkedFiles where file.fileType == "pdf" {
                await ThumbnailService.shared.removeCached(linkedFileId: file.id)
                try? attachmentManager.delete(file, in: library)
            }
        }

        // Import new PDF
        let linkedFile = try attachmentManager.importPDF(
            from: preview.sourceURL,
            for: publication,
            in: library
        )

        try context.save()

        Logger.files.infoCapture("Replaced PDF for publication: \(publication.citeKey)", category: "files")

        // Post-import processing
        let libID = library.id
        Task.detached(priority: .utility) {
            await Self.processImportedPDF(
                linkedFileID: linkedFile.id,
                publicationID: publicationID,
                libraryID: libID,
                sourceURL: preview.sourceURL
            )
        }
    }

    /// Generate a cite key from author, year, and title.
    private func generateCiteKey(author: String?, year: Int?, title: String?) -> String {
        let authorPart: String
        if let author {
            // Extract last name
            let parts = author.components(separatedBy: " ")
            authorPart = parts.last ?? "Unknown"
        } else {
            authorPart = "Unknown"
        }

        let yearPart = year.map { String($0) } ?? "NoYear"

        let titlePart: String
        if let title {
            // Extract first significant word
            let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !["the", "and", "for", "with"].contains($0.lowercased()) }
            titlePart = words.first?.capitalized ?? "Paper"
        } else {
            titlePart = "Paper"
        }

        return "\(authorPart)\(yearPart)\(titlePart)"
    }

    /// Generate a cite key from a filename.
    private func generateCiteKey(from filename: String) -> String {
        // Remove extension and sanitize
        let name = (filename as NSString).deletingPathExtension
        let sanitized = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()

        return sanitized.isEmpty ? "import\(UUID().uuidString.prefix(8))" : sanitized
    }

    // MARK: - Post-Import Processing

    /// Process an imported PDF for thumbnail generation and text extraction.
    ///
    /// This runs asynchronously after import to:
    /// 1. Generate and cache a thumbnail using pdfium
    /// 2. Extract text for full-text search indexing
    ///
    /// - Parameters:
    ///   - linkedFileID: ID of the imported linked file
    ///   - publicationID: ID of the publication
    ///   - libraryID: ID of the library
    ///   - sourceURL: Original source URL of the PDF
    private static func processImportedPDF(
        linkedFileID: UUID,
        publicationID: UUID,
        libraryID: UUID,
        sourceURL: URL
    ) async {
        Logger.files.info("Starting post-import processing for PDF")

        // Read PDF data for processing
        guard let pdfData = try? Data(contentsOf: sourceURL) else {
            Logger.files.warning("Could not read PDF data for post-import processing")
            return
        }

        // Generate thumbnail (async, cached to disk)
        await ThumbnailService.shared.generateThumbnail(
            from: pdfData,
            linkedFileId: linkedFileID
        )
        Logger.files.debug("Thumbnail generated for \(sourceURL.lastPathComponent)")

        // Extract text and update search index
        let context = PersistenceController.shared.viewContext
        let publication: CDPublication? = await MainActor.run {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id == %@", publicationID as CVarArg)
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }

        if let pub = publication {
            await FullTextSearchService.shared.indexPublicationWithPDF(pub, pdfData: pdfData)
            Logger.files.debug("Full-text index updated for \(sourceURL.lastPathComponent)")
        }

        Logger.files.info("Post-import processing complete for \(sourceURL.lastPathComponent)")
    }
}
