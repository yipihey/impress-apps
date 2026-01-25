//
//  ConflictDetector.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
import OSLog

// MARK: - Cite Key Conflict

/// Represents a conflict where two publications have the same cite key
public struct CiteKeyConflict: Identifiable, Sendable {
    public let id: UUID
    public let incomingPublicationID: UUID
    public let existingPublicationID: UUID
    public let citeKey: String
    public let suggestedResolutions: [CiteKeyResolution]
    public let detectedAt: Date

    public init(
        incomingPublicationID: UUID,
        existingPublicationID: UUID,
        citeKey: String,
        suggestedResolutions: [CiteKeyResolution]
    ) {
        self.id = UUID()
        self.incomingPublicationID = incomingPublicationID
        self.existingPublicationID = existingPublicationID
        self.citeKey = citeKey
        self.suggestedResolutions = suggestedResolutions
        self.detectedAt = Date()
    }
}

/// Resolution options for cite key conflicts
public enum CiteKeyResolution: Identifiable, Sendable {
    case renameIncoming(newCiteKey: String)
    case renameExisting(newCiteKey: String)
    case merge  // Merge incoming into existing
    case keepBoth  // Keep both with auto-generated unique keys
    case keepExisting  // Discard incoming
    case keepIncoming  // Replace existing with incoming

    public var id: String {
        switch self {
        case .renameIncoming(let key): return "rename-incoming-\(key)"
        case .renameExisting(let key): return "rename-existing-\(key)"
        case .merge: return "merge"
        case .keepBoth: return "keep-both"
        case .keepExisting: return "keep-existing"
        case .keepIncoming: return "keep-incoming"
        }
    }

    public var description: String {
        switch self {
        case .renameIncoming(let key):
            return "Rename incoming to \"\(key)\""
        case .renameExisting(let key):
            return "Rename existing to \"\(key)\""
        case .merge:
            return "Merge publications"
        case .keepBoth:
            return "Keep both (auto-rename)"
        case .keepExisting:
            return "Keep existing, discard incoming"
        case .keepIncoming:
            return "Replace existing with incoming"
        }
    }
}

// MARK: - PDF Conflict

/// Represents a conflict where the same PDF was modified on multiple devices
public struct PDFConflict: Identifiable, Sendable {
    public let id: UUID
    public let publicationID: UUID
    public let localFilePath: String
    public let remoteFilePath: String
    public let localModifiedDate: Date
    public let remoteModifiedDate: Date
    public let detectedAt: Date

    public init(
        publicationID: UUID,
        localFilePath: String,
        remoteFilePath: String,
        localModifiedDate: Date,
        remoteModifiedDate: Date
    ) {
        self.id = UUID()
        self.publicationID = publicationID
        self.localFilePath = localFilePath
        self.remoteFilePath = remoteFilePath
        self.localModifiedDate = localModifiedDate
        self.remoteModifiedDate = remoteModifiedDate
        self.detectedAt = Date()
    }
}

/// Resolution options for PDF conflicts
public enum PDFConflictResolution: Sendable, CustomStringConvertible {
    case keepLocal
    case keepRemote
    case keepBoth  // Rename remote to _conflict_<date>.pdf

    public var description: String {
        switch self {
        case .keepLocal: return "keepLocal"
        case .keepRemote: return "keepRemote"
        case .keepBoth: return "keepBoth"
        }
    }
}

// MARK: - Conflict Detector

/// Detects and manages sync conflicts (ADR-007)
public actor ConflictDetector {

    public static let shared = ConflictDetector()

    private init() {}

    /// Check for cite key collision during sync
    public func detectCiteKeyConflict(
        incoming: CDPublication,
        in context: NSManagedObjectContext
    ) async -> CiteKeyConflict? {
        let citeKey = incoming.citeKey
        let incomingID = incoming.id

        // Fetch existing publications with the same cite key
        let request = NSFetchRequest<CDPublication>(entityName: "Publication")
        request.predicate = NSPredicate(format: "citeKey == %@ AND id != %@", citeKey, incomingID as CVarArg)
        request.fetchLimit = 1

        do {
            let existing = try context.fetch(request)
            guard let collision = existing.first else {
                return nil
            }

            Logger.sync.info("Detected cite key conflict: \(citeKey)")

            // Generate suggested resolutions
            let suggestedNewKeyForIncoming = generateUniqueCiteKey(
                basedOn: incoming,
                avoiding: [citeKey],
                context: context
            )

            let suggestedNewKeyForExisting = generateUniqueCiteKey(
                basedOn: collision,
                avoiding: [citeKey, suggestedNewKeyForIncoming],
                context: context
            )

            return CiteKeyConflict(
                incomingPublicationID: incomingID,
                existingPublicationID: collision.id,
                citeKey: citeKey,
                suggestedResolutions: [
                    .renameIncoming(newCiteKey: suggestedNewKeyForIncoming),
                    .renameExisting(newCiteKey: suggestedNewKeyForExisting),
                    .merge,
                    .keepBoth,
                    .keepExisting,
                    .keepIncoming
                ]
            )
        } catch {
            Logger.sync.error("Failed to detect cite key conflict: \(error)")
            return nil
        }
    }

    /// Generate a unique cite key by appending a suffix
    private func generateUniqueCiteKey(
        basedOn publication: CDPublication,
        avoiding existingKeys: [String],
        context: NSManagedObjectContext
    ) -> String {
        let baseCiteKey = publication.citeKey

        // Try suffixes: a, b, c, ..., z, then 2, 3, 4, ...
        let suffixes = Array("abcdefghijklmnopqrstuvwxyz").map(String.init) + (2...99).map(String.init)

        for suffix in suffixes {
            let candidate = "\(baseCiteKey)\(suffix)"

            // Check if candidate is in the avoiding list
            if existingKeys.contains(candidate) {
                continue
            }

            // Check if candidate exists in database
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "citeKey == %@", candidate)
            request.fetchLimit = 1

            do {
                let count = try context.count(for: request)
                if count == 0 {
                    return candidate
                }
            } catch {
                // On error, continue trying
            }
        }

        // Fallback: use UUID
        return "\(baseCiteKey)_\(UUID().uuidString.prefix(8))"
    }

    /// Detect PDF conflict by comparing file hashes or modification dates
    public func detectPDFConflict(
        localFile: CDLinkedFile,
        remoteFile: CDLinkedFile,
        publication: CDPublication
    ) async -> PDFConflict? {
        // Compare SHA256 hashes if available
        if let localHash = localFile.sha256,
           let remoteHash = remoteFile.sha256,
           localHash == remoteHash {
            // No conflict - files are identical
            return nil
        }

        // Files differ - create conflict
        return PDFConflict(
            publicationID: publication.id,
            localFilePath: localFile.relativePath,
            remoteFilePath: remoteFile.relativePath,
            localModifiedDate: localFile.dateAdded,
            remoteModifiedDate: remoteFile.dateAdded
        )
    }

    /// Detect duplicate publications by identifiers (DOI, arXiv, bibcode)
    public func detectDuplicateByIdentifiers(
        incoming: CDPublication,
        in context: NSManagedObjectContext
    ) async -> CDPublication? {
        // Check DOI
        if let doi = incoming.doi, !doi.isEmpty {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "doi == %@ AND id != %@", doi, incoming.id as CVarArg)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                Logger.sync.info("Found duplicate by DOI: \(doi)")
                return existing
            }
        }

        // Check arXiv ID
        if let arxivID = incoming.arxivIDNormalized, !arxivID.isEmpty {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "arxivIDNormalized == %@ AND id != %@", arxivID, incoming.id as CVarArg)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                Logger.sync.info("Found duplicate by arXiv ID: \(arxivID)")
                return existing
            }
        }

        // Check bibcode
        if let bibcode = incoming.bibcodeNormalized, !bibcode.isEmpty {
            let request = NSFetchRequest<CDPublication>(entityName: "Publication")
            request.predicate = NSPredicate(format: "bibcodeNormalized == %@ AND id != %@", bibcode, incoming.id as CVarArg)
            request.fetchLimit = 1

            if let existing = try? context.fetch(request).first {
                Logger.sync.info("Found duplicate by bibcode: \(bibcode)")
                return existing
            }
        }

        return nil
    }
}
