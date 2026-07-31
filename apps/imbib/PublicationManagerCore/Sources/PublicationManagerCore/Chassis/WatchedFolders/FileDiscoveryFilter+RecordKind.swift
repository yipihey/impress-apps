// Chassis WIRING file — CROSS-PLATFORM (macOS + iOS). Data only.
//
//  FileDiscoveryFilter+RecordKind.swift
//  PublicationManagerCore
//
//  ADR-0023 W2 — the ONE place a `FileDiscoveryCapability` becomes a
//  `FileDiscoveryFilter`.
//
//  ── Why this is a file of its own ───────────────────────────────────────────
//
//  W0 put the declaration on the record kind (`RecordKindDescriptor
//  .fileDiscovery`); W1 wrote the watcher against a plain value
//  (`FileDiscoveryFilter`) that deliberately knows nothing about descriptors —
//  see its header for why dragging the declaration graph into a filesystem
//  watcher would be the wrong dependency. The two types therefore have to meet
//  SOMEWHERE, and the whole design depends on that somewhere being exactly one
//  place: a second mapping is a second answer to "which files does imbib
//  watch", and the ADR's D1 exists to make that question have one answer.
//
//  It lives chassis-side rather than in imbib's app target because W3 (imprint,
//  manuscript folders) and W4 (impart mbox, implore vsz) map the identical way
//  off their own descriptors. The mapping is kind-agnostic; only the caller's
//  choice of kind is not.
//
//  ── The two halves, and why both are carried ────────────────────────────────
//
//  `FileTypeSpec` has an optional UTI and a non-optional extension list, and
//  that asymmetry is load-bearing rather than incidental: W0 found that `.ris`
//  has NO UTI anywhere in the suite, so a discovery query built from UTIs alone
//  would match zero RIS files forever, silently. `FileDiscoveryFilter` matches
//  on both halves and `SpotlightPredicateFormat` emits both clauses, so the
//  mapping's only job is to hand over everything the capability declares and
//  drop nothing.
//
//  ── Identity ────────────────────────────────────────────────────────────────
//
//  `FileDiscoveryFilter.id` is the record kind's raw value ("publication"),
//  which makes it three things at once and all three are deliberate:
//
//    1. The attribution stamped on every `DiscoveredFile`, so a host can route
//       a hit to the kind that asked for it (D3's per-kind ingest unit).
//    2. The key persisted in `WatchedFolderBookmark.filterIDs`, re-resolved on
//       the next launch through `filtersByID` — which is what lets a kind that
//       gains an extension gain it on every already-watched folder, with no
//       migration.
//    3. The `kind_scope` the Rust `watched-folder@1.0.0` row is created with
//       (`BuiltinRecordKinds.fileDiscoveryKindScopes` is the legal set).
//
//  Nothing in the chassis parses it, but those three must agree, and they agree
//  by being the same string from the same source.
//

import Foundation

public extension FileDiscoveryFilter {

    /// The filter a record kind's declaration implies, or `nil` when the kind
    /// declares no file discovery at all.
    ///
    /// `nil` rather than an empty filter on purpose: an empty filter matches
    /// nothing and would put a folder into `scanOnDemand` with `.noFilters`,
    /// which is the right rendering for "the kind's declaration is broken" and
    /// the wrong one for "this kind was never watchable". A caller that wants
    /// the whole watchable set should ask for `builtinFilters`.
    init?(recordKind descriptor: RecordKindDescriptor) {
        guard let capability = descriptor.fileDiscovery else { return nil }
        self.init(
            id: descriptor.id.rawValue,
            contentTypeIdentifiers: capability.utiIdentifiers,
            filenameExtensions: capability.fileExtensions)
    }

    /// The filter for one kind scope, resolved through the same authority the
    /// Rust `kind_scope` vocabulary comes from.
    ///
    /// `BuiltinRecordKinds.fileDiscovery(forKindScope:)` reads `all`, not a
    /// shell's `recordKinds`, deliberately (see its doc comment): which files a
    /// folder discovers must not depend on which sections the host happens to
    /// show.
    static func forKindScope(_ kindScope: String) -> FileDiscoveryFilter? {
        guard let capability = BuiltinRecordKinds.fileDiscovery(forKindScope: kindScope) else {
            return nil
        }
        return FileDiscoveryFilter(
            id: kindScope,
            contentTypeIdentifiers: capability.utiIdentifiers,
            filenameExtensions: capability.fileExtensions)
    }

    /// Every watchable kind's filter, in declaration order.
    static var builtinFilters: [FileDiscoveryFilter] {
        BuiltinRecordKinds.fileDiscoverable.compactMap { FileDiscoveryFilter(recordKind: $0) }
    }

    /// `builtinFilters` keyed by id — the table
    /// `FolderWatchService.restorePersistedFolders(filtersByID:)` takes.
    ///
    /// A persisted folder whose filter id no longer resolves here is registered
    /// with NO filters and lands in `scanOnDemand` with `.noFilters`: visible
    /// and fixable, rather than silently watching nothing.
    static var builtinFiltersByID: [String: FileDiscoveryFilter] {
        Dictionary(uniqueKeysWithValues: builtinFilters.map { ($0.id, $0) })
    }

    /// imbib's filter: the publication kind's `.bib` / `.ris` declaration.
    ///
    /// Force-derived from the descriptor rather than spelled out, so that if
    /// the declaration ever loses its `fileDiscovery` this fails loudly at the
    /// call site instead of quietly watching for nothing.
    static var publications: FileDiscoveryFilter? {
        FileDiscoveryFilter(recordKind: PublicationRecordKind.descriptor)
    }
}
