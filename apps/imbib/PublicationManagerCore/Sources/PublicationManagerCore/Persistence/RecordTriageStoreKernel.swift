// Persistence SEAM file — CROSS-PLATFORM (macOS + iOS).
//
//  RecordTriageStoreKernel.swift
//  PublicationManagerCore
//
//  Stage 4b: the store half of the shared triage grammar, ONCE, for every
//  record kind — undo included.
//
//  `RecordTriageActions.storeBacked(descriptor:)` has always served every imbib
//  kind from one implementation, because the store side of triage is
//  schema-agnostic: star / flag / tag live on the item ENVELOPE, and
//  dismiss / restore / archive are payload `status` writes whose values come
//  from the kind's `TriageCapabilities`. What it could not serve was a host with
//  its own undo plumbing, because it registered none of its own: imbib's undo
//  comes free from `ImbibStore`'s operation log (`RustStoreAdapter.setStarred`
//  → `UndoInfo` → `UndoCoordinator.registerUndo(info:)`), a mechanism the
//  `SharedStore` FFI does not have — `SharedStore.setStarred` returns `Void`.
//
//  So imprint wrote the whole thing again (`ManuscriptStoreAdapter`'s Triage
//  extension, ~180 lines) to get closure-based undo over caller-supplied
//  `UndoManager`s. That is what lives here now, generically: prior-value capture
//  per item, an inverse that restores each item's OWN prior value (undoing a
//  mixed selection must not flatten it), and status writes validated against the
//  descriptor's declared lifecycle.
//
//  Rule 3 of `CollectionStoreAdapter`'s header holds here too: `apply*` performs
//  the store verb and posts the mutation event but registers nothing; the public
//  verb wraps it and registers the inverse. Undo/redo closures call `apply*`,
//  never the public verb — a public call inside a closure would push a SECOND
//  entry (one ⌘Z needing two ⌘⇧Z).
//

import Foundation
import ImpressLogging
import ImpressRustCore
import ImpressStoreKit
import OSLog

/// Descriptor-driven triage verbs over a `SharedStore`, with undo.
///
/// Stateless apart from its `StoreKernelScope`, so a host can build one per call
/// site (imprint's adapter holds one; `RecordTriageActions.storeBacked` builds
/// one on demand).
@MainActor
public struct RecordTriageStoreKernel {

    /// The kind's declarative contract — every status string below is READ from
    /// it. A literal `"dismissed"` here would be a second source of truth that
    /// drifts the first time a descriptor changes, which is the class of bug the
    /// descriptors exist to prevent.
    public let descriptor: RecordKindDescriptor

    /// The schema ref status writes are upserted under. Defaults to the
    /// descriptor's first declared ref, which is what every caller wants; a host
    /// whose rows carry a versioned ref passes the spelling its writer uses
    /// (schema-refs.json § "copy the spelling from the manifest").
    public let schemaRef: String

    public let scope: StoreKernelScope

    public init(
        descriptor: RecordKindDescriptor,
        scope: StoreKernelScope,
        schemaRef: String? = nil
    ) {
        self.descriptor = descriptor
        self.scope = scope
        self.schemaRef = schemaRef ?? descriptor.schemaRefs.first ?? descriptor.id.rawValue
    }

    // MARK: - Undo action names
    //
    // Preserved EXACTLY as `ManuscriptStoreAdapter` registered them, so
    // imprint's Edit menu reads identically after the migration. Renaming any
    // of these is a deliberate UX change for another pass, not a side effect of
    // moving onto the kernel.

    public enum UndoActionName {
        public static let star = StoreKernelUndoAction.star
        public static let flag = StoreKernelUndoAction.flag
        public static let addTag = StoreKernelUndoAction.addTag
        public static let removeTag = StoreKernelUndoAction.removeTag
        public static let dismiss = StoreKernelUndoAction.dismiss
        public static let restore = StoreKernelUndoAction.restore
        public static let archive = StoreKernelUndoAction.archive
        public static let rename = StoreKernelUndoAction.rename
        /// Fallback for a `setStatus` call that names no action of its own.
        public static let changeStatus = StoreKernelUndoAction.changeStatus
    }

    // MARK: - Derived lifecycle (read, never retyped)

    /// Reserved `dismissed` status for this kind (docs/status-lifecycle.md), or
    /// nil when the kind has no status-based dismissal.
    public var dismissedStatus: String? {
        if case .statusChange(let dismissed, _) = descriptor.triage.dismissal { return dismissed }
        return nil
    }

    /// Status a restore returns a dismissed record to.
    public var restoreStatus: String? {
        if case .statusChange(_, let restoreTo) = descriptor.triage.dismissal { return restoreTo }
        return nil
    }

    /// Reserved `archived` status, or nil when the kind has no archive.
    public var archivedStatus: String? { descriptor.triage.archiveStatus }

    // MARK: - Star

    /// Star / unstar. The inverse restores each item's PRIOR value, so undoing a
    /// mixed selection does not flatten it.
    public func setStarred(ids: [UUID], starred: Bool, undo: StoreUndoScope? = nil) {
        let priors = ids.reduce(into: [UUID: Bool]()) { acc, id in
            acc[id] = item(id)?.isStarred ?? !starred
        }
        let next = ids.reduce(into: [UUID: Bool]()) { $0[$1] = starred }
        applyStarred(next)
        scope.registerReversible(
            undo,
            actionName: UndoActionName.star,
            undo: { applyStarred(priors) },
            redo: { applyStarred(next) }
        )
    }

    // MARK: - Flag

    /// Set (or clear, with `nil`) the flag colour.
    public func setFlag(ids: [UUID], color: String?, undo: StoreUndoScope? = nil) {
        var priors: [UUID: String?] = [:]
        for id in ids {
            priors[id] = item(id)?.flagColor
        }
        let next = ids.reduce(into: [UUID: String?]()) { $0[$1] = color }
        applyFlag(next)
        scope.registerReversible(
            undo,
            actionName: UndoActionName.flag,
            undo: { applyFlag(priors) },
            redo: { applyFlag(next) }
        )
    }

    // MARK: - Tags

    /// Add a tag path. The inverse removes it only from the items that did not
    /// already carry it.
    public func addTag(ids: [UUID], tagPath: String, undo: StoreUndoScope? = nil) {
        let changed = ids.filter { !(item($0)?.tags ?? []).contains(tagPath) }
        guard !changed.isEmpty else { return }
        applyTag(changed, tagPath: tagPath, add: true)
        scope.registerReversible(
            undo,
            actionName: UndoActionName.addTag,
            undo: { applyTag(changed, tagPath: tagPath, add: false) },
            redo: { applyTag(changed, tagPath: tagPath, add: true) }
        )
    }

    /// Remove a tag path, inverse-adding it back only where it was present.
    public func removeTag(ids: [UUID], tagPath: String, undo: StoreUndoScope? = nil) {
        let changed = ids.filter { (item($0)?.tags ?? []).contains(tagPath) }
        guard !changed.isEmpty else { return }
        applyTag(changed, tagPath: tagPath, add: false)
        scope.registerReversible(
            undo,
            actionName: UndoActionName.removeTag,
            undo: { applyTag(changed, tagPath: tagPath, add: true) },
            redo: { applyTag(changed, tagPath: tagPath, add: false) }
        )
    }

    /// Every tag path in use on this kind's rows, sorted, de-duplicated.
    ///
    /// DERIVED from the items' own envelope `tags`, not read from a tag index,
    /// because there is no tag-listing verb to call: the `SharedStore` FFI
    /// exposes `add_tag` / `remove_tag` and nothing else, and the only listing
    /// verbs in the suite (`ImbibStore.listTags` / `listTagsWithCounts`) belong
    /// to imbib-core's `imbib/tag-definition` rows, which no sibling app writes.
    /// Reaching for those would boot a second store facade just to populate a
    /// submenu — the reason `RecordTriageActions.availableTagPaths` became
    /// injectable in the first place.
    ///
    /// Consequences worth knowing: the list is what is USED, not what has been
    /// DEFINED, so a tag removed from its last record disappears from the menu.
    /// For the Tags submenu — whose job is "file this under something you
    /// already use" — that is the more useful set. A real
    /// `distinct_tags(schema_ref)` verb in `impress-core` would be strictly
    /// better (one indexed query instead of a full scan).
    public func tagPathsInUse(pageSize: UInt32 = 100) -> [String] {
        guard let store = scope.store else { return [] }
        var paths = Set<String>()
        var offset: UInt32 = 0
        while true {
            let rows = (try? store.queryBySchema(
                schemaRef: schemaRef, limit: pageSize, offset: offset)) ?? []
            if rows.isEmpty { break }
            for row in rows { paths.formUnion(row.tags) }
            offset &+= UInt32(rows.count)
            if rows.count < Int(pageSize) { break }
        }
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Rename

    /// Rename via the payload `title` field, restoring the prior title on undo.
    public func rename(id: UUID, to title: String, undo: StoreUndoScope? = nil) {
        let prior = currentTitle(id)
        applyTitle([id: title])
        Logger.library.infoCapture(
            "renamed \(descriptor.displayName.lowercased()) \(id) → '\(title)'",
            category: "triage")
        scope.registerReversible(
            undo,
            actionName: UndoActionName.rename,
            undo: { if let prior { applyTitle([id: prior]) } },
            redo: { applyTitle([id: title]) }
        )
    }

    // MARK: - Status lifecycle

    /// Sweep records out of the working set. The status value and the action are
    /// the DESCRIPTOR's `DismissalSemantics.statusChange`; a kind that declares
    /// `.none` is a no-op here rather than a silent wrong write.
    @discardableResult
    public func dismiss(ids: [UUID], undo: StoreUndoScope? = nil) -> Bool {
        guard let dismissed = dismissedStatus else { return false }
        return setStatus(
            ids: ids, to: dismissed, actionName: UndoActionName.dismiss, undo: undo)
    }

    /// Return dismissed records to the descriptor's restore status — not to
    /// whatever they held before, which is what the declared contract says and
    /// what the macOS grammar does.
    @discardableResult
    public func restore(ids: [UUID], undo: StoreUndoScope? = nil) -> Bool {
        guard let restoreTo = restoreStatus else { return false }
        return setStatus(
            ids: ids, to: restoreTo, actionName: UndoActionName.restore, undo: undo)
    }

    /// Move to the deliberate end-state, when the kind declares an
    /// `archiveStatus`.
    @discardableResult
    public func archive(ids: [UUID], undo: StoreUndoScope? = nil) -> Bool {
        guard let archived = archivedStatus else { return false }
        return setStatus(
            ids: ids, to: archived, actionName: UndoActionName.archive, undo: undo)
    }

    /// Free-form status write, validated against the descriptor's declared
    /// lifecycle. A status the kind never declares is refused rather than
    /// written — the schema has no validation, so this is the only gate.
    @discardableResult
    public func setStatus(
        ids: [UUID],
        to status: String,
        actionName: String? = nil,
        undo: StoreUndoScope? = nil
    ) -> Bool {
        let declared = descriptor.triage.statusValues
        guard declared.isEmpty || declared.contains(status) else {
            Logger.library.error(
                "setStatus refused undeclared status '\(status)' for \(descriptor.id.rawValue)")
            return false
        }
        var priors: [UUID: String] = [:]
        for id in ids {
            priors[id] = currentStatus(id) ?? restoreStatus ?? status
        }
        let next = ids.reduce(into: [UUID: String]()) { $0[$1] = status }
        applyStatus(next)
        Logger.library.infoCapture(
            "status → '\(status)' for \(ids.count) \(descriptor.displayName.lowercased())(s)",
            category: "triage")
        scope.registerReversible(
            undo,
            actionName: actionName ?? UndoActionName.changeStatus,
            undo: { applyStatus(priors) },
            redo: { applyStatus(next) }
        )
        return true
    }

    // MARK: - Raw verbs (event-posting, NOT undo-registering)

    /// Ids crossing the FFI are lowercased: the Rust store's canonical id form
    /// is lowercase and payload refs are matched by string equality, while
    /// `UUID().uuidString` is uppercase (imbib CLAUDE.md invariant).
    private static func lower(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func item(_ id: UUID) -> SharedItemRow? {
        guard let store = scope.store else { return nil }
        return (try? store.getItem(id: Self.lower(id))) ?? nil
    }

    /// The payload `status` a row currently holds, or nil when the row is absent.
    /// A row present but without the key reads as the restore status, matching
    /// what a full decode of an unset `status` field produces.
    private func currentStatus(_ id: UUID) -> String? {
        guard let row = item(id) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: Data(row.payloadJson.utf8)))
            as? [String: Any]
        return payload?["status"] as? String ?? restoreStatus
    }

    public func applyStarred(_ states: [UUID: Bool]) {
        guard let store = scope.store else { return }
        for (id, value) in states {
            try? store.setStarred(id: Self.lower(id), isStarred: value)
        }
        scope.noteMutation(false, Set(states.keys), .otherField)
    }

    public func applyFlag(_ states: [UUID: String?]) {
        guard let store = scope.store else { return }
        for (id, value) in states {
            try? store.setFlag(id: Self.lower(id), color: value, style: nil, length: nil)
        }
        scope.noteMutation(false, Set(states.keys), .otherField)
    }

    public func applyTag(_ ids: [UUID], tagPath: String, add: Bool) {
        guard let store = scope.store else { return }
        for id in ids {
            if add {
                try? store.addTag(id: Self.lower(id), tag: tagPath)
            } else {
                try? store.removeTag(id: Self.lower(id), tag: tagPath)
            }
        }
        scope.noteMutation(false, Set(ids), .otherField)
    }

    /// The payload `title` a row currently holds, or nil when the row is absent.
    private func currentTitle(_ id: UUID) -> String? {
        guard let row = item(id) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: Data(row.payloadJson.utf8)))
            as? [String: Any]
        return payload?["title"] as? String
    }

    public func applyTitle(_ states: [UUID: String]) {
        guard let store = scope.store else { return }
        for (id, title) in states {
            guard let json = try? Self.encodeField("title", title) else { continue }
            try? store.upsertItem(id: id.uuidString, schemaRef: schemaRef, payloadJson: json)
        }
        scope.noteMutation(false, Set(states.keys), .otherField)
    }

    public func applyStatus(_ states: [UUID: String]) {
        guard let store = scope.store else { return }
        for (id, status) in states {
            guard let json = try? Self.encodeStatus(status) else { continue }
            // `id.uuidString` (uppercase) is what the manuscript writer has
            // always used for its own upserts, and `upsertItem` normalises;
            // the lowercase rule matters for payload REFS, not this argument.
            try? store.upsertItem(id: id.uuidString, schemaRef: schemaRef, payloadJson: json)
        }
        // Structural: a dismissed record LEAVES every unscoped list, so a
        // field-only refresh would leave a stale row on screen.
        scope.noteMutation(true, Set(states.keys), .otherField)
    }

    private static func encodeStatus(_ status: String) throws -> String {
        try encodeField("status", status)
    }

    private static func encodeField(_ key: String, _ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [key: value], options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value, .init(codingPath: [], debugDescription: "payload not UTF-8"))
        }
        return text
    }
}
