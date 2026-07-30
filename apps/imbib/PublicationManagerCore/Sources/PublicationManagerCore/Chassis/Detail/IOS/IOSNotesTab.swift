#if os(iOS)
// Chassis file — iOS-only. Lifted out of the imbib app target in I2; see
// `IOSPublicationDetailPane.swift` for why, and for the injection points.
//
//  IOSNotesTab.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import ImpressHelixCore

/// iOS Notes tab for viewing and editing publication notes.
///
/// Features:
/// - Hardware keyboard shortcuts (Cmd+S save, Cmd+B bold, Cmd+I italic)
/// - Apple Pencil Scribble support
/// - Helix modal editing mode (optional)
/// - Auto-save with debouncing
///
/// ## Stage 5b: same document, different editor
///
/// This is NOT macOS's `NotesPanel` written twice — macOS shows the quick
/// annotation fields inline plus a hybrid markdown/preview area inside a
/// resizable panel BESIDE the PDF, which is a design a phone has no room for.
/// What WAS written twice is the document model, and it had drifted into a bug:
/// macOS parsed the `note` field as YAML front matter + freeform, iOS read the
/// field RAW. So an iPhone user saw
///
///     ---
///     First Author: Pioneer in this field
///     ---
///
/// as literal text above their notes, and every edit round-tripped the front
/// matter as prose.
///
/// Both editors now share `PublicationNotesDocument` (the format) and
/// `PublicationNotesWriter` (the 500 ms debounce + the "selection moved on"
/// guard). This editor binds the FREEFORM half; the annotations ride along
/// untouched and are preserved on save, where before they were either shown as
/// junk or — once a user deleted the confusing lines — silently destroyed.
@available(iOS 17.0, *)
public struct IOSNotesTab: View {
    let publicationID: UUID

    public init(publicationID: UUID) {
        self.publicationID = publicationID
    }

    /// The parsed `note` field. Only `freeform` is editable here; the
    /// annotations are macOS's inline fields and are round-tripped verbatim.
    @State private var document = PublicationNotesDocument()
    @State private var annotationSettings: QuickAnnotationSettings = .defaults
    @State private var notesWriter = PublicationNotesWriter()

    // Helix mode settings
    @AppStorage("helixModeEnabled") private var helixModeEnabled = false
    @AppStorage("helixShowModeIndicator") private var helixShowModeIndicator = true
    @State private var helixState = HelixState()

    public var body: some View {
        Group {
            if helixModeEnabled {
                HelixTextEditor(
                    text: $document.freeform,
                    helixState: helixState,
                    showModeIndicator: helixShowModeIndicator,
                    indicatorPosition: .bottomRight
                )
            } else {
                // Use IOSNotesEditorView for keyboard shortcut and Scribble support
                IOSNotesEditorView(
                    text: $document.freeform,
                    onSave: {
                        saveNotes()
                    }
                )
            }
        }
        .background(Color(.systemBackground))
        .task {
            // The annotation field definitions the front matter is keyed on.
            annotationSettings = await QuickAnnotationSettingsStore.shared.settings
            loadNotes()
        }
        .onChange(of: publicationID, initial: true) { _, _ in
            loadNotes()
            helixState.reset()
        }
        .onChange(of: document.freeform) { _, _ in
            notesWriter.schedule(
                document, for: publicationID, settings: annotationSettings)
        }
    }

    // MARK: - Persistence

    private func loadNotes() {
        notesWriter.cancelPending()
        document = PublicationNotesDocument(
            publication: RustStoreAdapter.shared.getPublicationDetail(id: publicationID),
            settings: annotationSettings)
    }

    private func saveNotes() {
        notesWriter.saveNow(document, for: publicationID, settings: annotationSettings)
    }
}

#endif  // os(iOS)
