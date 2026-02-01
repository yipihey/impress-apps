//
//  RestoreOptionsView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import SwiftUI

/// Modal sheet for configuring and executing a backup restore operation.
///
/// Displays:
/// - Backup summary (publication count, attachment count, date)
/// - Mode picker: Merge / Replace (with explanations)
/// - Checkboxes: Publications, Attachments, Notes, Settings
/// - Warning banner for Replace mode
/// - Progress indicator during restore
/// - Cancel / Restore buttons
public struct RestoreOptionsView: View {

    // MARK: - Properties

    let backupInfo: BackupInfo
    let onDismiss: () -> Void
    let onComplete: (BackupRestoreService.RestoreResult) -> Void

    @State private var preview: BackupRestoreService.RestorePreview?
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var restoreMode: BackupRestoreService.RestoreMode = .merge
    @State private var restorePublications = true
    @State private var restoreAttachments = true
    @State private var restoreNotes = true
    @State private var restoreSettings = false

    @State private var isRestoring = false
    @State private var restoreProgress: BackupRestoreService.RestoreProgress?
    @State private var restoreError: String?
    @State private var showReplaceConfirmation = false

    // MARK: - Initialization

    public init(
        backupInfo: BackupInfo,
        onDismiss: @escaping () -> Void,
        onComplete: @escaping (BackupRestoreService.RestoreResult) -> Void
    ) {
        self.backupInfo = backupInfo
        self.onDismiss = onDismiss
        self.onComplete = onComplete
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            if isLoading {
                loadingView
            } else if let error = loadError {
                errorView(error)
            } else if isRestoring {
                restoringView
            } else {
                optionsView
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(width: 450, height: 500)
        .task {
            await loadPreview()
        }
        .confirmationDialog(
            "Replace Entire Library?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace Library", role: .destructive) {
                Task { await performRestore() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all existing publications, attachments, and notes before restoring from the backup. This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Restore from Backup")
                .font(.headline)

            Text(backupInfo.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading backup information...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Cannot Read Backup")
                .font(.headline)

            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Options View

    private var optionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Backup Summary
                if let preview = preview {
                    backupSummarySection(preview)
                }

                // Validation Issues
                if let preview = preview, !preview.isValid {
                    validationWarningSection(preview.validationIssues)
                }

                // Restore Mode
                restoreModeSection

                // Content Selection
                contentSelectionSection

                // Replace Warning
                if restoreMode == .replace {
                    replaceWarningSection
                }
            }
            .padding()
        }
    }

    // MARK: - Backup Summary Section

    private func backupSummarySection(_ preview: BackupRestoreService.RestorePreview) -> some View {
        GroupBox("Backup Contents") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(preview.publicationCount)", systemImage: "doc.text")
                    Text("publications")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("\(preview.attachmentCount)", systemImage: "paperclip")
                    Text("attachments")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("\(preview.notesCount)", systemImage: "note.text")
                    Text("notes")
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("Created:")
                        .foregroundStyle(.secondary)
                    Text(preview.backupDate, style: .date)
                    Text(preview.backupDate, style: .time)
                }
                .font(.caption)

                HStack {
                    Text("App version:")
                        .foregroundStyle(.secondary)
                    Text(preview.appVersion)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Validation Warning Section

    private func validationWarningSection(_ issues: [String]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Validation Issues")
                        .font(.headline)
                }

                ForEach(issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Restore Mode Section

    private var restoreModeSection: some View {
        GroupBox("Restore Mode") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $restoreMode) {
                    Text("Merge").tag(BackupRestoreService.RestoreMode.merge)
                    Text("Replace").tag(BackupRestoreService.RestoreMode.replace)
                }
                .pickerStyle(.segmented)

                if restoreMode == .merge {
                    Text("Add backup contents to your existing library. Duplicates (by cite key) will be skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Clear your existing library and restore only the backup contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Content Selection Section

    private var contentSelectionSection: some View {
        GroupBox("What to Restore") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Publications", isOn: $restorePublications)
                    .help("BibTeX entries from the backup")

                Toggle("Attachments", isOn: $restoreAttachments)
                    .disabled(!restorePublications)
                    .help("PDFs and other linked files")

                Toggle("Notes", isOn: $restoreNotes)
                    .disabled(!restorePublications)
                    .help("Notes attached to publications")

                Divider()

                Toggle("Settings", isOn: $restoreSettings)
                    .help("App preferences (optional)")

                Text("Settings are not restored by default. Enable this to restore your preferences from the backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Replace Warning Section

    private var replaceWarningSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Warning: Replace Mode")
                    .font(.headline)
                    .foregroundStyle(.red)

                Text("This will permanently delete all existing publications, attachments, and notes before restoring from the backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
    }

    // MARK: - Restoring View

    private var restoringView: some View {
        VStack(spacing: 20) {
            if let progress = restoreProgress {
                VStack(spacing: 12) {
                    ProgressView(value: progress.fractionComplete)
                        .progressViewStyle(.linear)

                    Text(progress.phase.rawValue)
                        .font(.headline)

                    if let item = progress.currentItem {
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("\(progress.current) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                Text("Starting restore...")
                    .foregroundStyle(.secondary)
            }

            if let error = restoreError {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Restore") {
                if restoreMode == .replace {
                    showReplaceConfirmation = true
                } else {
                    Task { await performRestore() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading || isRestoring || !canRestore)
        }
        .padding()
    }

    // MARK: - Computed Properties

    private var canRestore: Bool {
        restorePublications || restoreSettings
    }

    // MARK: - Actions

    private func loadPreview() async {
        isLoading = true
        loadError = nil

        do {
            let service = BackupRestoreService()
            preview = try await service.prepareRestore(from: backupInfo.url)
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func performRestore() async {
        isRestoring = true
        restoreError = nil

        let options = BackupRestoreService.RestoreOptions(
            mode: restoreMode,
            restorePublications: restorePublications,
            restoreAttachments: restoreAttachments,
            restoreNotes: restoreNotes,
            restoreSettings: restoreSettings
        )

        do {
            let service = BackupRestoreService()
            let result = try await service.executeRestore(
                from: backupInfo.url,
                options: options
            ) { progress in
                Task { @MainActor in
                    self.restoreProgress = progress
                }
            }

            await MainActor.run {
                onComplete(result)
            }
        } catch {
            restoreError = error.localizedDescription
            isRestoring = false
        }
    }
}

// MARK: - Restore Result View

/// View displayed after a successful restore operation.
public struct RestoreResultView: View {

    let result: BackupRestoreService.RestoreResult
    let onDismiss: () -> Void

    public init(
        result: BackupRestoreService.RestoreResult,
        onDismiss: @escaping () -> Void
    ) {
        self.result = result
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Restore Complete")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if result.publicationsRestored > 0 {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("\(result.publicationsRestored) publications restored")
                    }
                }

                if result.publicationsSkipped > 0 {
                    HStack {
                        Image(systemName: "arrow.right.arrow.left")
                        Text("\(result.publicationsSkipped) duplicates skipped")
                            .foregroundStyle(.secondary)
                    }
                }

                if result.attachmentsRestored > 0 {
                    HStack {
                        Image(systemName: "paperclip")
                        Text("\(result.attachmentsRestored) attachments restored")
                    }
                }

                if result.attachmentsMissing > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(result.attachmentsMissing) attachments could not be restored")
                            .foregroundStyle(.secondary)
                    }
                }

                if result.notesRestored > 0 {
                    HStack {
                        Image(systemName: "note.text")
                        Text("\(result.notesRestored) notes restored")
                    }
                }

                if result.settingsRestored {
                    HStack {
                        Image(systemName: "gear")
                        Text("Settings restored")
                    }
                }
            }

            if !result.warnings.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Warnings:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(result.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
        .frame(width: 350)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Restore Options") {
    RestoreOptionsView(
        backupInfo: BackupInfo(
            url: URL(fileURLWithPath: "/tmp/imbib-backup-2026-01-28"),
            createdAt: Date(),
            sizeBytes: 52_000_000,
            publicationCount: 150,
            attachmentCount: 45
        ),
        onDismiss: {},
        onComplete: { _ in }
    )
}

#Preview("Restore Result") {
    RestoreResultView(
        result: BackupRestoreService.RestoreResult(
            publicationsRestored: 145,
            publicationsSkipped: 5,
            attachmentsRestored: 43,
            attachmentsMissing: 2,
            notesRestored: 30,
            settingsRestored: false,
            warnings: ["Some attachments were not found in backup"]
        ),
        onDismiss: {}
    )
}
#endif
