//
//  IOSManuscriptList.swift
//  imbib-iOS
//
//  GUI-meld Phase 8. The Manuscripts section list for imbib-iOS. Reads the
//  cross-platform manuscript surface on `RustStoreAdapter`
//  (`queryManuscripts`) — the same `manuscript@1.0.0` items imprint edits —
//  and drives an iOS manuscript detail on tap. Manuscripts are NOT
//  publication-shaped, so this is its own light list rather than a detour
//  through the publication list wrapper.
//

import SwiftUI
import PublicationManagerCore
import OSLog

struct IOSManuscriptList: View {

    /// Selection binding owned by `IOSContentView` — drives the shared
    /// navigation destination into `IOSManuscriptDetailView`.
    @Binding var selectedManuscriptID: UUID?

    private var store: RustStoreAdapter { RustStoreAdapter.shared }

    @State private var manuscripts: [ManuscriptRow] = []
    @State private var searchText = ""

    // New-manuscript prompt.
    @State private var showNewSheet = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if manuscripts.isEmpty {
                ContentUnavailableView {
                    Label("No Manuscripts", systemImage: "doc.text")
                } description: {
                    Text("Manuscripts you create here or in imprint appear in this list.")
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
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
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
        .task { refresh() }
        .onChange(of: store.dataVersion) { _, _ in refresh() }
        .onChange(of: searchText) { _, _ in refresh() }
    }

    private var manuscriptList: some View {
        List {
            ForEach(manuscripts, id: \.id) { m in
                Button {
                    selectedManuscriptID = UUID(uuidString: m.id)
                } label: {
                    manuscriptRow(m)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteManuscripts)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func manuscriptRow(_ m: ManuscriptRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.title.isEmpty ? "Untitled" : m.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                statusBadge(m.status)
                if !m.authorString.isEmpty {
                    Text(m.authorString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if m.revisionCount > 0 {
                    Label("\(m.revisionCount)", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.isEmpty ? "draft" : status)
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
        showNewSheet = false
        guard let row = store.createManuscript(
            title: finalTitle,
            format: "typst",
            body: Self.typstStarter
        ) else {
            Logger.library.errorCapture(
                "IOSManuscriptList: createManuscript returned nil", category: "manuscripts")
            return
        }
        refresh()
        selectedManuscriptID = UUID(uuidString: row.id)
    }

    private func deleteManuscripts(at offsets: IndexSet) {
        let targets = offsets.map { manuscripts[$0].id }
        for idString in targets {
            guard let id = UUID(uuidString: idString) else { continue }
            store.deleteItem(id: id)
        }
        refresh()
    }

    // MARK: - Data

    private func refresh() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            manuscripts = store.queryManuscripts()
        } else {
            manuscripts = store.searchManuscripts(query: trimmed)
        }
    }

    private static let typstStarter = """
    // A new manuscript

    = Introduction

    Start writing here.
    """
}
