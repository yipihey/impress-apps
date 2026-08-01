// Chassis SEAM file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordTagVocabulary.swift
//  PublicationManagerCore
//
//  "Which tag paths does this kind actually use", once, for every host.
//
//  The Tags section needs a vocabulary per kind (`RecordSidebarDataSource
//  .tags`), and the only derivation available is a scan of the kind's own rows:
//  `RecordTriageStoreKernel.tagPathsInUse` explains why in full — the
//  `SharedStore` FFI exposes `add_tag`/`remove_tag` and no listing verb, and
//  the one listing verb in the suite (`ImbibStore.listTags`) reads imbib's
//  `imbib/tag-definition` rows, which no sibling app writes.
//
//  A scan is exactly the shape that must not be repeated per host, per rebuild
//  and per keystroke of a filter field. So the memo lives here, keyed on the
//  host's own data version, rather than four times over in four bindings files
//  with four different invalidation bugs. imbib is the deliberate exception in
//  both shells: it HAS a tag-definition table (23,916 rows), and reading the
//  definitions is both cheaper and more complete than scanning publications.
//

import Foundation

/// The tag vocabulary of a record kind, memoised per data version.
@MainActor
public enum RecordTagVocabulary {

    private struct Entry {
        let version: Int
        let paths: [String]
    }

    private static var cache: [RecordKindID: Entry] = [:]

    /// Every tag path in use on `kind`'s rows, sorted and de-duplicated.
    ///
    /// - Parameters:
    ///   - kind: the record kind to scan. A kind with no shipped descriptor
    ///     returns `[]` rather than guessing a schema ref.
    ///   - version: the host's store version. The scan re-runs only when this
    ///     changes, so a filter field asking on every keystroke costs one
    ///     dictionary lookup.
    public static func inUse(_ kind: RecordKindID, version: Int) -> [String] {
        if let entry = cache[kind], entry.version == version { return entry.paths }
        guard let descriptor = BuiltinRecordKinds.all.first(where: { $0.id == kind }) else {
            return []
        }
        let kernel = RecordTriageStoreKernel(
            descriptor: descriptor, scope: CollectionStoreAdapter.shared.scope)
        let paths = kernel.tagPathsInUse()
        cache[kind] = Entry(version: version, paths: paths)
        return paths
    }

    /// Drop the memo — for tests, and for a host that mutates tags through a
    /// path its own version counter does not observe.
    public static func invalidate() {
        cache.removeAll()
    }
}
