//
//  JournalManuscriptsListView.swift
//  imbib
//
//  Phase 2 of the impress journal pipeline (per docs/plan-journal-pipeline.md
//  §3.4 + ADR-0011 D8).
//
//  List view shown when the user selects a Journal sidebar status node
//  ("All Manuscripts", "Drafts", "Submitted", etc.). Clicking a row pushes
//  ManuscriptDetailView via NavigationStack.
//
//  This is a Phase 2 minimum-viable surface — sortable / filterable
//  enhancements (search by title, sort by modified date, count badges) are
//  Phase 5 polish work.
//

import SwiftUI
import PublicationManagerCore

struct JournalManuscriptsListView: View {

    /// Optional status filter. `nil` shows all manuscripts.
    let statusFilter: JournalManuscriptStatus?

    @State private var manuscripts: [JournalManuscript] = []
    @State private var isLoading = false
    @State private var navigationPath = NavigationPath()
    @State private var creatingManuscript = false
    @State private var newManuscriptTitle = ""
    @State private var lastError: String?

    private var bridge: ManuscriptBridge { ManuscriptBridge.shared }

    private var emptyMessage: String {
        guard let status = statusFilter else {
            return "No manuscripts yet. Create one with the New Manuscript button below."
        }
        return "No manuscripts in \(status.displayName.lowercased()) yet."
    }

    private var headerTitle: String {
        statusFilter?.displayName ?? "All Manuscripts"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(for: String.self) { manuscriptID in
                ManuscriptDetailView(manuscriptID: manuscriptID)
            }
        }
        .task(id: statusFilter) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .manuscriptDidChange)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(headerTitle).font(.title3).bold()
                Text("\(manuscripts.count) manuscript\(manuscripts.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                creatingManuscript = true
            } label: {
                Label("New Manuscript", systemImage: "plus.circle")
            }
        }
        .padding()
        .padding(.top, 40)   // toolbar overlap clearance
        .sheet(isPresented: $creatingManuscript) {
            createManuscriptSheet
        }
    }

    @ViewBuilder
    private var content: some View {
        if manuscripts.isEmpty && !isLoading {
            ContentUnavailableView(
                headerTitle,
                systemImage: "doc.text.image",
                description: Text(emptyMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if let lastError {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(lastError).font(.caption)
                            Spacer()
                            Button("Dismiss") { self.lastError = nil }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                ForEach(manuscripts) { m in
                    NavigationLink(value: m.id) {
                        manuscriptRow(m)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func manuscriptRow(_ m: JournalManuscript) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: m.status.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title)
                    .font(.body)
                    .lineLimit(2)
                if !m.authors.isEmpty {
                    Text(m.authors.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if statusFilter == nil {
                // Show status only when not already filtering by it
                Text(m.status.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var createManuscriptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Manuscript").font(.title3).bold()
            TextField("Title", text: $newManuscriptTitle)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    newManuscriptTitle = ""
                    creatingManuscript = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await createManuscript() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newManuscriptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func reload() async {
        await MainActor.run { self.isLoading = true }
        let list = await bridge.listManuscripts(status: statusFilter)
        await MainActor.run {
            self.manuscripts = list
            self.isLoading = false
        }
    }

    private func createManuscript() async {
        let title = newManuscriptTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let id = try await bridge.createManuscript(title: title)
            await MainActor.run {
                newManuscriptTitle = ""
                creatingManuscript = false
            }
            await reload()
            // Auto-navigate to the new manuscript's detail.
            await MainActor.run {
                navigationPath.append(id)
            }
        } catch {
            await MainActor.run {
                lastError = "Could not create manuscript: \(error.localizedDescription)"
            }
        }
    }
}
