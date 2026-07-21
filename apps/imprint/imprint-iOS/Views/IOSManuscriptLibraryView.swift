//
//  IOSManuscriptLibraryView.swift
//  imprint-iOS
//
//  GUI-meld Phase 8. The manuscript library that now fronts imprint-iOS:
//  a store-backed list of manuscripts (from the unified impress store) with
//  a "New Manuscript" action, feeding into `IOSManuscriptEditorHost`. This
//  is what turns imprint-iOS from a single-document editor into a
//  manuscripts app — the same store imbib and macOS imprint read/write.
//

import SwiftUI
import OSLog
import ImpressLogging
import ImprintCore

struct IOSManuscriptLibraryView: View {

    @Bindable private var adapter = ManuscriptStoreAdapter.shared

    /// Navigation path — drives programmatic push into the editor after a
    /// "New Manuscript" create.
    @State private var path = NavigationPath()

    /// Snapshot of the manuscript list, refreshed on `dataVersion` bumps.
    @State private var manuscripts: [ManuscriptModel] = []

    /// New-manuscript title prompt.
    @State private var showNewSheet = false
    @State private var newTitle = ""
    @State private var newFormat: ManuscriptFormat = .typst

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if manuscripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Manuscripts", systemImage: "doc.text")
                    } description: {
                        Text("Create a manuscript to start writing.")
                    } actions: {
                        Button {
                            newTitle = ""
                            showNewSheet = true
                        } label: {
                            Label("New Manuscript", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    manuscriptList
                }
            }
            .navigationTitle("Manuscripts")
            .navigationDestination(for: UUID.self) { id in
                IOSManuscriptEditorHost(manuscriptID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newTitle = ""
                        showNewSheet = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier("toolbar.newManuscript")
                }
            }
            .sheet(isPresented: $showNewSheet) {
                newManuscriptSheet
            }
        }
        .task {
            refresh()
            // Keep the stored-section outline snapshot fresh for multi-section
            // documents. Cheap — a single subscription to the store event bus.
            await OutlineSnapshotMaintainer.shared.start()
        }
        .onChange(of: adapter.dataVersion) { _, _ in
            refresh()
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    // MARK: - List

    private var manuscriptList: some View {
        List {
            ForEach(manuscripts) { m in
                NavigationLink(value: m.id) {
                    manuscriptRow(m)
                }
            }
            .onDelete(perform: deleteManuscripts)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func manuscriptRow(_ m: ManuscriptModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.title.isEmpty ? "Untitled" : m.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                statusBadge(m.status)
                if !m.authors.isEmpty {
                    Text(m.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(m.format.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }

    // MARK: - New Manuscript

    private var newManuscriptSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Untitled", text: $newTitle)
                        .accessibilityIdentifier("newManuscript.title")
                }
                Section("Format") {
                    Picker("Format", selection: $newFormat) {
                        Text("Typst").tag(ManuscriptFormat.typst)
                        Text("LaTeX").tag(ManuscriptFormat.latex)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Manuscript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createManuscript() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createManuscript() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty ? "Untitled" : title
        let format = newFormat
        showNewSheet = false
        do {
            let id = try adapter.createManuscript(
                title: finalTitle,
                format: format,
                body: format == .latex ? Self.latexStarter : Self.typstStarter
            )
            refresh()
            path.append(id)
            Logger.sharedStore.infoCapture(
                "IOSManuscriptLibraryView: created manuscript \(id)",
                category: "manuscript-library"
            )
        } catch {
            Logger.sharedStore.error(
                "IOSManuscriptLibraryView: create failed: \(error.localizedDescription)"
            )
        }
    }

    private func deleteManuscripts(at offsets: IndexSet) {
        let targets = offsets.map { manuscripts[$0].id }
        for id in targets {
            try? adapter.deleteManuscript(id: id)
        }
        refresh()
    }

    // MARK: - Data

    private func refresh() {
        manuscripts = adapter.listManuscripts()
    }

    // MARK: - URL handling

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "imprint", url.host == "open" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return }
        if let uuidString = items.first(where: { $0.name == "documentUUID" })?.value,
           let id = UUID(uuidString: uuidString) {
            path.append(id)
        }
    }

    // MARK: - Starters

    private static let typstStarter = """
    // A new manuscript

    = Introduction

    Start writing here, or tap the quote button to insert a citation from imbib.
    """

    private static let latexStarter = """
    \\documentclass{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage{amsmath, amssymb}

    \\title{Untitled}
    \\author{}
    \\date{\\today}

    \\begin{document}
    \\maketitle

    \\section{Introduction}

    Start writing here.

    \\end{document}
    """
}
