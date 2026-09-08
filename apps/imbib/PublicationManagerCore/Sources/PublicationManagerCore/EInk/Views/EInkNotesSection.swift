//
//  EInkNotesSection.swift
//  PublicationManagerCore
//
//  The Notes panel's collapsible "reMarkable" section (ADR-025 P8): what
//  the tablet sent back for this paper, grouped by page — highlights with
//  their text, typed text, handwriting with its OCR text and confidence,
//  and the rendered ink as a thumbnail. Clicking a row moves the PDF beside
//  the panel to that page (`.pdfGoToPage` with the 1-based page, scoped to
//  the paper's primary file). "Append reMarkable notes" writes the dated
//  block into the paper's freeform notes through `einkAppendNotes`, which
//  refuses a duplicate unless forced — the section asks before forcing.
//
//  Rows come from `einkAnnotations(publicationId:)` (the store), never from
//  the PDF: these rows are never drawn into the primary PDF
//  (`AnnotationPersistence.burnable`). The GROUPING is
//  `EInkNotesSectionModel`, a plain value with a unit test.
//

import ImpressLogging
import OSLog
import SwiftUI

// MARK: - Model

/// The imported rows arranged for display: one group per page, in page
/// order, each row typed by what it is.
public struct EInkNotesSectionModel: Sendable, Equatable {

    public enum RowKind: String, Sendable, Equatable {
        /// A highlighter stroke over text; `text` is what it covered.
        case highlight
        /// Text typed on the tablet's keyboard.
        case typed
        /// Handwriting that has been read; `text` is the OCR result.
        case inkRead
        /// Handwriting not yet read (OCR pending or failed).
        case inkUnread
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: RowKind
        /// 1-based page number for display and navigation.
        public let page: Int
        public let text: String?
        /// 0…1 for read ink.
        public let confidence: Double?
        /// Container-relative or absolute path of the rendered strokes (ink rows).
        public let imagePath: String?
        public let pen: String?
        public let date: Date

        public var systemImage: String {
            switch kind {
            case .highlight: return "highlighter"
            case .typed: return "keyboard"
            case .inkRead: return "pencil.and.scribble"
            case .inkUnread: return "pencil.and.outline"
            }
        }

        /// What the row says when it has no text.
        public var placeholder: String {
            switch kind {
            case .highlight: return "Highlight"
            case .typed: return "Typed text"
            case .inkRead: return "Handwriting"
            case .inkUnread: return "Handwriting (not read yet)"
            }
        }

        /// "87%" for read ink, nil otherwise.
        public var confidenceLabel: String? {
            guard kind == .inkRead, let confidence else { return nil }
            return "\(Int((confidence * 100).rounded()))%"
        }
    }

    public struct PageGroup: Sendable, Equatable, Identifiable {
        public let page: Int
        public let rows: [Row]
        public var id: Int { page }
    }

    public let groups: [PageGroup]

    public init(annotations: [AnnotationModel]) {
        let rows = annotations
            .filter(\.isEInkAuthored)
            .map(Self.row(for:))
            .sorted { lhs, rhs in
                if lhs.page != rhs.page { return lhs.page < rhs.page }
                return lhs.date < rhs.date
            }
        var byPage: [Int: [Row]] = [:]
        for row in rows {
            byPage[row.page, default: []].append(row)
        }
        groups = byPage.keys.sorted().map { PageGroup(page: $0, rows: byPage[$0] ?? []) }
    }

    public var isEmpty: Bool { groups.isEmpty }
    public var rowCount: Int { groups.reduce(0) { $0 + $1.rows.count } }
    public var unreadInkCount: Int { groups.flatMap(\.rows).filter { $0.kind == .inkUnread }.count }

    /// One imported annotation → one row. Pages are stored 0-based
    /// (`page_number = redirect_pdf_index`), shown 1-based.
    static func row(for annotation: AnnotationModel) -> Row {
        let kind: RowKind
        let text: String?
        switch annotation.annotationType {
        case "highlight":
            kind = .highlight
            text = firstNonEmpty(annotation.selectedText, annotation.contents)
        case "ink":
            let read = annotation.ocrConfidence != nil && !(annotation.contents ?? "").isEmpty
            kind = read ? .inkRead : .inkUnread
            text = read ? annotation.contents : nil
        default:
            kind = .typed
            text = firstNonEmpty(annotation.contents, annotation.selectedText)
        }
        return Row(
            id: annotation.id,
            kind: kind,
            page: annotation.pageNumber + 1,
            text: text,
            confidence: annotation.ocrConfidence,
            imagePath: annotation.imagePath,
            pen: annotation.pen,
            date: annotation.importedAt ?? annotation.dateModified)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Ink images

/// Resolves an imported ink row's `imagePath` the way the engine records it:
/// absolute as-is, else relative to the paper's library container (the
/// same rule `eink-pending-ocr` applies in Rust: `library_dir_for_write`).
@MainActor
enum EInkInkImageResolver {
    static func url(for path: String?, libraryIDs: [UUID]) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        for libraryID in libraryIDs {
            let url = AttachmentManager.shared.containerURL(for: libraryID).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

// MARK: - Section

struct EInkNotesSection: View {
    let publication: PublicationModel

    @State private var einkModel = EInkMirrorModel.shared
    @State private var model = EInkNotesSectionModel(annotations: [])
    @State private var isExpanded = true
    @State private var isAppending = false
    @State private var confirmForceAppend = false
    @State private var message: String?

    /// Called after the notes were appended, so the host re-reads the note field.
    let onNotesAppended: () -> Void

    var body: some View {
        if einkModel.isConfigured {
            content
                .task(id: publication.id) { reload() }
                .task(id: publication.id) {
                    // Reload on this paper's row events (an import wrote rows,
                    // OCR completed) and on structural events (a sync ran).
                    for await event in ImbibImpressStore.shared.events.subscribe() {
                        switch event {
                        case .structural:
                            reload()
                        case .itemsMutated(_, let ids) where ids.contains(publication.id):
                            reload()
                        default:
                            continue
                        }
                    }
                }
        }
    }

    private var content: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if model.isEmpty {
                Text("Nothing imported from the tablet yet. Highlights, typed text and handwriting appear here after a sync.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.groups) { group in
                        pageGroup(group)
                    }
                    HStack(spacing: 8) {
                        Button {
                            append(force: false)
                        } label: {
                            if isAppending {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("Appending…")
                                }
                            } else {
                                Label("Append reMarkable notes", systemImage: "text.append")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isAppending)
                        .help("Add a dated block with these highlights and notes to the reading notes below. Already-appended imports are skipped.")
                        if let message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        } label: {
            HStack(spacing: 6) {
                Text("reMarkable")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                if model.rowCount > 0 {
                    Text("\(model.rowCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if model.unreadInkCount > 0 {
                    Text("\(model.unreadInkCount) to read")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .confirmationDialog(
            "These reMarkable notes were already appended. Append them again?",
            isPresented: $confirmForceAppend,
            titleVisibility: .visible
        ) {
            Button("Append again") { append(force: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func pageGroup(_ group: EInkNotesSectionModel.PageGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Page \(group.page)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(group.rows) { row in
                Button {
                    goToPage(row.page)
                } label: {
                    rowLabel(row)
                }
                .buttonStyle(.plain)
                .help("Show page \(row.page) in the PDF")
            }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: EInkNotesSectionModel.Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: row.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.text ?? row.placeholder)
                        .font(.callout)
                        .foregroundStyle(row.text == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let confidence = row.confidenceLabel {
                        Text(confidence)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if row.kind == .inkRead || row.kind == .inkUnread,
                   let url = EInkInkImageResolver.url(for: row.imagePath, libraryIDs: publication.libraryIDs) {
                    inkThumbnail(url)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func inkThumbnail(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 80, alignment: .leading)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            default:
                EmptyView()
            }
        }
    }

    // MARK: Data

    private func reload() {
        let rows = RustStoreAdapter.shared.einkAnnotations(publicationId: publication.id)
        model = EInkNotesSectionModel(annotations: rows)
        // Display: what the panel renders after a read.
        Logger.library.debugCapture(
            "eink.notesSection \(publication.id): \(model.rowCount) row(s) on \(model.groups.count) page(s), "
                + "\(model.unreadInkCount) unread ink",
            category: "eink")
    }

    // MARK: Actions

    private func goToPage(_ page: Int) {
        var info: [String: Any] = ["page": page]
        if let primary = publication.linkedFiles.preferredPDF {
            info["linkedFileID"] = primary.id
        }
        NotificationCenter.default.post(name: .pdfGoToPage, object: nil, userInfo: info)
    }

    private func append(force: Bool) {
        let id = publication.id
        isAppending = true
        message = nil
        // `einkAppendNotes` is a main-actor store write (no tablet involved).
        let wrote = RustStoreAdapter.shared.einkAppendNotes(publicationId: id, force: force)
        isAppending = false
        if wrote {
            message = "Appended to the reading notes."
            onNotesAppended()
        } else if force {
            message = "Nothing to append."
        } else {
            confirmForceAppend = true
        }
    }
}
