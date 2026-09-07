//
//  RustStoreAdapter+EInk.swift
//  PublicationManagerCore
//
//  The e-ink mirror surface of the store (ADR-025): thin wrappers over the
//  `eink*` UniFFI verbs that imbib-core's `eink` module exposes. Every
//  wrapper absorbs `throws` into a logged nil/empty result — the convention
//  of the rest of the adapter — converts the UniFFI records into the Swift
//  projections in `EInk/EInkMirrorRecords.swift`, and, for the mutating
//  ones, fans the change out through `didMutate(kind: .einkMirror)` exactly
//  the way `setStarred` does, so the list rows re-read their marker.
//
//  Two verbs block on the tablet's USB interface (`einkSync`, `einkPlan`;
//  `einkReachable` is a 2 s probe). They are `nonisolated` and hop to a
//  detached task, the `RemarkableUSBWebBackend.offMain` pattern — never on
//  the main thread.
//

import Foundation
import ImbibRustCore
import ImpressLogging
import ImpressStoreKit
import OSLog

extension RustStoreAdapter {

    // MARK: - Status & devices

    /// The mirror subsystem's one status read (`eink-status`).
    public func einkStatus() -> EInkStatusSnapshot? {
        do {
            return EInkStatusSnapshot(from: try imbibStore.einkStatus())
        } catch {
            Logger.library.errorCapture("eink.status failed: \(error)", category: "eink")
            return nil
        }
    }

    /// `einkStatus()` off the main thread, for `EInkMirrorModel.refresh()`
    /// and the automation router.
    nonisolated public func einkStatusBackground() async -> EInkStatusSnapshot? {
        await Task.detached(priority: .utility) { [self] in
            do {
                return EInkStatusSnapshot(from: try self.imbibStore.einkStatus())
            } catch {
                Logger.library.errorCapture("eink.status failed: \(error)", category: "eink")
                return nil
            }
        }.value
    }

    public func einkDevices() -> [EInkDeviceRecord] {
        do {
            return try imbibStore.einkDevices().map(EInkDeviceRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.devices failed: \(error)", category: "eink")
            return []
        }
    }

    public func einkDevice(id: String) -> EInkDeviceRecord? {
        do {
            return try imbibStore.einkGetDevice(id: id).map(EInkDeviceRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.getDevice failed: \(error)", category: "eink")
            return nil
        }
    }

    /// Create (nil `id`) or update a device record. Every row's marker can
    /// change with the mode, so this is a structural event.
    @discardableResult
    public func einkConfigureDevice(_ input: EInkDeviceConfigInput) -> EInkDeviceRecord? {
        Logger.library.infoCapture(
            "eink.configureDevice id=\(input.id ?? "new") mode=\(input.mirrorMode ?? "-") "
                + "enabled=\(input.enabled.map(String.init) ?? "-")",
            category: "eink")
        do {
            let row = try imbibStore.einkConfigureDevice(input: input.ffi)
            let record = EInkDeviceRecord(from: row)
            didMutate(structural: true)
            Logger.library.infoCapture(
                "eink.configureDevice saved \(record.id) '\(record.name)' mode=\(record.mirrorMode) "
                    + "enabled=\(record.enabled)",
                category: "eink")
            return record
        } catch {
            Logger.library.errorCapture("eink.configureDevice failed: \(error)", category: "eink")
            return nil
        }
    }

    /// Remove a device and its mirror rows. Returns the number of rows removed.
    @discardableResult
    public func einkRemoveDevice(id: String) -> Int {
        do {
            let removed = Int(try imbibStore.einkRemoveDevice(id: id))
            didMutate(structural: true)
            Logger.library.infoCapture("eink.removeDevice \(id): \(removed) row(s) removed", category: "eink")
            return removed
        } catch {
            Logger.library.errorCapture("eink.removeDevice failed: \(error)", category: "eink")
            return 0
        }
    }

    // MARK: - Marks

    /// Mark publications for the tablet (`eink-mark`). nil `deviceId` = the default device.
    @discardableResult
    public func einkMark(ids: [UUID], deviceId: String? = nil) -> EInkMarkOutcome? {
        setEInkMark(ids: ids, deviceId: deviceId, marked: true)
    }

    /// Unmark publications (`eink-unmark`); an uploaded copy is removed on the next sync.
    @discardableResult
    public func einkUnmark(ids: [UUID], deviceId: String? = nil) -> EInkMarkOutcome? {
        setEInkMark(ids: ids, deviceId: deviceId, marked: false)
    }

    private func setEInkMark(ids: [UUID], deviceId: String?, marked: Bool) -> EInkMarkOutcome? {
        let verb = marked ? "eink.mark" : "eink.unmark"
        guard !ids.isEmpty else { return nil }
        // Mutation
        Logger.library.infoCapture(
            "\(verb) requested for \(ids.count) pub(s) device=\(deviceId ?? "default")",
            category: "eink")
        do {
            let publicationIds = ids.map(\.uuidString)
            let row = marked
                ? try imbibStore.einkMark(deviceId: deviceId, publicationIds: publicationIds)
                : try imbibStore.einkUnmark(deviceId: deviceId, publicationIds: publicationIds)
            let outcome = EInkMarkOutcome(from: row)
            // Save
            Logger.library.infoCapture(
                "\(verb) changed=\(outcome.changed.count) unchanged=\(outcome.unchanged.count) "
                    + "awaitingSource=\(outcome.awaitingSource.count) device=\(outcome.deviceId)",
                category: "eink")
            if !outcome.changed.isEmpty {
                didMutate(structural: false, affectedIDs: Set(outcome.changed), kind: .einkMirror)
            }
            return outcome
        } catch {
            Logger.library.errorCapture("\(verb) failed: \(error)", category: "eink")
            return nil
        }
    }

    /// Queue already-mirrored rows for another upload (`eink-resend`).
    @discardableResult
    public func einkResend(mirrorIds: [String]) -> Int {
        guard !mirrorIds.isEmpty else { return 0 }
        do {
            let count = Int(try imbibStore.einkResend(mirrorIds: mirrorIds))
            Logger.library.infoCapture("eink.resend \(count)/\(mirrorIds.count) row(s) queued", category: "eink")
            if count > 0 { didMutate(structural: true) }
            return count
        } catch {
            Logger.library.errorCapture("eink.resend failed: \(error)", category: "eink")
            return 0
        }
    }

    // MARK: - Reads

    /// Mirror rows, optionally filtered by Rust state spelling (`queued`,
    /// `uploaded`, … including `superseded` / `unmarked`, which the marker
    /// enum does not model).
    public func einkListMirrored(state: String? = nil, deviceId: String? = nil) -> [EInkMirrorRecord] {
        do {
            return try imbibStore.einkListMirrored(deviceId: deviceId, state: state)
                .compactMap(EInkMirrorRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.listMirrored failed: \(error)", category: "eink")
            return []
        }
    }

    /// The mirror row for one publication, if any.
    public func einkMirrorRecord(publicationId: UUID, deviceId: String? = nil) -> EInkMirrorRecord? {
        do {
            return try imbibStore.einkMirrorForPublication(
                deviceId: deviceId, publicationId: publicationId.uuidString
            ).flatMap(EInkMirrorRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.mirrorForPublication failed: \(error)", category: "eink")
            return nil
        }
    }

    /// Marker state per publication for the marker device.
    public func einkRowStates(deviceId: String? = nil) -> [UUID: EInkMirrorState] {
        do {
            var states: [UUID: EInkMirrorState] = [:]
            for row in try imbibStore.einkRowStates(deviceId: deviceId) {
                if let id = UUID(uuidString: row.publicationId), let state = EInkMirrorState(rawValue: row.state) {
                    states[id] = state
                }
            }
            return states
        } catch {
            Logger.library.errorCapture("eink.rowStates failed: \(error)", category: "eink")
            return [:]
        }
    }

    /// Marked publications with no local PDF/ePUB (what a fetcher works through).
    public func einkAwaitingSource(deviceId: String? = nil) -> [EInkAwaitingSourceRecord] {
        do {
            return try imbibStore.einkAwaitingSource(deviceId: deviceId)
                .compactMap(EInkAwaitingSourceRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.awaitingSource failed: \(error)", category: "eink")
            return []
        }
    }

    /// The local PDF/ePUB the engine would send for a publication.
    public func einkLocalSource(publicationId: UUID) -> EInkLocalSourceRecord? {
        do {
            return try imbibStore.einkLocalSource(publicationId: publicationId.uuidString)
                .flatMap(EInkLocalSourceRecord.init(from:))
        } catch {
            Logger.library.errorCapture("eink.localSource failed: \(error)", category: "eink")
            return nil
        }
    }

    /// Folders the tablet lacks, parents first (`eink-folder-checklist`).
    public func einkFolderChecklist(deviceId: String? = nil) -> [EInkFolderNeed] {
        do {
            return try imbibStore.einkFolderChecklist(deviceId: deviceId).map(EInkFolderNeed.init(from:))
        } catch {
            Logger.library.errorCapture("eink.folderChecklist failed: \(error)", category: "eink")
            return []
        }
    }

    /// Whether the tablet answers over USB — a 2 s probe, so never on the main thread.
    nonisolated public func einkReachable(deviceId: String? = nil) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            do {
                return try self.imbibStore.einkReachable(deviceId: deviceId)
            } catch {
                Logger.library.debugCapture("eink.reachable probe failed: \(error)", category: "eink")
                return false
            }
        }.value
    }

    // MARK: - Sync (blocking network calls; always off-main)

    /// Run one sync pass against the tablet (`eink-sync`): uploads, removals,
    /// and — when `importAnnotations` — the import of what came back. The
    /// store changes underneath every affected row, so the completion posts
    /// one structural event from the main actor.
    nonisolated public func einkSync(deviceId: String? = nil, import importAnnotations: Bool) async throws -> EInkSyncReport {
        Logger.library.infoCapture(
            "eink.sync starting device=\(deviceId ?? "default") import=\(importAnnotations)",
            category: "eink")
        let report = try await Task.detached(priority: .userInitiated) { [self] in
            EInkSyncReport(from: try self.imbibStore.einkSync(deviceId: deviceId, import: importAnnotations))
        }.value
        Logger.library.infoCapture(
            "eink.sync done device=\(report.deviceId) reachable=\(report.reachable) "
                + "uploaded=\(report.uploaded.count) failed=\(report.failed.count) "
                + "imports=\(report.imports.count) pendingImports=\(report.pendingImports) "
                + "folderNeeds=\(report.folderNeeds.count) in \(Int(report.duration * 1000)) ms",
            category: "eink")
        await notifyMutationFromBackground()
        return report
    }

    /// A dry run of `einkSync` (`eink-plan`): the same report, nothing written or sent.
    nonisolated public func einkPlan(deviceId: String? = nil) async throws -> EInkSyncReport {
        try await Task.detached(priority: .userInitiated) { [self] in
            EInkSyncReport(from: try self.imbibStore.einkPlan(deviceId: deviceId))
        }.value
    }

    // MARK: - Imported annotations

    /// Annotations imported from the tablet for a publication (highlights,
    /// typed text, ink with OCR text), across its primary file.
    public func einkAnnotations(publicationId: UUID) -> [AnnotationModel] {
        do {
            return try imbibStore.einkAnnotationsForPublication(publicationId: publicationId.uuidString)
                .map(AnnotationModel.init(from:))
        } catch {
            Logger.library.errorCapture("eink.annotationsForPublication failed: \(error)", category: "eink")
            return []
        }
    }

    /// Imported ink annotations whose rendered strokes still need reading.
    public func einkPendingOCR(publicationId: UUID? = nil) -> [EInkOCRJob] {
        do {
            return try imbibStore.einkPendingOcr(publicationId: publicationId?.uuidString)
                .compactMap(EInkOCRJob.init(from:))
        } catch {
            Logger.library.errorCapture("eink.pendingOcr failed: \(error)", category: "eink")
            return []
        }
    }

    /// Store the OCR result for an imported ink annotation. Pass the owning
    /// `publicationId` (the job carries it) so the Notes pane's reload is
    /// row-scoped rather than structural.
    @discardableResult
    public func einkCompleteOCR(annotationId: UUID, text: String?, confidence: Double, publicationId: UUID? = nil) -> Bool {
        do {
            try imbibStore.einkCompleteOcr(annotationId: annotationId.uuidString, text: text, confidence: confidence)
            if let publicationId {
                didMutate(structural: false, affectedIDs: [publicationId], kind: .otherField)
            } else {
                didMutate()
            }
            return true
        } catch {
            Logger.library.errorCapture("eink.completeOcr failed: \(error)", category: "eink")
            return false
        }
    }

    /// Append the imported reMarkable notes to the publication's notes
    /// (idempotent; `force` re-appends). Returns whether anything was written.
    @discardableResult
    public func einkAppendNotes(publicationId: UUID, force: Bool = false) -> Bool {
        do {
            let wrote = try imbibStore.einkAppendNotes(publicationId: publicationId.uuidString, force: force)
            Logger.library.infoCapture(
                "eink.appendNotes \(publicationId) force=\(force) wrote=\(wrote)", category: "eink")
            if wrote {
                didMutate(structural: false, affectedIDs: [publicationId], kind: .otherField)
            }
            return wrote
        } catch {
            Logger.library.errorCapture("eink.appendNotes failed: \(error)", category: "eink")
            return false
        }
    }

    /// Absolute path of a linked file, resolved by the store (the annotated
    /// PDF a sync imported, the primary source, …).
    public func resolveLinkedFilePath(linkedFileId: UUID) -> String? {
        do {
            return try imbibStore.resolveLinkedFile(linkedFileId: linkedFileId.uuidString)
        } catch {
            Logger.library.errorCapture("resolveLinkedFile failed: \(error)", category: "eink")
            return nil
        }
    }
}
