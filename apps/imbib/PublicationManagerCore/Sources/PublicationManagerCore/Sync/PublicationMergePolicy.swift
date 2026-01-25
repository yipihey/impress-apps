//
//  PublicationMergePolicy.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-16.
//

import Foundation
import CoreData
import OSLog

/// Custom merge policy for CloudKit sync that implements field-level merging (ADR-007)
public final class PublicationMergePolicy: NSMergePolicy {

    public init() {
        // Use merge by property object trump as the base policy
        super.init(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }

    // MARK: - Constraint Conflict Resolution

    public override func resolve(constraintConflicts list: [NSConstraintConflict]) throws {
        for conflict in list {
            try resolveConstraintConflict(conflict)
        }
        try super.resolve(constraintConflicts: list)
    }

    private func resolveConstraintConflict(_ conflict: NSConstraintConflict) throws {
        // Handle cite key uniqueness constraint violations
        guard let publication = conflict.databaseObject as? CDPublication else {
            return
        }

        Logger.sync.info("Resolving constraint conflict for publication: \(publication.citeKey)")

        // Check if this is a cite key collision
        if let conflicting = conflict.conflictingObjects.first as? CDPublication {
            // Queue for user resolution instead of auto-merging
            let citeKeyConflict = CiteKeyConflict(
                incomingPublicationID: publication.id,
                existingPublicationID: conflicting.id,
                citeKey: publication.citeKey,
                suggestedResolutions: [
                    .renameIncoming(newCiteKey: "\(publication.citeKey)a"),
                    .merge,
                    .keepExisting
                ]
            )

            Task { @MainActor in
                SyncConflictQueue.shared.enqueue(.citeKey(citeKeyConflict))
            }
        }
    }

    // MARK: - Merge Conflict Resolution

    public override func resolve(mergeConflicts list: [Any]) throws {
        for conflict in list {
            if let mergeConflict = conflict as? NSMergeConflict {
                try resolveMergeConflict(mergeConflict)
            }
        }
        try super.resolve(mergeConflicts: list)
    }

    private func resolveMergeConflict(_ conflict: NSMergeConflict) throws {
        guard let publication = conflict.sourceObject as? CDPublication else {
            return
        }

        Logger.sync.info("Resolving merge conflict for publication: \(publication.citeKey)")

        // Get the object and cached/persisted snapshots
        let objectSnapshot = conflict.objectSnapshot ?? [:]
        let cachedSnapshot = conflict.cachedSnapshot ?? [:]
        let persistedSnapshot = conflict.persistedSnapshot ?? [:]

        // Apply field-level merge using timestamps
        let localTimestamps = decodeTimestamps(from: objectSnapshot["fieldTimestamps"] as? String)
        let remoteTimestamps = decodeTimestamps(from: persistedSnapshot["fieldTimestamps"] as? String)

        var mergedTimestamps = localTimestamps

        // For each field, use the version with the more recent timestamp
        for field in CDPublication.scalarFields {
            let localTime = localTimestamps[field] ?? .distantPast
            let remoteTime = remoteTimestamps[field] ?? .distantPast

            if remoteTime > localTime {
                // Remote wins - apply the persisted value
                if let value = persistedSnapshot[field] {
                    publication.setValue(value, forKey: field)
                    mergedTimestamps[field] = remoteTime
                }
            }
            // Otherwise local wins (already has the value)
        }

        // Save merged timestamps
        publication.setFieldTimestamps(FieldTimestamps(timestamps: mergedTimestamps))

        // Merge relationships (union merge)
        mergeRelationships(publication, objectSnapshot: objectSnapshot, persistedSnapshot: persistedSnapshot)
    }

    // MARK: - Helper Methods

    private func decodeTimestamps(from json: String?) -> [String: Date] {
        guard let json = json,
              let data = json.data(using: .utf8),
              let timestamps = try? JSONDecoder().decode(FieldTimestamps.self, from: data) else {
            return [:]
        }
        return timestamps.timestamps
    }

    private func mergeRelationships(
        _ publication: CDPublication,
        objectSnapshot: [String: Any],
        persistedSnapshot: [String: Any]
    ) {
        // Tags - union merge
        if let localTags = objectSnapshot["tags"] as? Set<CDTag>,
           let remoteTags = persistedSnapshot["tags"] as? Set<CDTag> {
            publication.tags = localTags.union(remoteTags)
        }

        // Collections - union merge
        if let localCollections = objectSnapshot["collections"] as? Set<CDCollection>,
           let remoteCollections = persistedSnapshot["collections"] as? Set<CDCollection> {
            publication.collections = localCollections.union(remoteCollections)
        }

        // Libraries - union merge
        if let localLibraries = objectSnapshot["libraries"] as? Set<CDLibrary>,
           let remoteLibraries = persistedSnapshot["libraries"] as? Set<CDLibrary> {
            publication.libraries = localLibraries.union(remoteLibraries)
        }
    }
}

// MARK: - PersistenceController Extension

public extension PersistenceController {

    /// Configure the view context to use our custom merge policy
    func configureCloudKitMerging() {
        viewContext.mergePolicy = PublicationMergePolicy()
        Logger.sync.info("Configured custom merge policy for CloudKit sync")
    }

    /// Enable CloudKit sync with conflict resolution
    func enableCloudKitSync() {
        guard isCloudKitEnabled else {
            Logger.sync.warning("Cannot enable CloudKit sync - not configured")
            return
        }

        // Configure merge policy
        configureCloudKitMerging()

        // Start sync conflict monitoring
        setupSyncConflictMonitoring()

        Logger.sync.info("CloudKit sync enabled with conflict resolution")
    }

    private func setupSyncConflictMonitoring() {
        // Monitor for remote changes
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] notification in
            self?.handleRemoteChangeWithConflictDetection(notification)
        }
    }

    private func handleRemoteChangeWithConflictDetection(_ notification: Notification) {
        viewContext.perform { [weak self] in
            guard let self = self else { return }

            // Refresh objects
            self.viewContext.refreshAllObjects()

            // Check for any unresolved conflicts in the context
            if self.viewContext.hasChanges {
                Logger.sync.debug("View context has changes after remote sync")
            }

            // Notify UI
            NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
        }
    }
}
