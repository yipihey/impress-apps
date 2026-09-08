//
//  EInkSurfaceModelTests.swift
//  PublicationManagerCoreTests
//
//  The logic behind the P8 surfaces (ADR-025), tested where it lives — in
//  plain values the views only render: the Settings pane's folder
//  checklist and read model, the Info section's action availability per
//  state, the Notes section's grouping by page, the import browser's
//  selection → request mapping, the toolbar glyph's state derivation, the
//  PDF switcher's label and default choice, and the persistence layer's
//  "never burn reMarkable rows into the primary PDF" rule.
//

import Foundation
import ImbibRustCore
import XCTest
@testable import PublicationManagerCore

final class EInkSurfaceModelTests: XCTestCase {

    // MARK: - Fixtures

    private func need(_ path: [String], publications: Int = 1) -> EInkFolderNeed {
        EInkFolderNeed(from: FolderNeed(path: path, parentId: nil, publications: UInt32(publications)))
    }

    private func mirrorRow(
        state: String, marked: Bool = true, resend: Bool = false,
        remotePath: String? = "imbib/Library/Cosmology", annotatedFileId: String? = nil,
        lastError: String? = nil
    ) -> EInkMirrorRecord {
        EInkMirrorRecord(from: EinkMirrorRow(
            id: "m-1", publicationId: UUID().uuidString, deviceId: "dev-1", marked: marked, markedAtMs: 1,
            linkedFileId: nil, sourceKind: "pdf", remoteId: "r-1", remoteParentId: nil, remoteName: nil,
            remotePath: remotePath, uploadedSha256: nil, uploadedAtMs: 2, state: state, lastError: lastError,
            attempts: 0, lastAttemptMs: nil, remoteModifiedMs: nil, importedModifiedMs: nil,
            annotatedFileId: annotatedFileId, resend: resend, createdMs: 0, modifiedMs: 0))!
    }

    private func linkedFile(_ name: String, role: String?, isPDF: Bool = true) -> LinkedFileModel {
        LinkedFileModel(from: LinkedFileRow(
            id: UUID().uuidString, filename: name, relativePath: "Papers/\(name)", fileSize: 1000,
            isPdf: isPDF, isLocallyMaterialized: true, pdfCloudAvailable: false, dateAdded: 0,
            fileType: isPDF ? "pdf" : "epub", sha256: nil, displayName: nil, mimeType: nil, role: role,
            sourceDeviceId: nil, sourceRemoteId: nil, sourceRemoteModifiedMs: nil))
    }

    private func annotation(
        type: String, page: Int, contents: String? = nil, selectedText: String? = nil,
        author: String? = AnnotationModel.einkAuthorName, source: String? = "remarkable",
        ocrConfidence: Double? = nil, imagePath: String? = nil, modified: Int64 = 0
    ) -> AnnotationModel {
        AnnotationModel(from: AnnotationRow(
            id: UUID().uuidString, annotationType: type, pageNumber: Int32(page), boundsJson: nil, color: nil,
            contents: contents, selectedText: selectedText, authorName: author, dateCreated: 0, dateModified: modified,
            linkedFileId: UUID().uuidString, source: source, sourceDeviceId: nil, sourceRemoteId: nil,
            sourcePageId: nil, sourceItemId: nil, imagePath: imagePath, pen: nil, strokesHash: nil,
            ocrConfidence: ocrConfidence, importedAtMs: nil))
    }

    private func localSource() -> EInkLocalSourceRecord {
        EInkLocalSourceRecord(from: EinkLocalSource(
            linkedFileId: UUID().uuidString, kind: "pdf", filename: "Abel_2026_Paper.pdf", relativePath: nil, sha256: nil))!
    }

    private func status(devices: [EInkDeviceRecord], defaultId: String?, markerId: String?, counts: EinkCounts? = nil) -> EInkStatusSnapshot {
        let rows = devices.map { device -> EinkDeviceRow in
            EinkDeviceRow(
                id: device.id, name: device.name, transport: device.transport, baseUrl: device.baseURL,
                mirrorMode: device.mirrorMode, rootFolderName: device.rootFolderName,
                mirrorCollections: device.mirrorCollections, includeLibraryLevel: device.includeLibraryLevel,
                includeInbox: device.includeInbox, folderStrategy: device.folderStrategy,
                uploadFormat: device.uploadFormat, autoFetchSource: device.autoFetchSource,
                importAnnotatedPdf: device.importAnnotatedPDF, importRmdoc: device.importRmdoc,
                importHighlights: device.importHighlights, importInk: device.importInk,
                importTypedText: device.importTypedText, runOcr: device.runOCR,
                autoImportOnConnect: device.autoImportOnConnect, enabled: device.enabled,
                lastSyncAtMs: nil, lastSeenAtMs: nil, syncStartedAtMs: nil, lastError: device.lastError, createdMs: 0)
        }
        let counts = counts ?? EinkCounts(
            queued: 2, awaitingSource: 1, awaitingFolder: 3, uploaded: 7, stale: 1, removedOnDevice: 0,
            failed: 1, superseded: 0, unmarked: 0, newAnnotations: 0)
        return EInkStatusSnapshot(from: EinkStatus(
            devices: rows, markerDeviceId: markerId, defaultDeviceId: defaultId, counts: counts,
            lastSyncAtMs: nil, lastError: nil, legacyMarkerRows: 0))
    }

    // MARK: - Folder checklist

    func testChecklistListsParentsFirstAndCopyTextIsIndented() {
        let needs = [
            need(["imbib", "Library", "Cosmology", "CMB"], publications: 2),
            need(["imbib", "Library"], publications: 1),
            need(["imbib", "Library", "Cosmology"], publications: 4),
            need(["imbib", "Library", "Astro"], publications: 1),
        ]
        let checklist = EInkFolderChecklist(needs)

        XCTAssertEqual(checklist.lines.map(\.name), ["Library", "Astro", "Cosmology", "CMB"],
                       "shallower folders first, siblings by name")
        XCTAssertEqual(checklist.lines.map(\.depth), [1, 2, 2, 3])
        XCTAssertEqual(checklist.waitingPublications, 8)
        XCTAssertEqual(checklist.lines.first?.parentPath, "imbib")

        let text = checklist.copyText.split(separator: "\n").map(String.init)
        XCTAssertEqual(text.count, 4)
        XCTAssertEqual(text[0], "  Library  (imbib › Library; 1 paper)")
        XCTAssertEqual(text[3], "      CMB  (imbib › Library › Cosmology › CMB; 2 papers)")
    }

    func testEmptyChecklist() {
        let checklist = EInkFolderChecklist([])
        XCTAssertTrue(checklist.isEmpty)
        XCTAssertEqual(checklist.copyText, "")
        XCTAssertEqual(checklist.waitingPublications, 0)
    }

    // MARK: - Pane model

    func testPaneModelPicksTheUSBDeviceAndHidesTheChecklistUnderRmdoc() {
        var usb = EInkTestSupport.deviceRecord(id: "usb-1")
        var cloud = EInkTestSupport.deviceRecord(id: "cloud-1")
        cloud.transport = "cloud"
        usb.folderStrategy = "rmdoc"

        let rmdoc = EInkUSBDevicePaneModel(status: status(devices: [cloud, usb], defaultId: "cloud-1", markerId: "usb-1"))
        XCTAssertEqual(rmdoc?.device.id, "usb-1", "a non-USB default device is not the card's device")
        XCTAssertFalse(rmdoc?.showsFolderChecklist ?? true, "rmdoc creates folders itself")
        XCTAssertEqual(rmdoc?.mode, .individual)

        usb.folderStrategy = "checklist"
        usb.mirrorMode = "all"
        let checklist = EInkUSBDevicePaneModel(status: status(devices: [usb], defaultId: "usb-1", markerId: nil))
        XCTAssertTrue(checklist?.showsFolderChecklist ?? false)
        XCTAssertEqual(checklist?.mode, .all)

        XCTAssertNil(EInkUSBDevicePaneModel(status: status(devices: [cloud], defaultId: "cloud-1", markerId: nil)),
                     "no USB device → no card (the pane offers Add reMarkable (USB))")
        XCTAssertNil(EInkUSBDevicePaneModel(status: nil))
    }

    func testPaneCountersFollowTheSnapshotInDisplayOrder() {
        let usb = EInkTestSupport.deviceRecord(id: "usb-1")
        let pane = EInkUSBDevicePaneModel(status: status(devices: [usb], defaultId: "usb-1", markerId: "usb-1"))!
        XCTAssertEqual(pane.counters.map(\.label), ["Queued", "On tablet", "Awaiting PDF", "Awaiting folder", "Stale", "Failed"])
        XCTAssertEqual(pane.counters.map(\.value), [2, 7, 1, 3, 1, 1])
    }

    func testModeFooterNamesTheMarkerAndTheKeys() {
        let individual = EInkUSBDevicePaneModel.modeFooter(for: .individual)
        XCTAssertTrue(individual.contains("⌃⌘E"))
        XCTAssertTrue(individual.contains("marker"))
        XCTAssertTrue(EInkUSBDevicePaneModel.modeFooter(for: .all).contains("no marker"))
        XCTAssertEqual(EInkUSBDevicePaneModel.MirrorMode.all.title, "Mirror everything with a PDF or ePUB")
        XCTAssertEqual(EInkUSBDevicePaneModel.MirrorMode.individual.title, "Only papers I choose")
    }

    func testAddingAReMarkableDefaultsToUSBIndividualModeWithEveryImportOn() {
        let input = EInkUSBDeviceCreation.defaultInput()
        XCTAssertNil(input.id, "nil id creates a record")
        XCTAssertEqual(input.transport, "usb")
        XCTAssertEqual(input.mirrorMode, "individual")
        XCTAssertEqual(input.rootFolderName, "imbib")
        XCTAssertEqual(input.mirrorCollections, true)
        XCTAssertEqual(input.enabled, true)
        XCTAssertEqual(input.importAnnotatedPDF, true)
        XCTAssertEqual(input.importHighlights, true)
        XCTAssertEqual(input.importInk, true)
        XCTAssertEqual(input.importTypedText, true)
        XCTAssertEqual(input.runOCR, true)
        XCTAssertEqual(input.autoImportOnConnect, true)
    }

    // MARK: - Info section

    func testInfoSectionActionsPerState() {
        func actions(_ record: EInkMirrorRecord?, individual: Bool = true, annotated: Bool = false) -> [EInkMirrorSectionModel.Action] {
            EInkMirrorSectionModel(
                record: record, showsIndividualControls: individual, source: localSource(),
                annotatedFile: annotated ? linkedFile("rm.pdf", role: "eink-annotated") : nil).actions
        }

        XCTAssertEqual(actions(nil), [.mirror], "not mirrored, individual mode → Mirror")
        XCTAssertEqual(actions(nil, individual: false), [], "all mode: the engine decides")
        XCTAssertEqual(actions(mirrorRow(state: "queued")), [.remove], "queued: nothing on the tablet yet")
        XCTAssertEqual(actions(mirrorRow(state: "awaiting_source")), [.remove])
        XCTAssertEqual(actions(mirrorRow(state: "uploaded")), [.remove, .updateOnTablet, .importAnnotations])
        XCTAssertEqual(actions(mirrorRow(state: "stale")), [.remove, .updateOnTablet, .importAnnotations])
        XCTAssertEqual(actions(mirrorRow(state: "uploaded", resend: true)), [.remove, .importAnnotations],
                       "a queued resend is not offered twice")
        XCTAssertEqual(actions(mirrorRow(state: "uploaded"), individual: false), [.updateOnTablet, .importAnnotations])
        XCTAssertEqual(actions(mirrorRow(state: "uploaded"), annotated: true),
                       [.remove, .updateOnTablet, .importAnnotations, .showAnnotatedPDF])
        XCTAssertEqual(actions(mirrorRow(state: "unmarked", marked: false), annotated: true), [.mirror, .showAnnotatedPDF],
                       "the rendition outlives the mark")
        XCTAssertEqual(actions(mirrorRow(state: "failed", lastError: "HTTP 500")), [.remove])
    }

    func testInfoSectionTitlesAndSourceLine() {
        let mirrored = EInkMirrorSectionModel(record: mirrorRow(state: "uploaded"), showsIndividualControls: true, source: localSource(), annotatedFile: nil)
        XCTAssertEqual(mirrored.title, EInkMirrorState.uploaded.label)
        XCTAssertEqual(mirrored.sourceLine, "PDF · Abel_2026_Paper.pdf")
        XCTAssertTrue(mirrored.isMirrored)

        let unmarked = EInkMirrorSectionModel(record: mirrorRow(state: "unmarked", marked: false), showsIndividualControls: true, source: nil, annotatedFile: nil)
        XCTAssertEqual(unmarked.title, "Removed from reMarkable")
        XCTAssertFalse(unmarked.isMirrored)
        XCTAssertNil(unmarked.sourceLine)

        let none = EInkMirrorSectionModel(record: nil, showsIndividualControls: false, source: nil, annotatedFile: nil)
        XCTAssertEqual(none.title, "Not mirrored")
        XCTAssertEqual(none.systemImage, "rectangle.portrait")
    }

    // MARK: - Notes section

    func testNotesSectionGroupsByPageAndTypesRows() {
        let rows = [
            annotation(type: "ink", page: 4, contents: "read me", ocrConfidence: 0.87, imagePath: "eink/ink-1.png", modified: 5),
            annotation(type: "highlight", page: 0, selectedText: "dark matter halo", modified: 2),
            annotation(type: "ink", page: 4, modified: 1),
            annotation(type: "freeText", page: 0, contents: "typed on the tablet", modified: 3),
            annotation(type: "highlight", page: 2, contents: "In imbib", author: "My Mac", source: nil),
        ]
        let model = EInkNotesSectionModel(annotations: rows)

        XCTAssertEqual(model.groups.map(\.page), [1, 5], "0-based store pages shown 1-based; imbib's own row excluded")
        XCTAssertEqual(model.rowCount, 4)
        XCTAssertEqual(model.unreadInkCount, 1)

        let first = model.groups[0].rows
        XCTAssertEqual(first.map(\.kind), [.highlight, .typed], "within a page, oldest first")
        XCTAssertEqual(first[0].text, "dark matter halo")
        XCTAssertEqual(first[1].text, "typed on the tablet")

        let ink = model.groups[1].rows
        XCTAssertEqual(ink.map(\.kind), [.inkUnread, .inkRead])
        XCTAssertNil(ink[0].text)
        XCTAssertEqual(ink[0].placeholder, "Handwriting (not read yet)")
        XCTAssertEqual(ink[1].text, "read me")
        XCTAssertEqual(ink[1].confidenceLabel, "87%")
        XCTAssertEqual(ink[1].imagePath, "eink/ink-1.png")
        XCTAssertNil(ink[0].confidenceLabel)
    }

    func testNotesSectionIsEmptyWithoutImportedRows() {
        let model = EInkNotesSectionModel(annotations: [annotation(type: "highlight", page: 1, author: "Me", source: nil)])
        XCTAssertTrue(model.isEmpty)
    }

    // MARK: - Import browser

    func testImportRequestPrefillsFromResolvedIdsAndHonoursOverrides() {
        let library = UUID(), collection = UUID(), otherLibrary = UUID(), otherCollection = UUID()
        let inTree = EInkUnmatchedDocument(
            remoteId: "r-1", name: "Notes", kind: "notebook", remotePath: "imbib/Library/Cosmology",
            inImbibTree: true, libraryId: library, collectionId: collection)
        let elsewhere = EInkUnmatchedDocument(remoteId: "r-2", name: "Paper.pdf", kind: "pdf", remotePath: "Reading", inImbibTree: false)

        let resolved = EInkImportRequest.make(document: inTree, libraryOverride: nil, collectionOverride: nil, kind: .publication)
        XCTAssertEqual(resolved, EInkImportRequest(remoteId: "r-1", libraryId: library, collectionId: collection, kind: .publication))
        XCTAssertFalse(resolved.needsLibrary)

        let asNote = EInkImportRequest.make(document: inTree, libraryOverride: nil, collectionOverride: nil, kind: .note)
        XCTAssertEqual(asNote.kind, .note)
        XCTAssertEqual(asNote.libraryId, library)

        let relibraried = EInkImportRequest.make(document: inTree, libraryOverride: otherLibrary, collectionOverride: nil, kind: .publication)
        XCTAssertEqual(relibraried.libraryId, otherLibrary)
        XCTAssertNil(relibraried.collectionId, "a resolved collection belongs to the resolved library, not the chosen one")

        let recollected = EInkImportRequest.make(document: inTree, libraryOverride: otherLibrary, collectionOverride: otherCollection, kind: .publication)
        XCTAssertEqual(recollected.collectionId, otherCollection)

        let sameLibrary = EInkImportRequest.make(document: inTree, libraryOverride: library, collectionOverride: nil, kind: .publication)
        XCTAssertEqual(sameLibrary.collectionId, collection, "choosing the resolved library keeps the resolved collection")

        let unresolved = EInkImportRequest.make(document: elsewhere, libraryOverride: nil, collectionOverride: nil, kind: .publication)
        XCTAssertTrue(unresolved.needsLibrary, "outside the tree with no chosen library → the engine would refuse")
        XCTAssertFalse(EInkImportRequest.make(document: elsewhere, libraryOverride: library, collectionOverride: nil, kind: .publication).needsLibrary)
    }

    @MainActor
    func testBrowserModelOrdersInTreeFirstAndGatesImportOnLibraries() async {
        let library = UUID()
        let docs = [
            EInkUnmatchedDocument(remoteId: "b", name: "Zeta", kind: "pdf", remotePath: "Reading", inImbibTree: false),
            EInkUnmatchedDocument(remoteId: "a", name: "Alpha", kind: "notebook", remotePath: "imbib/Library", inImbibTree: true, libraryId: library),
            EInkUnmatchedDocument(remoteId: "c", name: "Beta", kind: "epub", remotePath: "imbib/Library", inImbibTree: true, libraryId: library),
        ]
        let calls = CountBox()
        let model = EInkImportBrowserModel(
            list: { docs },
            importDocument: { request in
                calls.record(request.remoteId)
                if request.remoteId == "c" { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
                return EInkDocumentImportOutcome(remoteId: request.remoteId, asKind: request.kind.rawValue, publicationId: UUID(), adoptedExisting: false)
            })
        await model.refresh()
        XCTAssertEqual(model.orderedDocuments.map(\.remoteId), ["a", "c", "b"], "in-tree first, then by path and name")

        model.selection = ["b", "a"]
        XCTAssertEqual(model.selectionNeedingLibrary, 1)
        XCTAssertFalse(model.canImport, "a selected document outside the tree needs a chosen library")

        model.targetLibraryId = library
        XCTAssertEqual(model.selectionNeedingLibrary, 0)
        XCTAssertTrue(model.canImport)
        XCTAssertEqual(model.requests.map(\.remoteId), ["a", "b"], "requests follow list order")

        model.selection = ["a", "c"]
        await model.importSelection()
        XCTAssertEqual(calls.lines, ["a", "c"])
        XCTAssertEqual(model.outcomes["a"]?.isSuccess, true)
        XCTAssertEqual(model.outcomes["c"]?.isSuccess, false, "one failure does not stop the rest")
        XCTAssertTrue(model.selection.isEmpty, "the selection is cleared after a run")
    }

    func testImportOutcomeSummary() {
        XCTAssertEqual(EInkDocumentImportOutcome(remoteId: "r", asKind: "note").summary, "Saved as a note")
        XCTAssertEqual(EInkDocumentImportOutcome(remoteId: "r", asKind: "publication", adoptedExisting: true, annotationsCreated: 2, annotationsUpdated: 1).summary,
                       "Adopted the existing paper · 3 annotations")
        XCTAssertEqual(EInkDocumentImportOutcome(remoteId: "r", asKind: "publication", inkPendingOCR: 4).summary,
                       "Created a new paper · 4 handwritten to read")
    }

    // MARK: - Toolbar glyph

    func testToolbarStatusPrecedence() {
        XCTAssertEqual(EInkToolbarStatus(isSyncing: true, isConnected: false, hasError: true), .syncing)
        XCTAssertEqual(EInkToolbarStatus(isSyncing: false, isConnected: true, hasError: true), .error)
        XCTAssertEqual(EInkToolbarStatus(isSyncing: false, isConnected: true, hasError: false), .connected)
        XCTAssertEqual(EInkToolbarStatus(isSyncing: false, isConnected: false, hasError: false), .disconnected)
    }

    // MARK: - PDF switcher

    func testSwitcherLabelsTheAnnotatedRenditionAndPrefersThePrimary() {
        let primary = linkedFile("Abel_2026_Paper.pdf", role: "primary")
        let legacy = linkedFile("Old.pdf", role: nil)
        let annotated = linkedFile("Abel_2026_Paper-remarkable.pdf", role: "eink-annotated")
        let epub = linkedFile("Book.epub", role: nil, isPDF: false)

        XCTAssertEqual(PublicationPDFSwitcher.label(for: annotated), "reMarkable — annotated")
        XCTAssertEqual(PublicationPDFSwitcher.label(for: primary), "Abel_2026_Paper.pdf")

        XCTAssertEqual([annotated, legacy, primary].preferredPDF?.id, primary.id, "the primary role wins wherever it sits")
        XCTAssertEqual([annotated, legacy].preferredPDF?.id, legacy.id, "an un-roled PDF beats the rendition")
        XCTAssertEqual([annotated].preferredPDF?.id, annotated.id, "the rendition alone is still a PDF to show")
        XCTAssertEqual([epub].preferredPDF?.id, epub.id, "any file as the last resort")
        XCTAssertNil([LinkedFileModel]().preferredPDF)
    }

    // MARK: - Annotation persistence

    func testBurnableSkipsReMarkableRowsByAuthorOrProvenance() {
        let mine = annotation(type: "highlight", page: 0, author: "My Mac", source: nil)
        let byAuthor = annotation(type: "highlight", page: 0, author: AnnotationModel.einkAuthorName, source: nil)
        let byProvenance = annotation(type: "ink", page: 1, author: "somebody", source: "remarkable")
        let legacySpelling = annotation(type: "ink", page: 1, author: "somebody", source: "eink")

        XCTAssertTrue(byAuthor.isEInkAuthored)
        XCTAssertTrue(byProvenance.isFromEInkDevice, "Rust spells the provenance `remarkable`")
        XCTAssertTrue(legacySpelling.isFromEInkDevice)
        XCTAssertFalse(mine.isEInkAuthored)

        let kept = AnnotationPersistence.burnable([mine, byAuthor, byProvenance, legacySpelling])
        XCTAssertEqual(kept.map(\.id), [mine.id], "only imbib's own rows are drawn into the PDF")
    }
}
