//
//  EverythingImportPreviewView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI

// MARK: - Everything Import Preview View

/// SwiftUI view for previewing and configuring an Everything import.
public struct EverythingImportPreviewView: View {
    public let preview: EverythingImportPreview
    @Binding public var options: EverythingImportOptions
    @Binding public var libraryConflictResolutions: [UUID: LibraryConflictResolution]

    @State private var expandedSections: Set<String> = ["summary"]

    public init(
        preview: EverythingImportPreview,
        options: Binding<EverythingImportOptions>,
        libraryConflictResolutions: Binding<[UUID: LibraryConflictResolution]>
    ) {
        self.preview = preview
        self._options = options
        self._libraryConflictResolutions = libraryConflictResolutions
    }

    public var body: some View {
        Form {
            summarySection
            libraryConflictsSection
            duplicateHandlingSection
            importOptionsSection
            libraryListSection
            publicationListSection
            errorsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        Section {
            HStack {
                Label("Libraries", systemImage: "books.vertical")
                Spacer()
                Text("\(preview.libraries.count)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Collections", systemImage: "folder")
                Spacer()
                Text("\(preview.manifest.libraries.reduce(0) { $0 + $1.collectionCount })")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Smart Searches", systemImage: "magnifyingglass")
                Spacer()
                Text("\(preview.manifest.libraries.reduce(0) { $0 + $1.smartSearchCount })")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Publications", systemImage: "doc.text")
                Spacer()
                Text("\(preview.publications.count)")
                    .foregroundStyle(.secondary)
            }

            if !preview.duplicates.isEmpty {
                HStack {
                    Label("Duplicates", systemImage: "doc.on.doc")
                    Spacer()
                    Text("\(preview.duplicates.count)")
                        .foregroundStyle(.orange)
                }
            }

            if !preview.manifest.mutedItems.isEmpty {
                HStack {
                    Label("Muted Items", systemImage: "speaker.slash")
                    Spacer()
                    Text("\(preview.manifest.mutedItems.count)")
                        .foregroundStyle(.secondary)
                }
            }

            if !preview.manifest.dismissedPapers.isEmpty {
                HStack {
                    Label("Dismissed Papers", systemImage: "xmark.circle")
                    Spacer()
                    Text("\(preview.manifest.dismissedPapers.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Import Summary")
        }
    }

    // MARK: - Library Conflicts Section

    @ViewBuilder
    private var libraryConflictsSection: some View {
        if !preview.libraryConflicts.isEmpty {
            Section {
                ForEach(preview.libraryConflicts) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(conflict.importName)
                                .fontWeight(.medium)
                        }

                        Text("Conflicts with existing library: \"\(conflict.existingName)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Resolution", selection: conflictResolutionBinding(for: conflict.id)) {
                            ForEach(LibraryConflictResolution.allCases, id: \.self) { resolution in
                                Text(resolution.rawValue).tag(resolution)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Library Conflicts")
            } footer: {
                Text("Choose how to handle libraries that conflict with existing ones.")
                    .font(.caption)
            }
        }
    }

    private func conflictResolutionBinding(for id: UUID) -> Binding<LibraryConflictResolution> {
        Binding(
            get: { libraryConflictResolutions[id] ?? .merge },
            set: { libraryConflictResolutions[id] = $0 }
        )
    }

    // MARK: - Duplicate Handling Section

    @ViewBuilder
    private var duplicateHandlingSection: some View {
        if !preview.duplicates.isEmpty {
            Section {
                Picker("Duplicate Publications", selection: duplicateHandlingBinding) {
                    Text("Skip").tag(MboxImportOptions.DuplicateHandling.skip)
                    Text("Replace").tag(MboxImportOptions.DuplicateHandling.replace)
                    Text("Merge").tag(MboxImportOptions.DuplicateHandling.merge)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Duplicate Handling")
            } footer: {
                Text("\(preview.duplicates.count) publication\(preview.duplicates.count == 1 ? "" : "s") already exist in your library.")
                    .font(.caption)
            }
        }
    }

    private var duplicateHandlingBinding: Binding<MboxImportOptions.DuplicateHandling> {
        Binding(
            get: { options.duplicateHandling },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: newValue,
                    importFiles: options.importFiles,
                    preserveUUIDs: options.preserveUUIDs,
                    importTriageState: options.importTriageState,
                    importMutedItems: options.importMutedItems,
                    importDismissedPapers: options.importDismissedPapers,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    // MARK: - Import Options Section

    private var importOptionsSection: some View {
        Section {
            Toggle("Import files", isOn: importFilesBinding)
                .help("Import PDF and other file attachments")

            Toggle("Preserve UUIDs", isOn: preserveUUIDsBinding)
                .help("Keep original identifiers for round-trip export/import")

            Toggle("Import read/starred status", isOn: importTriageStateBinding)
                .help("Restore read and starred status for papers")

            if !preview.manifest.mutedItems.isEmpty {
                Toggle("Import muted items", isOn: importMutedItemsBinding)
            }

            if !preview.manifest.dismissedPapers.isEmpty {
                Toggle("Import dismissed papers", isOn: importDismissedPapersBinding)
            }
        } header: {
            Text("Import Options")
        }
    }

    private var importFilesBinding: Binding<Bool> {
        Binding(
            get: { options.importFiles },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: options.duplicateHandling,
                    importFiles: newValue,
                    preserveUUIDs: options.preserveUUIDs,
                    importTriageState: options.importTriageState,
                    importMutedItems: options.importMutedItems,
                    importDismissedPapers: options.importDismissedPapers,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    private var preserveUUIDsBinding: Binding<Bool> {
        Binding(
            get: { options.preserveUUIDs },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: options.duplicateHandling,
                    importFiles: options.importFiles,
                    preserveUUIDs: newValue,
                    importTriageState: options.importTriageState,
                    importMutedItems: options.importMutedItems,
                    importDismissedPapers: options.importDismissedPapers,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    private var importTriageStateBinding: Binding<Bool> {
        Binding(
            get: { options.importTriageState },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: options.duplicateHandling,
                    importFiles: options.importFiles,
                    preserveUUIDs: options.preserveUUIDs,
                    importTriageState: newValue,
                    importMutedItems: options.importMutedItems,
                    importDismissedPapers: options.importDismissedPapers,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    private var importMutedItemsBinding: Binding<Bool> {
        Binding(
            get: { options.importMutedItems },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: options.duplicateHandling,
                    importFiles: options.importFiles,
                    preserveUUIDs: options.preserveUUIDs,
                    importTriageState: options.importTriageState,
                    importMutedItems: newValue,
                    importDismissedPapers: options.importDismissedPapers,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    private var importDismissedPapersBinding: Binding<Bool> {
        Binding(
            get: { options.importDismissedPapers },
            set: { newValue in
                options = EverythingImportOptions(
                    duplicateHandling: options.duplicateHandling,
                    importFiles: options.importFiles,
                    preserveUUIDs: options.preserveUUIDs,
                    importTriageState: options.importTriageState,
                    importMutedItems: options.importMutedItems,
                    importDismissedPapers: newValue,
                    libraryConflictResolutions: options.libraryConflictResolutions
                )
            }
        )
    }

    // MARK: - Library List Section

    private var libraryListSection: some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSections.contains("libraries") },
                    set: { if $0 { expandedSections.insert("libraries") } else { expandedSections.remove("libraries") } }
                )
            ) {
                ForEach(preview.libraries) { library in
                    HStack {
                        Image(systemName: libraryIcon(for: library.metadata.libraryType))
                            .foregroundStyle(libraryColor(for: library.metadata.libraryType))
                        VStack(alignment: .leading) {
                            Text(library.metadata.name)
                            Text("\(library.publicationCount) publications")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if library.isNew {
                            Text("New")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                }
            } label: {
                Label("Libraries (\(preview.libraries.count))", systemImage: "books.vertical")
            }
        }
    }

    private func libraryIcon(for type: LibraryType?) -> String {
        switch type {
        case .inbox:
            return "tray"
        case .save:
            return "square.and.arrow.down"
        case .dismissed:
            return "xmark.circle"
        case .exploration:
            return "safari"
        case .user, .none:
            return "books.vertical"
        }
    }

    private func libraryColor(for type: LibraryType?) -> Color {
        switch type {
        case .inbox:
            return .blue
        case .save:
            return .green
        case .dismissed:
            return .red
        case .exploration:
            return .orange
        case .user, .none:
            return .primary
        }
    }

    // MARK: - Publication List Section

    private var publicationListSection: some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSections.contains("publications") },
                    set: { if $0 { expandedSections.insert("publications") } else { expandedSections.remove("publications") } }
                )
            ) {
                ForEach(preview.publications.prefix(50)) { pub in
                    VStack(alignment: .leading) {
                        Text(pub.title)
                            .lineLimit(1)
                        Text(pub.authors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if preview.publications.count > 50 {
                    Text("... and \(preview.publications.count - 50) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label("Publications (\(preview.publications.count))", systemImage: "doc.text")
            }
        }
    }

    // MARK: - Errors Section

    @ViewBuilder
    private var errorsSection: some View {
        if !preview.parseErrors.isEmpty {
            Section {
                ForEach(preview.parseErrors) { error in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error.description)
                            .font(.caption)
                    }
                }
            } header: {
                Label("Parse Errors", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Import Result View

/// View for displaying the result of an Everything import.
public struct EverythingImportResultView: View {
    public let result: EverythingImportResult

    public init(result: EverythingImportResult) {
        self.result = result
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: result.hasErrors ? "exclamationmark.triangle.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(result.hasErrors ? .orange : .green)

            Text(result.hasErrors ? "Import Completed with Warnings" : "Import Successful")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if result.librariesCreated > 0 {
                    Label("\(result.librariesCreated) librar\(result.librariesCreated == 1 ? "y" : "ies") created", systemImage: "books.vertical")
                }
                if result.librariesMerged > 0 {
                    Label("\(result.librariesMerged) librar\(result.librariesMerged == 1 ? "y" : "ies") merged", systemImage: "arrow.triangle.merge")
                }
                if result.collectionsCreated > 0 {
                    Label("\(result.collectionsCreated) collection\(result.collectionsCreated == 1 ? "" : "s") created", systemImage: "folder")
                }
                if result.publicationsImported > 0 {
                    Label("\(result.publicationsImported) publication\(result.publicationsImported == 1 ? "" : "s") imported", systemImage: "doc.text")
                }
                if result.publicationsMerged > 0 {
                    Label("\(result.publicationsMerged) publication\(result.publicationsMerged == 1 ? "" : "s") merged", systemImage: "arrow.triangle.merge")
                }
                if result.publicationsSkipped > 0 {
                    Label("\(result.publicationsSkipped) duplicate\(result.publicationsSkipped == 1 ? "" : "s") skipped", systemImage: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }

            if !result.errors.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    ForEach(result.errors.prefix(5)) { error in
                        Text("- \(error.description)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if result.errors.count > 5 {
                        Text("... and \(result.errors.count - 5) more errors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}

#if DEBUG
struct EverythingImportPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        EverythingImportPreviewView(
            preview: EverythingImportPreview(
                manifest: EverythingManifest(
                    libraries: [
                        LibraryIndex(id: UUID(), name: "My Library", type: .user, publicationCount: 100),
                        LibraryIndex(id: UUID(), name: "Inbox", type: .inbox, publicationCount: 25)
                    ],
                    mutedItems: [
                        MutedItemInfo(type: "author", value: "John Doe")
                    ],
                    totalPublications: 125
                ),
                libraries: [
                    LibraryImportPreview(
                        id: UUID(),
                        metadata: LibraryMetadata(name: "My Library", libraryType: .user),
                        publicationCount: 100,
                        isNew: true
                    )
                ]
            ),
            options: .constant(.default),
            libraryConflictResolutions: .constant([:])
        )
        .frame(width: 500, height: 600)
    }
}
#endif
