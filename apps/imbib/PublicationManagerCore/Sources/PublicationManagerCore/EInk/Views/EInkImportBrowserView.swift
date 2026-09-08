//
//  EInkImportBrowserView.swift
//  PublicationManagerCore
//
//  "Import from reMarkable" (ADR-025 P8): the tablet's documents that no
//  mirror row accounts for — notebooks the user wrote, PDFs and ePUBs they
//  put there themselves — listed in-tree first with the library and
//  collection their folder names resolve to, multi-selected, and brought
//  in one by one through `einkImportDocument` as publications (a notebook
//  becomes `@misc` with the rendered PDF; a PDF whose bytes match a file
//  already here adopts that paper) or as note artifacts. Per-document
//  outcomes stay in the sheet.
//
//  Replaces `RemarkableDocumentBrowserView` (ADR-019), which walked the
//  cloud backend's folder tree and whose Import button simulated a second
//  of work. Reached from Settings › E-Ink, Paper ▸ Import from reMarkable…
//  and the palette (`.showEInkImportBrowser`, presented by `ContentView`).
//
//  Listing and importing talk to the tablet over USB, so both run off the
//  main thread (`einkListUnmatched` / `einkImportDocument` are
//  `nonisolated` + detached); the model is `@MainActor` and only holds
//  results. The selection → request mapping is `EInkImportRequest.make`,
//  a pure function with a unit test.
//

import ImpressKit
import ImpressLogging
import OSLog
import SwiftUI

// MARK: - Request mapping

/// One `eink-import-document` call, derived from a selected document and
/// the sheet's target pickers.
public struct EInkImportRequest: Sendable, Equatable, Hashable {

    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case publication
        case note
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .publication: return "Publication"
            case .note: return "Note"
            }
        }
    }

    public let remoteId: String
    public let libraryId: UUID?
    public let collectionId: UUID?
    public let kind: Kind

    /// The rule: the sheet's explicit choice wins; otherwise the ids the
    /// tablet's folder names resolved to; a document outside the tree with
    /// no chosen library yields a nil library, which the engine refuses —
    /// `needsLibrary` says so before the click.
    public static func make(
        document: EInkUnmatchedDocument,
        libraryOverride: UUID?,
        collectionOverride: UUID?,
        kind: Kind
    ) -> EInkImportRequest {
        let library = libraryOverride ?? document.libraryId
        // A chosen library replaces the resolved collection too: a resolved
        // collection belongs to the resolved library, not the chosen one.
        let collection: UUID?
        if let collectionOverride {
            collection = collectionOverride
        } else if libraryOverride != nil, libraryOverride != document.libraryId {
            collection = nil
        } else {
            collection = document.collectionId
        }
        return EInkImportRequest(remoteId: document.remoteId, libraryId: library, collectionId: collection, kind: kind)
    }

    /// True when the engine would refuse: no library resolved or chosen.
    public var needsLibrary: Bool { libraryId == nil }
}

// MARK: - Model

@MainActor
@Observable
public final class EInkImportBrowserModel {

    public enum Outcome: Sendable, Equatable {
        case imported(EInkDocumentImportOutcome)
        case failed(String)

        public var isSuccess: Bool {
            if case .imported = self { return true }
            return false
        }
    }

    public private(set) var documents: [EInkUnmatchedDocument] = []
    public private(set) var libraries: [LibraryModel] = []
    public private(set) var collections: [CollectionModel] = []
    public private(set) var isLoading = false
    public private(set) var isImporting = false
    public private(set) var loadError: String?
    public var selection: Set<String> = []
    public var kind: EInkImportRequest.Kind = .publication
    /// nil = "as resolved from the tablet's folders".
    public var targetLibraryId: UUID? {
        didSet {
            if targetLibraryId != oldValue {
                targetCollectionId = nil
                reloadCollections()
            }
        }
    }
    public var targetCollectionId: UUID?
    /// Per remote id, the outcome of the last import click.
    public private(set) var outcomes: [String: Outcome] = [:]
    /// The document whose import is running now (for the progress line).
    public private(set) var importingRemoteId: String?

    private let list: @Sendable () async -> [EInkUnmatchedDocument]
    private let importDocument: @Sendable (EInkImportRequest) async throws -> EInkDocumentImportOutcome

    public init(
        list: @escaping @Sendable () async -> [EInkUnmatchedDocument] = { await RustStoreAdapter.shared.einkListUnmatched() },
        importDocument: @escaping @Sendable (EInkImportRequest) async throws -> EInkDocumentImportOutcome = { request in
            try await RustStoreAdapter.shared.einkImportDocument(
                remoteId: request.remoteId,
                libraryId: request.libraryId,
                collectionId: request.collectionId,
                asKind: request.kind.rawValue)
        }
    ) {
        self.list = list
        self.importDocument = importDocument
    }

    /// In-tree first, then by path and name — the order the list shows.
    public var orderedDocuments: [EInkUnmatchedDocument] {
        documents.sorted { lhs, rhs in
            if lhs.inImbibTree != rhs.inImbibTree { return lhs.inImbibTree }
            if lhs.remotePath != rhs.remotePath {
                return lhs.remotePath.localizedStandardCompare(rhs.remotePath) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public var selectedDocuments: [EInkUnmatchedDocument] {
        orderedDocuments.filter { selection.contains($0.remoteId) }
    }

    /// The requests the Import button would send, in list order.
    public var requests: [EInkImportRequest] {
        selectedDocuments.map {
            EInkImportRequest.make(document: $0, libraryOverride: targetLibraryId, collectionOverride: targetCollectionId, kind: kind)
        }
    }

    /// Documents in the selection the engine would refuse for want of a library.
    public var selectionNeedingLibrary: Int { requests.filter(\.needsLibrary).count }

    public var canImport: Bool { !isImporting && !requests.isEmpty && selectionNeedingLibrary == 0 }

    public func loadLibraries() {
        libraries = RustStoreAdapter.shared.listLibraries().filter { !$0.isInbox }
        reloadCollections()
    }

    private func reloadCollections() {
        guard let targetLibraryId else {
            collections = []
            return
        }
        collections = RustStoreAdapter.shared.listCollections(libraryId: targetLibraryId).filter { !$0.isSmart }
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        let rows = await list()
        documents = rows
        selection = selection.intersection(rows.map(\.remoteId))
        isLoading = false
        Logger.library.infoCapture(
            "eink.browser listed \(rows.count) unmatched document(s), \(rows.filter(\.inImbibTree).count) in tree",
            category: "eink")
    }

    /// Prefill the target pickers from ONE selected document's resolved ids
    /// (the way the sheet opens on a folder that maps to a collection).
    public func prefillTargets(from document: EInkUnmatchedDocument) {
        guard targetLibraryId == nil, let library = document.libraryId else { return }
        targetLibraryId = library
        targetCollectionId = document.collectionId
    }

    /// Import every selected document, in order, recording each outcome.
    /// Errors are per document: one failure does not stop the rest.
    public func importSelection() async {
        guard canImport else { return }
        isImporting = true
        defer {
            isImporting = false
            importingRemoteId = nil
        }
        let requests = self.requests
        Logger.library.infoCapture("eink.browser importing \(requests.count) document(s) as \(kind.rawValue)", category: "eink")
        var imported = 0
        for request in requests {
            importingRemoteId = request.remoteId
            do {
                let outcome = try await importDocument(request)
                outcomes[request.remoteId] = .imported(outcome)
                imported += 1
            } catch {
                outcomes[request.remoteId] = .failed(error.localizedDescription)
                Logger.library.errorCapture("eink.browser import \(request.remoteId) failed: \(error.localizedDescription)", category: "eink")
            }
        }
        Logger.library.infoCapture("eink.browser imported \(imported)/\(requests.count)", category: "eink")
        // Imported documents now have a mirror row; re-list so they drop out.
        selection = []
        await refresh()
    }
}

// MARK: - View

public struct EInkImportBrowserView: View {

    @Binding var isPresented: Bool
    @State private var model: EInkImportBrowserModel

    public init(isPresented: Binding<Bool>, model: EInkImportBrowserModel? = nil) {
        _isPresented = isPresented
        _model = State(wrappedValue: model ?? EInkImportBrowserModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoading && model.documents.isEmpty {
                loading
            } else if model.documents.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            targets
            Divider()
            footer
        }
        .impressResizableSheet(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 560)
        .task {
            model.loadLibraries()
            await model.refresh()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from reMarkable")
                    .font(.headline)
                Text("Notebooks, PDFs and ePUBs on the tablet that imbib does not know yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isLoading || model.isImporting)
        }
        .padding()
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Reading the tablet over USB…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing to import", systemImage: "rectangle.portrait")
        } description: {
            Text("Every document on the tablet is already mirrored, or the tablet did not answer. Connect the cable, turn on the USB web interface, and Refresh.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $model.selection) {
            let ordered = model.orderedDocuments
            let inTree = ordered.filter(\.inImbibTree)
            let elsewhere = ordered.filter { !$0.inImbibTree }
            if !inTree.isEmpty {
                Section("In imbib's folders on the tablet") {
                    ForEach(inTree) { document in
                        row(document).tag(document.remoteId)
                    }
                }
            }
            if !elsewhere.isEmpty {
                Section("Elsewhere on the tablet") {
                    ForEach(elsewhere) { document in
                        row(document).tag(document.remoteId)
                    }
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: model.selection) { _, newValue in
            if newValue.count == 1, let id = newValue.first,
               let document = model.documents.first(where: { $0.remoteId == id }) {
                model.prefillTargets(from: document)
            }
        }
    }

    @ViewBuilder
    private func row(_ document: EInkUnmatchedDocument) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: document.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(document.kind.uppercased())
                    Text(document.remotePath.isEmpty ? "Top level" : document.remotePath.replacingOccurrences(of: "/", with: " › "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if document.pageCount > 0 {
                        Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
                    }
                    Text(document.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let resolved = resolvedTarget(document) {
                    Text(resolved)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                outcomeLine(document)
            }
            Spacer(minLength: 0)
            if model.importingRemoteId == document.remoteId {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func resolvedTarget(_ document: EInkUnmatchedDocument) -> String? {
        guard let libraryId = document.libraryId else { return nil }
        let library = model.libraries.first { $0.id == libraryId }?.name ?? "a library"
        if let collectionId = document.collectionId {
            let collection = RustStoreAdapter.shared.listCollections(libraryId: libraryId).first { $0.id == collectionId }?.name
            return "→ \(library)" + (collection.map { " › \($0)" } ?? "")
        }
        return "→ \(library)"
    }

    @ViewBuilder
    private func outcomeLine(_ document: EInkUnmatchedDocument) -> some View {
        if let outcome = model.outcomes[document.remoteId] {
            switch outcome {
            case .imported(let result):
                Label(result.summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var targets: some View {
        HStack(spacing: 12) {
            Picker("Library", selection: $model.targetLibraryId) {
                Text("As resolved from the folders").tag(UUID?.none)
                ForEach(model.libraries) { library in
                    Text(library.name).tag(UUID?.some(library.id))
                }
            }
            .frame(maxWidth: 260)

            Picker("Collection", selection: $model.targetCollectionId) {
                Text(model.targetLibraryId == nil ? "As resolved" : "Library root").tag(UUID?.none)
                ForEach(model.collections) { collection in
                    Text(collection.name).tag(UUID?.some(collection.id))
                }
            }
            .frame(maxWidth: 260)
            .disabled(model.targetLibraryId == nil)

            Picker("Import as", selection: $model.kind) {
                ForEach(EInkImportRequest.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if model.selectionNeedingLibrary > 0 {
                Label("\(model.selectionNeedingLibrary) selected document\(model.selectionNeedingLibrary == 1 ? " is" : "s are") outside imbib's folders — choose a library.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let imported = model.outcomes.values.filter(\.isSuccess).count
                if imported > 0 {
                    Text("\(imported) imported this session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await model.importSelection() }
            } label: {
                if model.isImporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Importing…")
                    }
                } else {
                    Text(model.kind == .note ? "Import as Notes" : "Import")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canImport)
        }
        .padding()
    }
}
