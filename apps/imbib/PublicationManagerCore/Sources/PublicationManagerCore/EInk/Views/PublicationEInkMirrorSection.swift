//
//  PublicationEInkMirrorSection.swift
//  PublicationManagerCore
//
//  The Info-tab section for a paper's relationship with the reMarkable
//  (ADR-025 P8): the mirror state with its glyph and tint, the tablet path,
//  the upload / import dates, the last error, the local source the engine
//  sends, and the verbs — Mirror / Remove (the same store-backed triage
//  action the list uses), "Update on tablet" (`einkResend`), "Import
//  annotations now" (`einkImport(publicationId:)`, off-main) and "Show
//  annotated PDF" (switches to the PDF tab and selects the rendition).
//
//  Shown only while a device is configured (`EInkMirrorModel.isConfigured`);
//  renders nothing otherwise, like `CitedInManuscriptsSection`. WHICH verbs
//  apply in WHICH state is `EInkMirrorSectionModel`, a plain value with a
//  unit test; the view renders it.
//

import ImpressLogging
import OSLog
import SwiftUI

// MARK: - Model

/// What the section shows and offers for one paper, derived from the mirror
/// row (nil = not mirrored), the mode gate and the local source.
public struct EInkMirrorSectionModel: Sendable, Equatable {

    public enum Action: String, Sendable, CaseIterable, Identifiable {
        /// Mark the paper for the tablet (individual mode, not mirrored).
        case mirror
        /// Unmark — removes the tablet copy on the next sync (individual mode, mirrored).
        case remove
        /// Queue another upload of a copy that is on the tablet (`einkResend`).
        case updateOnTablet
        /// Pull this paper's annotations back now, whether or not the tablet reports a change.
        case importAnnotations
        /// Open the reMarkable-annotated rendition in the PDF tab.
        case showAnnotatedPDF

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .mirror: return EInkMirrorState.mirrorVerb
            case .remove: return "Remove from reMarkable"
            case .updateOnTablet: return "Update on tablet"
            case .importAnnotations: return "Import annotations now"
            case .showAnnotatedPDF: return "Show annotated PDF"
            }
        }

        public var systemImage: String {
            switch self {
            case .mirror: return "rectangle.portrait.badge.plus"
            case .remove: return "rectangle.portrait.slash"
            case .updateOnTablet: return "arrow.up.circle"
            case .importAnnotations: return "arrow.down.circle"
            case .showAnnotatedPDF: return "doc.richtext"
            }
        }
    }

    public let record: EInkMirrorRecord?
    /// A device in individual mode is configured, so Mirror / Remove apply.
    public let showsIndividualControls: Bool
    /// The local PDF/ePUB the engine would send, if any.
    public let source: EInkLocalSourceRecord?
    /// The reMarkable-annotated rendition, if a sync imported one.
    public let annotatedFile: LinkedFileModel?

    public init(
        record: EInkMirrorRecord?,
        showsIndividualControls: Bool,
        source: EInkLocalSourceRecord?,
        annotatedFile: LinkedFileModel?
    ) {
        self.record = record
        self.showsIndividualControls = showsIndividualControls
        self.source = source
        self.annotatedFile = annotatedFile
    }

    public var state: EInkMirrorState? { record?.state }

    /// True while the row is marked, in any state the marker models.
    public var isMirrored: Bool { record?.marked == true && state != nil }

    /// The headline: the state's label, or the un-mirrored wording.
    public var title: String {
        if let state { return state.label }
        if record?.stateRaw == "unmarked" { return "Removed from reMarkable" }
        return showsIndividualControls ? "Not on reMarkable" : "Not mirrored"
    }

    public var explanation: String {
        if let state { return state.explanation }
        return showsIndividualControls
            ? "Mark it to keep a copy on the tablet."
            : "Every paper with a PDF or ePUB is mirrored; this one has no file yet."
    }

    public var systemImage: String { state?.systemImage ?? "rectangle.portrait" }

    /// The "PDF · filename" line, or nil without a local source.
    public var sourceLine: String? {
        guard let source else { return nil }
        return "\(source.kind.uppercased()) · \(source.filename)"
    }

    /// The verbs, in display order. Rules:
    /// - Mirror / Remove only in individual mode (in `all` mode the engine decides);
    /// - Update on tablet only for a copy that is on the tablet (`uploaded` / `stale`)
    ///   and not already queued for a resend;
    /// - Import annotations now for any copy on the tablet;
    /// - Show annotated PDF whenever a rendition exists, mirrored or not.
    public var actions: [Action] {
        var actions: [Action] = []
        if showsIndividualControls {
            actions.append(isMirrored ? .remove : .mirror)
        }
        if let state, state.isOnDevice {
            if record?.resend != true {
                actions.append(.updateOnTablet)
            }
            actions.append(.importAnnotations)
        }
        if annotatedFile != nil {
            actions.append(.showAnnotatedPDF)
        }
        return actions
    }
}

// MARK: - Section

public struct PublicationEInkMirrorSection: View {
    public let publicationID: UUID

    @State private var einkModel = EInkMirrorModel.shared
    @State private var record: EInkMirrorRecord?
    @State private var source: EInkLocalSourceRecord?
    @State private var annotatedFile: LinkedFileModel?
    @State private var isImporting = false
    @State private var lastMessage: String?

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    private var model: EInkMirrorSectionModel {
        EInkMirrorSectionModel(
            record: record,
            showsIndividualControls: einkModel.showsIndividualControls,
            source: source,
            annotatedFile: annotatedFile)
    }

    public var body: some View {
        if einkModel.isConfigured {
            content
                .task(id: publicationID) { reload() }
                .task(id: publicationID) {
                    // Re-read when THIS paper's mirror row changes (a sync ran,
                    // a mark toggled) or the store changed structurally.
                    for await event in ImbibImpressStore.shared.events.subscribe() {
                        switch event {
                        case .structural:
                            reload()
                        case .itemsMutated(_, let ids) where ids.contains(publicationID):
                            reload()
                        default:
                            continue
                        }
                    }
                }
        }
    }

    private var content: some View {
        let model = self.model
        return VStack(alignment: .leading, spacing: 8) {
            Text("reMarkable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.systemImage)
                    .foregroundStyle(model.state?.color ?? .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .fontWeight(.medium)
                    Text(model.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            detailRows(model)

            if !model.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.actions) { action in
                        Button {
                            perform(action)
                        } label: {
                            if action == .importAnnotations && isImporting {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("Importing…")
                                }
                            } else {
                                Label(action.title, systemImage: action.systemImage)
                            }
                        }
                        .controlSize(.small)
                        .disabled(isImporting && action == .importAnnotations)
                    }
                }
                .padding(.top, 2)
            }

            if let lastMessage {
                Text(lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("reMarkable: \(model.title)")
    }

    @ViewBuilder
    private func detailRows(_ model: EInkMirrorSectionModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let path = model.record?.remotePath, !path.isEmpty {
                row("On tablet", path.replacingOccurrences(of: "/", with: " › "), mono: false)
            }
            if let source = model.sourceLine {
                row("Source", source, mono: false)
            }
            if let at = model.record?.uploadedAt {
                row("Uploaded", at.formatted(date: .abbreviated, time: .shortened), mono: false)
            }
            if let at = model.record?.importedModifiedAt {
                row("Annotations imported", at.formatted(date: .abbreviated, time: .shortened), mono: false)
            }
            if let error = model.record?.lastError, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 26)
    }

    private func row(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: Data

    private func reload() {
        let adapter = RustStoreAdapter.shared
        record = adapter.einkMirrorRecord(publicationId: publicationID)
        source = adapter.einkLocalSource(publicationId: publicationID)
        annotatedFile = adapter.listLinkedFiles(publicationId: publicationID).first(where: \.isEInkAnnotated)
        // Display: what the section renders after a read.
        Logger.library.debugCapture(
            "eink.infoSection \(publicationID) state=\(record?.stateRaw ?? "none") source=\(source?.filename ?? "none") "
                + "annotated=\(annotatedFile?.filename ?? "none")",
            category: "eink")
    }

    // MARK: Actions

    private func perform(_ action: EInkMirrorSectionModel.Action) {
        let id = publicationID
        Logger.library.infoCapture("eink.infoSection \(action.rawValue) for \(id)", category: "eink")
        switch action {
        case .mirror, .remove:
            RecordTriageActions
                .storeBacked(descriptor: PublicationRecordKind.descriptor)
                .onToggleEink([id], action == .mirror)
            Task { await EInkServices.shared.coordinator?.nudge(.marked) }
        case .updateOnTablet:
            guard let mirrorId = record?.id else { return }
            let queued = RustStoreAdapter.shared.einkResend(mirrorIds: [mirrorId])
            lastMessage = queued > 0 ? "Queued; sent on the next sync." : "Nothing to resend."
            if queued > 0 {
                Task { await EInkServices.shared.coordinator?.nudge(.marked) }
            }
        case .importAnnotations:
            importAnnotations(id)
        case .showAnnotatedPDF:
            guard let file = annotatedFile else { return }
            NotificationCenter.default.post(name: .showPDFTab, object: nil, userInfo: ["linkedFileID": file.id])
        }
    }

    private func importAnnotations(_ id: UUID) {
        isImporting = true
        lastMessage = nil
        Task {
            do {
                let report = try await RustStoreAdapter.shared.einkImport(publicationId: id)
                let mine = report.imports.first { $0.publicationId == id }
                if !report.reachable {
                    lastMessage = "The tablet did not answer over USB."
                } else if let mine {
                    let count = mine.created + mine.updated
                    lastMessage = count == 0
                        ? "Nothing new on the tablet."
                        : "\(count) annotation\(count == 1 ? "" : "s") imported"
                            + (mine.inkPendingOCR > 0 ? "; \(mine.inkPendingOCR) handwritten being read." : ".")
                    if mine.inkPendingOCR > 0 {
                        await EInkServices.shared.ocr?.run(publicationIds: [id])
                    }
                } else {
                    lastMessage = "No copy of this paper on the tablet to import from."
                }
            } catch {
                lastMessage = error.localizedDescription
            }
            isImporting = false
            reload()
        }
    }
}
