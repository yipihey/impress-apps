//
//  FieldMerger.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
import OSLog

// MARK: - Field Timestamps

/// Helper for managing field-level timestamps for conflict resolution (ADR-007)
public struct FieldTimestamps: Codable, Sendable, Equatable {
    public var timestamps: [String: Date]

    public init(timestamps: [String: Date] = [:]) {
        self.timestamps = timestamps
    }

    public subscript(field: String) -> Date? {
        get { timestamps[field] }
        set { timestamps[field] = newValue }
    }

    /// Update timestamp for a field to now
    public mutating func touch(_ field: String) {
        timestamps[field] = Date()
    }

    /// Update timestamps for multiple fields to now
    public mutating func touchAll(_ fields: [String]) {
        let now = Date()
        for field in fields {
            timestamps[field] = now
        }
    }
}

// MARK: - CDPublication Extensions for Timestamps

public extension CDPublication {

    /// Decode field timestamps from JSON
    var decodedFieldTimestamps: FieldTimestamps {
        guard let json = fieldTimestamps,
              let data = json.data(using: .utf8),
              let timestamps = try? JSONDecoder().decode(FieldTimestamps.self, from: data) else {
            return FieldTimestamps()
        }
        return timestamps
    }

    /// Encode and save field timestamps
    func setFieldTimestamps(_ timestamps: FieldTimestamps) {
        if let data = try? JSONEncoder().encode(timestamps),
           let json = String(data: data, encoding: .utf8) {
            fieldTimestamps = json
        }
    }

    /// Update timestamp for a specific field
    func touchFieldTimestamp(_ field: String) {
        var timestamps = decodedFieldTimestamps
        timestamps.touch(field)
        setFieldTimestamps(timestamps)
    }

    /// List of scalar fields that use last-writer-wins merge
    static var scalarFields: [String] {
        ["title", "year", "abstract", "doi", "url", "entryType", "rawBibTeX", "rawFields",
         "citationCount", "referenceCount", "enrichmentSource", "enrichmentDate",
         "originalSourceID", "pdfLinksJSON", "webURL", "semanticScholarID", "openAlexID",
         "arxivIDNormalized", "bibcodeNormalized", "isRead", "dateRead", "isStarred",
         "hasPDFDownloaded", "pdfDownloadDate", "dateAddedToInbox"]
    }
}

// MARK: - Field Merger

/// Merges publication fields using field-level timestamps (ADR-007)
public actor FieldMerger {

    public static let shared = FieldMerger()

    private init() {}

    /// Merge scalar fields using field-level timestamps.
    /// Returns the merged values as a dictionary of field name to value.
    public func mergeScalarFields(
        local: CDPublication,
        remote: CDPublication,
        ancestor: CDPublication? = nil
    ) -> [String: Any] {
        let localTimestamps = local.decodedFieldTimestamps
        let remoteTimestamps = remote.decodedFieldTimestamps

        var mergedValues: [String: Any] = [:]

        for field in CDPublication.scalarFields {
            let localTime = localTimestamps[field] ?? .distantPast
            let remoteTime = remoteTimestamps[field] ?? .distantPast

            // Remote wins if it has a more recent timestamp
            if remoteTime > localTime {
                if let value = remote.value(forKey: field) {
                    mergedValues[field] = value
                }
            } else {
                // Local wins (or equal timestamps)
                if let value = local.value(forKey: field) {
                    mergedValues[field] = value
                }
            }
        }

        return mergedValues
    }

    /// Apply merged values to a publication
    public func applyMergedValues(
        _ values: [String: Any],
        to publication: CDPublication
    ) {
        for (field, value) in values {
            publication.setValue(value, forKey: field)
        }
        publication.dateModified = Date()
    }

    /// Merge authors using 3-way merge (if ancestor available) or union merge
    public func mergeAuthors(
        local: Set<CDPublicationAuthor>,
        remote: Set<CDPublicationAuthor>,
        ancestor: Set<CDPublicationAuthor>? = nil
    ) -> Set<CDPublicationAuthor> {
        // For authors, we use a simplified union merge based on author identity
        // In practice, author entities are deduplicated by name

        if let ancestor = ancestor {
            // 3-way merge
            let localAuthors = Set(local.compactMap { $0.author })
            let remoteAuthors = Set(remote.compactMap { $0.author })
            let ancestorAuthors = Set(ancestor.compactMap { $0.author })

            let localAdded = localAuthors.subtracting(ancestorAuthors)
            let remoteAdded = remoteAuthors.subtracting(ancestorAuthors)
            let localRemoved = ancestorAuthors.subtracting(localAuthors)
            let remoteRemoved = ancestorAuthors.subtracting(remoteAuthors)

            var result = ancestorAuthors
            result.formUnion(localAdded)
            result.formUnion(remoteAdded)
            result.subtract(localRemoved)
            result.subtract(remoteRemoved)

            // Return the CDPublicationAuthor objects that correspond to merged authors
            let allPAs = local.union(remote)
            return allPAs.filter { pa in
                guard let author = pa.author else { return false }
                return result.contains(author)
            }
        }

        // Without ancestor, simple union merge
        return local.union(remote)
    }

    /// Merge tags using union merge (non-destructive)
    public func mergeTags(
        local: Set<CDTag>,
        remote: Set<CDTag>
    ) -> Set<CDTag> {
        // Simple union - if either device has the tag, keep it
        local.union(remote)
    }

    /// Merge collections using union merge
    public func mergeCollections(
        local: Set<CDCollection>,
        remote: Set<CDCollection>
    ) -> Set<CDCollection> {
        local.union(remote)
    }

    /// Merge libraries using union merge
    public func mergeLibraries(
        local: Set<CDLibrary>,
        remote: Set<CDLibrary>
    ) -> Set<CDLibrary> {
        local.union(remote)
    }

    /// Perform a full merge of two publications
    public func merge(
        local: CDPublication,
        remote: CDPublication,
        context: NSManagedObjectContext
    ) -> MergeResult {
        Logger.sync.info("Merging publications: local=\(local.citeKey) remote=\(remote.citeKey)")

        // Merge scalar fields
        let mergedScalars = mergeScalarFields(local: local, remote: remote)
        applyMergedValues(mergedScalars, to: local)

        // Merge relationships
        if let localAuthors = local.publicationAuthors,
           let remoteAuthors = remote.publicationAuthors {
            let mergedAuthors = mergeAuthors(local: localAuthors, remote: remoteAuthors)
            local.publicationAuthors = mergedAuthors
        }

        if let localTags = local.tags,
           let remoteTags = remote.tags {
            local.tags = mergeTags(local: localTags, remote: remoteTags)
        }

        if let localCollections = local.collections,
           let remoteCollections = remote.collections {
            local.collections = mergeCollections(local: localCollections, remote: remoteCollections)
        }

        if let localLibraries = local.libraries,
           let remoteLibraries = remote.libraries {
            local.libraries = mergeLibraries(local: localLibraries, remote: remoteLibraries)
        }

        // Merge field timestamps
        var mergedTimestamps = local.decodedFieldTimestamps
        let remoteTimestamps = remote.decodedFieldTimestamps
        for (field, remoteTime) in remoteTimestamps.timestamps {
            let localTime = mergedTimestamps[field] ?? .distantPast
            if remoteTime > localTime {
                mergedTimestamps[field] = remoteTime
            }
        }
        local.setFieldTimestamps(mergedTimestamps)

        Logger.sync.info("Merge complete for \(local.citeKey)")

        return MergeResult(mergedPublication: local, hadConflicts: false)
    }
}

// MARK: - Merge Result

public struct MergeResult: Sendable {
    public let mergedPublication: CDPublication
    public let hadConflicts: Bool
    public var conflictDetails: [String]?

    public init(mergedPublication: CDPublication, hadConflicts: Bool, conflictDetails: [String]? = nil) {
        self.mergedPublication = mergedPublication
        self.hadConflicts = hadConflicts
        self.conflictDetails = conflictDetails
    }
}

// Note: Uses Logger.sync from Logger+Extensions.swift
