//
//  MboxImportPreviewView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-22.
//

import SwiftUI

// MARK: - Mbox Import Preview View

/// Preview UI for mbox import, allowing users to review and select publications.
public struct MboxImportPreviewView: View {
    let preview: MboxImportPreview
    let onImport: (Set<UUID>, [UUID: DuplicateAction]) -> Void
    let onCancel: () -> Void

    @State private var selectedPublications: Set<UUID>
    @State private var duplicateDecisions: [UUID: DuplicateAction] = [:]
    @State private var showDuplicatesSection = true
    @State private var showErrorsSection = false

    public init(
        preview: MboxImportPreview,
        onImport: @escaping (Set<UUID>, [UUID: DuplicateAction]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preview = preview
        self.onImport = onImport
        self.onCancel = onCancel
        self._selectedPublications = State(initialValue: Set(preview.publications.map { $0.id }))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Library info
                    if let metadata = preview.libraryMetadata {
                        libraryInfoSection(metadata)
                    }

                    // Summary
                    summarySection

                    // New publications
                    if !preview.publications.isEmpty {
                        newPublicationsSection
                    }

                    // Duplicates
                    if !preview.duplicates.isEmpty {
                        duplicatesSection
                    }

                    // Parse errors
                    if !preview.parseErrors.isEmpty {
                        errorsSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "envelope.open")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("Import mbox Library")
                .font(.headline)

            Spacer()
        }
        .padding()
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(uiColor: .secondarySystemBackground))
        #endif
    }

    // MARK: - Library Info

    @ViewBuilder
    private func libraryInfoSection(_ metadata: LibraryMetadata) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Library Name", systemImage: "folder")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(metadata.name)
                        .fontWeight(.medium)
                }

                if let bibPath = metadata.bibtexPath {
                    HStack {
                        Label("BibTeX Path", systemImage: "doc.text")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(bibPath)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                HStack {
                    Label("Export Date", systemImage: "calendar")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(metadata.exportDate, style: .date)
                }

                if !metadata.collections.isEmpty {
                    HStack {
                        Label("Collections", systemImage: "folder.badge.plus")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(metadata.collections.count)")
                    }
                }
            }
        } label: {
            Text("Library Information")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        HStack(spacing: 20) {
            summaryItem(
                count: preview.publications.count,
                label: "New",
                icon: "plus.circle.fill",
                color: .green
            )

            summaryItem(
                count: preview.duplicates.count,
                label: "Duplicates",
                icon: "doc.on.doc.fill",
                color: .orange
            )

            summaryItem(
                count: preview.parseErrors.count,
                label: "Errors",
                icon: "exclamationmark.triangle.fill",
                color: .red
            )
        }
        .padding(.vertical, 8)
    }

    private func summaryItem(count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text("\(count)")
                    .font(.title2.weight(.bold))
            }
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - New Publications

    private var newPublicationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button(action: selectAll) {
                        Text("Select All")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button(action: deselectAll) {
                        Text("Deselect All")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("\(selectedPublications.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)

                ForEach(preview.publications) { pub in
                    publicationRow(pub)
                }
            }
        } label: {
            Text("Publications to Import")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func publicationRow(_ pub: PublicationPreview) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selectedPublications.contains(pub.id) },
                set: { isSelected in
                    if isSelected {
                        selectedPublications.insert(pub.id)
                    } else {
                        selectedPublications.remove(pub.id)
                    }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(pub.title)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(pub.authors)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let year = pub.year {
                        Text("(\(year))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if pub.fileCount > 0 {
                        Label("\(pub.fileCount)", systemImage: "paperclip")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Text(pub.citeKey)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Duplicates

    private var duplicatesSection: some View {
        DisclosureGroup(isExpanded: $showDuplicatesSection) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(preview.duplicates) { dup in
                    duplicateRow(dup)
                }
            }
        } label: {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.orange)
                Text("Duplicates (\(preview.duplicates.count))")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func duplicateRow(_ dup: DuplicateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dup.importPublication.title)
                        .font(.callout)
                        .lineLimit(1)

                    HStack {
                        Text("Matches existing:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(dup.existingCiteKey)
                            .font(.caption.monospaced())
                            .foregroundColor(.orange)
                        Text("by \(dup.matchType.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Picker("", selection: Binding(
                    get: { duplicateDecisions[dup.id] ?? .skip },
                    set: { duplicateDecisions[dup.id] = $0 }
                )) {
                    ForEach(DuplicateAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            Divider()
        }
    }

    // MARK: - Errors

    private var errorsSection: some View {
        DisclosureGroup(isExpanded: $showErrorsSection) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(preview.parseErrors) { error in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)

                        Text("Message \(error.messageIndex):")
                            .font(.caption.weight(.medium))

                        Text(error.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Parse Errors (\(preview.parseErrors.count))")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Import \(selectedPublications.count) Publications") {
                onImport(selectedPublications, duplicateDecisions)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedPublications.isEmpty && duplicateDecisions.values.filter { $0 != .skip }.isEmpty)
        }
        .padding()
    }

    // MARK: - Actions

    private func selectAll() {
        selectedPublications = Set(preview.publications.map { $0.id })
    }

    private func deselectAll() {
        selectedPublications.removeAll()
    }
}

// MARK: - Color Extension for Cross-Platform

#if os(iOS)
private extension Color {
    static func secondarySystemBackground() -> Color {
        Color(uiColor: .secondarySystemBackground)
    }
}
#else
private extension Color {
    init(_ nsColor: NSColor) {
        self.init(nsColor: nsColor)
    }
}
#endif

// MARK: - Preview

#if DEBUG
struct MboxImportPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        let dummyMessage = MboxMessage(
            from: "Test Author",
            subject: "Test Title",
            date: Date(),
            messageID: "test-id"
        )

        let preview = MboxImportPreview(
            libraryMetadata: LibraryMetadata(
                name: "My Research Library",
                exportDate: Date(),
                collections: [
                    CollectionInfo(id: UUID(), name: "Quantum Physics"),
                    CollectionInfo(id: UUID(), name: "2024 Papers"),
                ]
            ),
            publications: [
                PublicationPreview(
                    id: UUID(),
                    citeKey: "Einstein1905a",
                    title: "On the Electrodynamics of Moving Bodies",
                    authors: "Albert Einstein",
                    year: 1905,
                    fileCount: 1,
                    message: dummyMessage
                ),
                PublicationPreview(
                    id: UUID(),
                    citeKey: "Feynman1965QED",
                    title: "QED: The Strange Theory of Light and Matter",
                    authors: "Richard Feynman",
                    year: 1965,
                    fileCount: 2,
                    message: dummyMessage
                ),
            ],
            duplicates: [
                DuplicateInfo(
                    importPublication: PublicationPreview(
                        id: UUID(),
                        citeKey: "Hawking1974",
                        title: "Black Hole Explosions?",
                        authors: "Stephen Hawking",
                        year: 1974,
                        message: dummyMessage
                    ),
                    existingCiteKey: "Hawking1974",
                    existingTitle: "Black Hole Explosions?",
                    matchType: .citeKey
                ),
            ],
            parseErrors: [
                ParseError(messageIndex: 5, description: "Invalid MIME boundary"),
            ]
        )

        return MboxImportPreviewView(
            preview: preview,
            onImport: { _, _ in },
            onCancel: { }
        )
    }
}
#endif
