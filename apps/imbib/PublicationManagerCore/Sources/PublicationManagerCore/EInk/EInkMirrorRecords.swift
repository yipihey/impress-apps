//
//  EInkMirrorRecords.swift
//  PublicationManagerCore
//
//  Swift projections of the UniFFI records the e-ink mirror engine returns
//  (`crates/imbib-core/src/eink/`). Views and the automation router consume
//  THESE — plain `Sendable`/`Equatable` values with `Date`s and `UUID`s — so
//  no view imports `ImbibRustCore`, the same convention as `LinkedFileModel`
//  and `AnnotationModel`. Each has an `init(from:)` that is the only place a
//  Rust field name is spelled.
//
//  Millisecond timestamps become `Date`; raw state strings become
//  `EInkMirrorState?` (nil for `superseded`/`unmarked`, which have no
//  marker), with the raw string kept alongside for the states the enum does
//  not model.
//

import Foundation
import ImbibRustCore

// MARK: - Helpers

private func date(fromMs ms: Int64?) -> Date? {
    ms.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
}

private func ms(from date: Date?) -> Int? {
    date.map { Int($0.timeIntervalSince1970 * 1000) }
}

// MARK: - Counts

/// The per-state totals `eink-status` reports (`EinkCounts`).
public struct EInkCountsSnapshot: Sendable, Equatable, Hashable {
    public var queued: Int = 0
    public var awaitingSource: Int = 0
    public var awaitingFolder: Int = 0
    public var uploaded: Int = 0
    public var stale: Int = 0
    public var removedOnDevice: Int = 0
    public var failed: Int = 0
    public var superseded: Int = 0
    public var unmarked: Int = 0
    /// Uploaded copies the tablet reports as changed since the last import.
    public var newAnnotations: Int = 0

    public init() {}

    init(from row: EinkCounts) {
        queued = Int(row.queued)
        awaitingSource = Int(row.awaitingSource)
        awaitingFolder = Int(row.awaitingFolder)
        uploaded = Int(row.uploaded)
        stale = Int(row.stale)
        removedOnDevice = Int(row.removedOnDevice)
        failed = Int(row.failed)
        superseded = Int(row.superseded)
        unmarked = Int(row.unmarked)
        newAnnotations = Int(row.newAnnotations)
    }

    /// Rows still marked for the tablet, in any state.
    public var marked: Int {
        queued + awaitingSource + awaitingFolder + uploaded + stale + removedOnDevice + failed
    }

    /// Rows that need something before the tablet has a current copy.
    public var pending: Int { queued + awaitingSource + awaitingFolder + stale + failed }

    public func jsonDictionary() -> [String: Any] {
        [
            "queued": queued,
            "awaiting_source": awaitingSource,
            "awaiting_folder": awaitingFolder,
            "uploaded": uploaded,
            "stale": stale,
            "removed_on_device": removedOnDevice,
            "failed": failed,
            "superseded": superseded,
            "unmarked": unmarked,
            "new_annotations": newAnnotations,
        ]
    }
}

// MARK: - Device

/// A configured e-ink device (`imbib/eink-device` store record).
public struct EInkDeviceRecord: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public var name: String
    /// `usb` today; the transport vocabulary is Rust's.
    public var transport: String
    public var baseURL: String
    /// `all` or `individual`.
    public var mirrorMode: String
    public var rootFolderName: String
    public var mirrorCollections: Bool
    public var includeLibraryLevel: Bool
    public var includeInbox: Bool
    /// `rmdoc` or `checklist`.
    public var folderStrategy: String
    /// `rmdoc` (exact names) or `pdf` (bare file, named `<file>.pdf`).
    public var uploadFormat: String
    public var autoFetchSource: Bool
    public var importAnnotatedPDF: Bool
    public var importRmdoc: Bool
    public var importHighlights: Bool
    public var importInk: Bool
    public var importTypedText: Bool
    public var runOCR: Bool
    public var autoImportOnConnect: Bool
    public var enabled: Bool
    public var lastSyncAt: Date?
    public var lastSeenAt: Date?
    public var syncStartedAt: Date?
    public var lastError: String?
    public var created: Date

    /// True when this device's marks show on list rows.
    public var isIndividualMode: Bool { mirrorMode == "individual" }

    init(from row: EinkDeviceRow) {
        id = row.id
        name = row.name
        transport = row.transport
        baseURL = row.baseUrl
        mirrorMode = row.mirrorMode
        rootFolderName = row.rootFolderName
        mirrorCollections = row.mirrorCollections
        includeLibraryLevel = row.includeLibraryLevel
        includeInbox = row.includeInbox
        folderStrategy = row.folderStrategy
        uploadFormat = row.uploadFormat
        autoFetchSource = row.autoFetchSource
        importAnnotatedPDF = row.importAnnotatedPdf
        importRmdoc = row.importRmdoc
        importHighlights = row.importHighlights
        importInk = row.importInk
        importTypedText = row.importTypedText
        runOCR = row.runOcr
        autoImportOnConnect = row.autoImportOnConnect
        enabled = row.enabled
        lastSyncAt = date(fromMs: row.lastSyncAtMs)
        lastSeenAt = date(fromMs: row.lastSeenAtMs)
        syncStartedAt = date(fromMs: row.syncStartedAtMs)
        lastError = row.lastError
        created = date(fromMs: row.createdMs) ?? Date(timeIntervalSince1970: 0)
    }

    public func jsonDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "name": name,
            "transport": transport,
            "base_url": baseURL,
            "mirror_mode": mirrorMode,
            "root_folder_name": rootFolderName,
            "mirror_collections": mirrorCollections,
            "include_library_level": includeLibraryLevel,
            "include_inbox": includeInbox,
            "folder_strategy": folderStrategy,
            "upload_format": uploadFormat,
            "auto_fetch_source": autoFetchSource,
            "import_annotated_pdf": importAnnotatedPDF,
            "import_rmdoc": importRmdoc,
            "import_highlights": importHighlights,
            "import_ink": importInk,
            "import_typed_text": importTypedText,
            "run_ocr": runOCR,
            "auto_import_on_connect": autoImportOnConnect,
            "enabled": enabled,
            "created_ms": ms(from: created) ?? 0,
        ]
        json["last_sync_ms"] = ms(from: lastSyncAt) ?? NSNull()
        json["last_seen_ms"] = ms(from: lastSeenAt) ?? NSNull()
        json["sync_started_ms"] = ms(from: syncStartedAt) ?? NSNull()
        json["last_error"] = lastError ?? NSNull()
        return json
    }
}

/// The write side of `eink-configure-device`: every field optional, only
/// the ones set are changed (a nil `id` creates a device).
public struct EInkDeviceConfigInput: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var transport: String?
    public var baseURL: String?
    public var mirrorMode: String?
    public var rootFolderName: String?
    public var mirrorCollections: Bool?
    public var includeLibraryLevel: Bool?
    public var includeInbox: Bool?
    public var folderStrategy: String?
    public var uploadFormat: String?
    public var autoFetchSource: Bool?
    public var importAnnotatedPDF: Bool?
    public var importRmdoc: Bool?
    public var importHighlights: Bool?
    public var importInk: Bool?
    public var importTypedText: Bool?
    public var runOCR: Bool?
    public var autoImportOnConnect: Bool?
    public var enabled: Bool?

    public init(id: String? = nil) {
        self.id = id
    }

    var ffi: EinkDeviceConfigInput {
        EinkDeviceConfigInput(
            id: id,
            name: name,
            transport: transport,
            baseUrl: baseURL,
            mirrorMode: mirrorMode,
            rootFolderName: rootFolderName,
            mirrorCollections: mirrorCollections,
            includeLibraryLevel: includeLibraryLevel,
            includeInbox: includeInbox,
            folderStrategy: folderStrategy,
            uploadFormat: uploadFormat,
            autoFetchSource: autoFetchSource,
            importAnnotatedPdf: importAnnotatedPDF,
            importRmdoc: importRmdoc,
            importHighlights: importHighlights,
            importInk: importInk,
            importTypedText: importTypedText,
            runOcr: runOCR,
            autoImportOnConnect: autoImportOnConnect,
            enabled: enabled
        )
    }
}

// MARK: - Status

/// What `eink-status` reports: the one description of the mirror subsystem,
/// rendered by the Settings pane, the menu-bar gating and `GET /api/eink/status`.
public struct EInkStatusSnapshot: Sendable, Equatable, Hashable {
    public var devices: [EInkDeviceRecord] = []
    /// The device whose marks show on list rows, if any (individual mode).
    public var markerDeviceId: String?
    /// The device a call without a device id means.
    public var defaultDeviceId: String?
    public var counts = EInkCountsSnapshot()
    public var lastSyncAt: Date?
    public var lastError: String?
    /// Rows written by the retired Swift sync manager that still carry the
    /// legacy marker; the Settings migration drains them.
    public var legacyMarkerRows: Int = 0

    public init() {}

    init(from row: EinkStatus) {
        devices = row.devices.map(EInkDeviceRecord.init(from:))
        markerDeviceId = row.markerDeviceId
        defaultDeviceId = row.defaultDeviceId
        counts = EInkCountsSnapshot(from: row.counts)
        lastSyncAt = date(fromMs: row.lastSyncAtMs)
        lastError = row.lastError
        legacyMarkerRows = Int(row.legacyMarkerRows)
    }

    /// At least one enabled device exists.
    public var isConfigured: Bool { devices.contains { $0.enabled } }

    /// A device in individual mode is configured, so rows carry a marker and
    /// the mirror verbs (menu, `e`, ⌃⌘E) apply.
    public var showsIndividualControls: Bool { markerDeviceId != nil }

    public var markerDevice: EInkDeviceRecord? {
        markerDeviceId.flatMap { id in devices.first { $0.id == id } }
    }

    public var defaultDevice: EInkDeviceRecord? {
        defaultDeviceId.flatMap { id in devices.first { $0.id == id } }
    }

    /// The JSON body for `GET /api/eink/status`.
    public func jsonDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "configured": isConfigured,
            "shows_individual_controls": showsIndividualControls,
            "devices": devices.map { $0.jsonDictionary() },
            "counts": counts.jsonDictionary(),
            "legacy_marker_rows": legacyMarkerRows,
        ]
        json["marker_device_id"] = markerDeviceId ?? NSNull()
        json["default_device_id"] = defaultDeviceId ?? NSNull()
        json["last_sync_ms"] = ms(from: lastSyncAt) ?? NSNull()
        json["last_error"] = lastError ?? NSNull()
        return json
    }
}

// MARK: - Mirror row

/// One `imbib/eink-mirror` record: a publication's relationship with one device.
public struct EInkMirrorRecord: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let publicationId: UUID
    public let deviceId: String
    public let marked: Bool
    public let markedAt: Date?
    public let linkedFileId: UUID?
    /// `pdf` or `epub`.
    public let sourceKind: String?
    public let remoteId: String?
    public let remoteParentId: String?
    public let remoteName: String?
    public let remotePath: String?
    public let uploadedSha256: String?
    public let uploadedAt: Date?
    /// The marker state; nil for `superseded` / `unmarked` (see `stateRaw`).
    public let state: EInkMirrorState?
    /// Rust's spelling, including the two states the enum does not model.
    public let stateRaw: String
    public let lastError: String?
    public let attempts: Int
    public let lastAttemptAt: Date?
    public let remoteModifiedAt: Date?
    public let importedModifiedAt: Date?
    public let annotatedFileId: UUID?
    public let resend: Bool
    public let created: Date
    public let modified: Date

    init?(from row: EinkMirrorRow) {
        guard let publicationId = UUID(uuidString: row.publicationId) else { return nil }
        id = row.id
        self.publicationId = publicationId
        deviceId = row.deviceId
        marked = row.marked
        markedAt = date(fromMs: row.markedAtMs)
        linkedFileId = row.linkedFileId.flatMap(UUID.init(uuidString:))
        sourceKind = row.sourceKind
        remoteId = row.remoteId
        remoteParentId = row.remoteParentId
        remoteName = row.remoteName
        remotePath = row.remotePath
        uploadedSha256 = row.uploadedSha256
        uploadedAt = date(fromMs: row.uploadedAtMs)
        state = EInkMirrorState(rawValue: row.state)
        stateRaw = row.state
        lastError = row.lastError
        attempts = Int(row.attempts)
        lastAttemptAt = date(fromMs: row.lastAttemptMs)
        remoteModifiedAt = date(fromMs: row.remoteModifiedMs)
        importedModifiedAt = date(fromMs: row.importedModifiedMs)
        annotatedFileId = row.annotatedFileId.flatMap(UUID.init(uuidString:))
        resend = row.resend
        created = date(fromMs: row.createdMs) ?? Date(timeIntervalSince1970: 0)
        modified = date(fromMs: row.modifiedMs) ?? Date(timeIntervalSince1970: 0)
    }

    /// The `eink` object `GET /api/papers/{citeKey}` carries.
    public func jsonDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "device_id": deviceId,
            "marked": marked,
            "state": stateRaw,
            "attempts": attempts,
            "resend": resend,
        ]
        json["remote_path"] = remotePath ?? NSNull()
        json["remote_id"] = remoteId ?? NSNull()
        json["source_kind"] = sourceKind ?? NSNull()
        json["uploaded_at"] = uploadedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        json["marked_at"] = markedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        json["last_error"] = lastError ?? NSNull()
        return json
    }
}

// MARK: - Mark outcome

/// What `eink-mark` / `eink-unmark` did.
public struct EInkMarkOutcome: Sendable, Equatable {
    public let deviceId: String
    /// Publications whose row changed.
    public let changed: [UUID]
    /// Publications already in the requested state, or unknown ids.
    public let unchanged: [UUID]
    /// Marked publications with no local PDF/ePUB: only the running app can
    /// fetch one; the row waits in `awaiting_source` until then.
    public let awaitingSource: [UUID]

    init(from row: EinkMarkOutcome) {
        deviceId = row.deviceId
        changed = row.changed.compactMap(UUID.init(uuidString:))
        unchanged = row.unchanged.compactMap(UUID.init(uuidString:))
        awaitingSource = row.awaitingSource.compactMap(UUID.init(uuidString:))
    }
}

// MARK: - Folder checklist

/// A folder the tablet lacks (the USB interface cannot create folders).
public struct EInkFolderNeed: Sendable, Equatable, Hashable, Identifiable {
    /// Full path from the top level, e.g. `["imbib", "Library", "Cosmology"]`.
    public let path: [String]
    /// The deepest existing ancestor, or nil for the top level.
    public let parentId: String?
    public let publications: Int

    public var id: String { path.joined(separator: "/") }
    public var displayPath: String { path.joined(separator: " › ") }

    init(from row: FolderNeed) {
        path = row.path
        parentId = row.parentId
        publications = Int(row.publications)
    }

    public func jsonDictionary() -> [String: Any] {
        ["path": path, "parent_id": parentId ?? NSNull(), "publications": publications]
    }
}

// MARK: - Awaiting source

/// A marked publication with no local PDF/ePUB, with what a fetcher needs.
public struct EInkAwaitingSourceRecord: Sendable, Equatable, Hashable, Identifiable {
    public let mirrorId: String
    public let publicationId: UUID
    public let citeKey: String
    public let title: String
    public let doi: String?
    public let arxivId: String?
    public let url: String?

    public var id: String { mirrorId }

    init?(from row: EinkAwaitingSource) {
        guard let publicationId = UUID(uuidString: row.publicationId) else { return nil }
        mirrorId = row.mirrorId
        self.publicationId = publicationId
        citeKey = row.citeKey
        title = row.title
        doi = row.doi
        arxivId = row.arxivId
        url = row.url
    }
}

/// The local PDF/ePUB the engine would send for a publication.
public struct EInkLocalSourceRecord: Sendable, Equatable, Hashable {
    public let linkedFileId: UUID
    /// `pdf` or `epub`.
    public let kind: String
    public let filename: String
    public let relativePath: String?
    public let sha256: String?

    init?(from row: EinkLocalSource) {
        guard let linkedFileId = UUID(uuidString: row.linkedFileId) else { return nil }
        self.linkedFileId = linkedFileId
        kind = row.kind
        filename = row.filename
        relativePath = row.relativePath
        sha256 = row.sha256
    }
}

// MARK: - OCR

/// An imported ink annotation whose strokes are rendered but not yet read.
public struct EInkOCRJob: Sendable, Equatable, Hashable, Identifiable {
    public let annotationId: UUID
    public let publicationId: UUID
    public let linkedFileId: UUID
    public let pageNumber: Int
    /// Absolute path of the rendered strokes (PNG).
    public let imagePath: String

    public var id: UUID { annotationId }

    init?(from row: EinkOcrJob) {
        guard let annotationId = UUID(uuidString: row.annotationId),
              let publicationId = UUID(uuidString: row.publicationId),
              let linkedFileId = UUID(uuidString: row.linkedFileId) else { return nil }
        self.annotationId = annotationId
        self.publicationId = publicationId
        self.linkedFileId = linkedFileId
        pageNumber = Int(row.pageNumber)
        imagePath = row.imagePath
    }
}

// MARK: - Sync report

public struct EInkPlanSummary: Sendable, Equatable, Hashable {
    public let toUpload: Int
    public let awaitingSource: Int
    public let awaitingFolder: Int
    public let stale: Int
    public let removed: Int
    public let toImport: Int
    public let unchanged: Int
    public let skippedNoSource: Int
    public let skippedScope: Int
    public let foldersToCreate: Int

    init(from row: PlanSummary) {
        toUpload = Int(row.toUpload)
        awaitingSource = Int(row.awaitingSource)
        awaitingFolder = Int(row.awaitingFolder)
        stale = Int(row.stale)
        removed = Int(row.removed)
        toImport = Int(row.toImport)
        unchanged = Int(row.unchanged)
        skippedNoSource = Int(row.skippedNoSource)
        skippedScope = Int(row.skippedScope)
        foldersToCreate = Int(row.foldersToCreate)
    }

    public func jsonDictionary() -> [String: Any] {
        [
            "to_upload": toUpload,
            "awaiting_source": awaitingSource,
            "awaiting_folder": awaitingFolder,
            "stale": stale,
            "removed": removed,
            "to_import": toImport,
            "unchanged": unchanged,
            "skipped_no_source": skippedNoSource,
            "skipped_scope": skippedScope,
            "folders_to_create": foldersToCreate,
        ]
    }
}

/// One document the sync imported annotations from.
public struct EInkImportedDocument: Sendable, Equatable, Hashable {
    public let publicationId: UUID?
    public let remoteId: String
    public let annotatedPDF: String
    public let rmdoc: String?
    public let annotatedFileId: UUID?
    public let created: Int
    public let updated: Int
    public let deleted: Int
    public let inkPendingOCR: Int

    init(from row: ImportedDocument) {
        publicationId = UUID(uuidString: row.publicationId)
        remoteId = row.remoteId
        annotatedPDF = row.annotatedPdf
        rmdoc = row.rmdoc
        annotatedFileId = row.annotatedFileId.flatMap(UUID.init(uuidString:))
        created = Int(row.created)
        updated = Int(row.updated)
        deleted = Int(row.deleted)
        inkPendingOCR = Int(row.inkPendingOcr)
    }

    public func jsonDictionary() -> [String: Any] {
        var json: [String: Any] = [
            "remote_id": remoteId,
            "annotated_pdf": annotatedPDF,
            "created": created,
            "updated": updated,
            "deleted": deleted,
            "ink_pending_ocr": inkPendingOCR,
        ]
        json["publication_id"] = publicationId?.uuidString ?? NSNull()
        json["rmdoc"] = rmdoc ?? NSNull()
        json["annotated_file_id"] = annotatedFileId?.uuidString ?? NSNull()
        return json
    }
}

/// What one `eink-sync` (or `eink-plan`, when `dryRun`) run did.
public struct EInkSyncReport: Sendable, Equatable, Hashable {
    public let deviceId: String
    public let reachable: Bool
    public let dryRun: Bool
    public let summary: EInkPlanSummary
    /// Publications sent this run.
    public let uploaded: [UUID]
    /// Publications whose upload failed (`lastError` on the row says why).
    public let failed: [UUID]
    public let folderNeeds: [EInkFolderNeed]
    public let foldersCreated: [String]
    public let imports: [EInkImportedDocument]
    /// Documents with new annotations that were not imported this run.
    public let pendingImports: Int
    public let trace: [String]
    public let duration: TimeInterval

    init(from row: ImbibRustCore.EinkSyncReport) {
        deviceId = row.deviceId
        reachable = row.reachable
        dryRun = row.dryRun
        summary = EInkPlanSummary(from: row.summary)
        uploaded = row.uploaded.compactMap(UUID.init(uuidString:))
        failed = row.failed.compactMap(UUID.init(uuidString:))
        folderNeeds = row.folderNeeds.map(EInkFolderNeed.init(from:))
        foldersCreated = row.foldersCreated
        imports = row.imports.map(EInkImportedDocument.init(from:))
        pendingImports = Int(row.pendingImports)
        trace = row.trace
        duration = TimeInterval(row.durationMs) / 1000
    }

    /// Every publication this run touched — the affected set for the
    /// store event after a real sync.
    public var touchedPublicationIds: Set<UUID> {
        Set(uploaded).union(failed).union(imports.compactMap(\.publicationId))
    }

    /// The JSON body for `POST /api/eink/sync`.
    public func jsonDictionary() -> [String: Any] {
        [
            "device_id": deviceId,
            "reachable": reachable,
            "dry_run": dryRun,
            "summary": summary.jsonDictionary(),
            "uploaded": uploaded.map(\.uuidString),
            "failed": failed.map(\.uuidString),
            "folder_needs": folderNeeds.map { $0.jsonDictionary() },
            "folders_created": foldersCreated,
            "imports": imports.map { $0.jsonDictionary() },
            "pending_imports": pendingImports,
            "trace": trace,
            "duration_ms": Int(duration * 1000),
        ]
    }
}
