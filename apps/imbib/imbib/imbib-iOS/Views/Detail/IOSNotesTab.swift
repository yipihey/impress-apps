//
//  IOSNotesTab.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import ImpressModalEditing

/// iOS Notes tab for viewing and editing publication notes.
@available(iOS 17.0, *)
struct IOSNotesTab: View {
    let publication: CDPublication

    @Environment(LibraryViewModel.self) private var viewModel
    @State private var notes: String = ""
    @State private var saveTask: Task<Void, Never>?

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
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemBackground))
        .padding()
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
}
