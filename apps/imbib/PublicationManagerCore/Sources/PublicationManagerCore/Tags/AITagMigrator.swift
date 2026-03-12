//
//  AITagMigrator.swift
//  PublicationManagerCore
//
//  One-time migration of flat ai/ tags to the three-tier hierarchy:
//    ai/{value} → ai/field/{value}, ai/type/{value}, or ai/topic/{value}
//

import Foundation
import OSLog

/// Migrates legacy flat `ai/` tags to the structured `ai/field/`, `ai/type/`, `ai/topic/` hierarchy.
///
/// Runs once on first launch after update, gated by a UserDefaults key.
public enum AITagMigrator {

    private static let migrationKey = "aiTagMigrationV1Complete"

    /// Known field values from the old flat schema (pre-migration)
    private static let knownFields: Set<String> = [
        "machine-learning", "artificial-intelligence", "computer-vision",
        "natural-language-processing", "robotics", "systems",
        "astrophysics", "physics", "chemistry", "biology", "medicine",
        "mathematics", "statistics", "social-science", "economics",
        // New astro sub-fields that might already exist
        "cosmology", "stellar", "galactic", "extragalactic", "planetary",
        "high-energy", "gravitational-waves", "instrumentation", "solar",
        "astro-informatics", "theoretical-physics", "particle-physics",
        "fluid-dynamics", "other"
    ]

    /// Known paper type values
    private static let knownTypes: Set<String> = [
        "empirical", "theoretical", "review", "methods", "dataset", "position"
    ]

    /// Run migration if not yet completed.
    ///
    /// Must be called on MainActor since it accesses RustStoreAdapter.
    @MainActor
    public static func migrateIfNeeded() {
        let defaults = UserDefaults.forCurrentEnvironment
        guard !defaults.bool(forKey: migrationKey) else { return }

        let store = RustStoreAdapter.shared
        let allTags = store.listTags()

        // Find tags directly under ai/ (one level deep, e.g., "ai/astrophysics")
        let flatAITags = allTags.filter { tag in
            let parts = tag.path.components(separatedBy: "/")
            return parts.count == 2 && parts[0] == "ai"
        }

        guard !flatAITags.isEmpty else {
            // No legacy tags to migrate
            defaults.set(true, forKey: migrationKey)
            Logger.library.infoCapture(
                "AI tag migration: no flat ai/ tags found, marking complete",
                category: "migration"
            )
            return
        }

        Logger.library.infoCapture(
            "AI tag migration: migrating \(flatAITags.count) flat ai/ tags to three-tier hierarchy",
            category: "migration"
        )

        store.beginBatchMutation()

        for tag in flatAITags {
            let leaf = TagPathNormalizer.normalize(
                tag.path.components(separatedBy: "/").last ?? ""
            )
            guard !leaf.isEmpty else { continue }

            let newPath: String
            if knownTypes.contains(leaf) {
                newPath = "ai/type/\(leaf)"
            } else if knownFields.contains(leaf) {
                newPath = "ai/field/\(leaf)"
            } else {
                newPath = "ai/topic/\(leaf)"
            }

            // Only rename if path actually changed
            if tag.path != newPath {
                store.renameTag(oldPath: tag.path, newPath: newPath)
                Logger.library.infoCapture(
                    "AI tag migration: '\(tag.path)' → '\(newPath)'",
                    category: "migration"
                )
            }
        }

        store.endBatchMutation()

        defaults.set(true, forKey: migrationKey)
        Logger.library.infoCapture(
            "AI tag migration complete: \(flatAITags.count) tags processed",
            category: "migration"
        )
    }
}
