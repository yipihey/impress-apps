//
//  IOSNotesTab.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import ImpressHelixCore

/// iOS Notes tab for viewing and editing publication notes.
///
/// Features:
/// - Hardware keyboard shortcuts (Cmd+S save, Cmd+B bold, Cmd+I italic)
/// - Apple Pencil Scribble support
/// - Helix modal editing mode (optional)
/// - Auto-save with debouncing
@available(iOS 17.0, *)
struct IOSNotesTab: View {
    let publication: CDPublication

    @Environment(LibraryViewModel.self) private var viewModel
    @State private var notes: String = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showSaveConfirmation = false

    // Helix mode settings
    @AppStorage("helixModeEnabled") private var helixModeEnabled = false
    @AppStorage("helixShowModeIndicator") private var helixShowModeIndicator = true
    @StateObject private var helixState = HelixState()

    var body: some View {
        Group {
            if helixModeEnabled {
                HelixTextEditor(
                    text: $notes,
                    helixState: helixState,
                    showModeIndicator: helixShowModeIndicator,
                    indicatorPosition: .bottomRight
                )
            } else {
                // Use IOSNotesEditorView for keyboard shortcut and Scribble support
                IOSNotesEditorView(
                    text: $notes,
                    onSave: {
                        saveNotes()
                    }
                )
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: publication.id, initial: true) { _, _ in
            saveTask?.cancel()
            notes = publication.fields["note"] ?? ""
            helixState.reset()
        }
        .onChange(of: notes) { oldValue, newValue in
            let targetPublication = publication

            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard targetPublication.id == self.publication.id else { return }
                await viewModel.updateField(targetPublication, field: "note", value: newValue)
            }
        }
    }

    // MARK: - Actions

    private func saveNotes() {
        saveTask?.cancel()
        Task {
            await viewModel.updateField(publication, field: "note", value: notes)
        }
    }
}
