//
//  CoreDataPublicationStore.swift
//  PublicationManagerCore
//
//  Core Data implementation of PublicationStore.
//

import Foundation
import CoreData
import ImbibRustCore

/// Core Data implementation of PublicationStore
public actor CoreDataPublicationStore: PublicationStore {
    private let persistenceController: PersistenceController
    private let changeSubject: (stream: AsyncStream<StoreChange>, continuation: AsyncStream<StoreChange>.Continuation)

    public init(persistenceController: PersistenceController) {
        self.persistenceController = persistenceController
        self.changeSubject = AsyncStream<StoreChange>.makeStream()
    }

    public func fetchAll(in library: String?) async throws -> [Publication] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")

            if let libraryId = library, let uuid = UUID(uuidString: libraryId) {
                request.predicate = NSPredicate(format: "ANY libraries.id == %@", uuid as CVarArg)
            }

            guard let cdPublications = try? context.fetch(request) else {
                return []
            }
            return cdPublications.map { $0.toRustPublication() }
        }
    }

    public func fetch(id: String) async throws -> Publication? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1

            return try? context.fetch(request).first?.toRustPublication()
        }
    }

    public func fetch(byCiteKey citeKey: String, in library: String?) async throws -> Publication? {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")

            if let libraryId = library, let uuid = UUID(uuidString: libraryId) {
                request.predicate = NSPredicate(
                    format: "citeKey == %@ AND ANY libraries.id == %@",
                    citeKey, uuid as CVarArg
                )
            } else {
                request.predicate = NSPredicate(format: "citeKey == %@", citeKey)
            }
            request.fetchLimit = 1

            return try? context.fetch(request).first?.toRustPublication()
        }
    }

    public func search(query: String) async throws -> [Publication] {
        let context = persistenceController.viewContext

        return await context.perform {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(
                format: "title CONTAINS[cd] %@ OR citeKey CONTAINS[cd] %@",
                query, query
            )

            guard let cdPublications = try? context.fetch(request) else {
                return []
            }
            return cdPublications.map { $0.toRustPublication() }
        }
    }

    public func save(_ publication: Publication) async throws {
        let context = persistenceController.viewContext

        try await context.perform {
            let cdPublication: CDPublication
            if let uuid = UUID(uuidString: publication.id),
               let existing = try self.fetchCDPublication(id: uuid, in: context) {
                cdPublication = existing
            } else {
                cdPublication = CDPublication(context: context)
                cdPublication.id = UUID(uuidString: publication.id) ?? UUID()
                cdPublication.dateAdded = Date()
            }

            cdPublication.update(from: publication)
            try context.save()
        }

        changeSubject.continuation.yield(.updated([publication.id]))
    }

    public func delete(id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { return }
        let context = persistenceController.viewContext

        try await context.perform {
            if let cdPublication = try self.fetchCDPublication(id: uuid, in: context) {
                context.delete(cdPublication)
                try context.save()
            }
        }

        changeSubject.continuation.yield(.deleted([id]))
    }

    public func batchImport(_ publications: [Publication]) async throws {
        let context = persistenceController.viewContext
        var insertedIds: [String] = []

        try await context.perform {
            for publication in publications {
                let cdPublication = CDPublication(context: context)
                cdPublication.id = UUID(uuidString: publication.id) ?? UUID()
                cdPublication.dateAdded = Date()
                cdPublication.update(from: publication)
                insertedIds.append(publication.id)
            }

            try context.save()
        }

        changeSubject.continuation.yield(.inserted(insertedIds))
    }

    public nonisolated func changes() -> AsyncStream<StoreChange> {
        changeSubject.stream
    }

    private func fetchCDPublication(id: UUID, in context: NSManagedObjectContext) throws -> CDPublication? {
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

// MARK: - CDPublication Extensions

extension CDPublication {
    func toRustPublication() -> Publication {
        let identifiers = Identifiers(
            doi: self.doi,
            arxivId: self.arxivIDNormalized,
            pmid: nil,
            pmcid: nil,
            bibcode: self.bibcodeNormalized,
            isbn: nil,
            issn: nil,
            orcid: nil
        )

        let authors: [Author] = (self.publicationAuthors as? Set<CDPublicationAuthor>)?
            .sorted { $0.order < $1.order }
            .compactMap { pubAuthor -> Author? in
                guard let author = pubAuthor.author else { return nil }
                return Author(
                    id: author.id.uuidString,
                    givenName: author.givenName,
                    familyName: author.familyName,
                    suffix: author.nameSuffix,
                    orcid: nil,
                    affiliation: nil
                )
            } ?? []

        let linkedFiles: [LinkedFile] = (self.linkedFiles as? Set<CDLinkedFile>)?
            .map { file in
                LinkedFile(
                    id: file.id.uuidString,
                    filename: file.filename,
                    relativePath: file.relativePath,
                    absoluteUrl: nil,
                    storageType: .local,
                    mimeType: file.mimeType ?? "application/pdf",
                    fileSize: file.fileSize > 0 ? Int64(file.fileSize) : nil,
                    checksum: file.sha256,
                    addedAt: file.dateAdded.ISO8601Format()
                )
            } ?? []

        let tagNames: [String] = (self.tags as? Set<CDTag>)?.map { $0.name } ?? []
        let collectionIds: [String] = (self.collections as? Set<CDCollection>)?.map { $0.id.uuidString } ?? []

        // Parse extra fields from rawFields JSON
        var extraFields: [String: String] = [:]
        if let rawFieldsString = self.rawFields,
           let data = rawFieldsString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            extraFields = decoded
        }

        return Publication(
            id: self.id.uuidString,
            citeKey: self.citeKey,
            entryType: self.entryType,
            title: self.title ?? "",
            year: self.year != 0 ? Int32(self.year) : nil,
            month: extraFields["month"],
            authors: authors,
            editors: [],
            journal: extraFields["journal"],
            booktitle: extraFields["booktitle"],
            publisher: extraFields["publisher"],
            volume: extraFields["volume"],
            number: extraFields["number"],
            pages: extraFields["pages"],
            edition: extraFields["edition"],
            series: extraFields["series"],
            address: extraFields["address"],
            chapter: extraFields["chapter"],
            howpublished: extraFields["howpublished"],
            institution: extraFields["institution"],
            organization: extraFields["organization"],
            school: extraFields["school"],
            note: extraFields["note"],
            abstractText: self.abstract,
            keywords: (extraFields["keywords"] ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            url: self.url,
            eprint: extraFields["eprint"],
            primaryClass: extraFields["primaryclass"],
            archivePrefix: extraFields["archiveprefix"],
            identifiers: identifiers,
            extraFields: extraFields,
            linkedFiles: linkedFiles,
            tags: tagNames,
            collections: collectionIds,
            libraryId: (self.libraries as? Set<CDLibrary>)?.first?.id.uuidString,
            createdAt: self.dateAdded.ISO8601Format(),
            modifiedAt: self.dateModified.ISO8601Format(),
            sourceId: self.originalSourceID,
            citationCount: self.citationCount >= 0 ? Int32(self.citationCount) : nil,
            referenceCount: self.referenceCount >= 0 ? Int32(self.referenceCount) : nil,
            enrichmentSource: self.enrichmentSource,
            enrichmentDate: self.enrichmentDate?.ISO8601Format(),
            rawBibtex: self.rawBibTeX,
            rawRis: nil
        )
    }

    func update(from publication: Publication) {
        self.citeKey = publication.citeKey
        self.entryType = publication.entryType
        self.title = publication.title
        self.year = Int16(publication.year ?? 0)
        self.doi = publication.identifiers.doi
        self.arxivIDNormalized = publication.identifiers.arxivId
        self.bibcodeNormalized = publication.identifiers.bibcode
        self.abstract = publication.abstractText
        self.url = publication.url
        self.rawBibTeX = publication.rawBibtex
        self.originalSourceID = publication.sourceId
        self.citationCount = Int32(publication.citationCount ?? -1)
        self.referenceCount = Int32(publication.referenceCount ?? -1)
        self.enrichmentSource = publication.enrichmentSource
        self.dateModified = Date()

        // Store extra fields as JSON
        var rawFields = publication.extraFields
        if let journal = publication.journal { rawFields["journal"] = journal }
        if let volume = publication.volume { rawFields["volume"] = volume }
        if let number = publication.number { rawFields["number"] = number }
        if let pages = publication.pages { rawFields["pages"] = pages }
        if let publisher = publication.publisher { rawFields["publisher"] = publisher }
        if let booktitle = publication.booktitle { rawFields["booktitle"] = booktitle }
        if let edition = publication.edition { rawFields["edition"] = edition }
        if let series = publication.series { rawFields["series"] = series }
        if let address = publication.address { rawFields["address"] = address }
        if let chapter = publication.chapter { rawFields["chapter"] = chapter }
        if let howpublished = publication.howpublished { rawFields["howpublished"] = howpublished }
        if let institution = publication.institution { rawFields["institution"] = institution }
        if let organization = publication.organization { rawFields["organization"] = organization }
        if let school = publication.school { rawFields["school"] = school }
        if let note = publication.note { rawFields["note"] = note }
        if let month = publication.month { rawFields["month"] = month }
        if let eprint = publication.eprint { rawFields["eprint"] = eprint }
        if let primaryClass = publication.primaryClass { rawFields["primaryclass"] = primaryClass }
        if let archivePrefix = publication.archivePrefix { rawFields["archiveprefix"] = archivePrefix }
        if !publication.keywords.isEmpty {
            rawFields["keywords"] = publication.keywords.joined(separator: ", ")
        }

        if let data = try? JSONEncoder().encode(rawFields),
           let jsonString = String(data: data, encoding: .utf8) {
            self.rawFields = jsonString
        }
    }
}
