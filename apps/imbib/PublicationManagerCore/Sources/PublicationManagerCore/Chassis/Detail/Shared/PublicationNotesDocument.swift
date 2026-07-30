//
//  PublicationNotesDocument.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the Notes tab's DOCUMENT MODEL and its debounced
//  writer, shared by two genuinely different editors.
//
//  ## The bug this closes
//
//  A publication's notes live in ONE store field (`note`) whose format is YAML
//  front matter (the quick annotations, label-keyed) followed by freeform
//  markdown. macOS's `NotesPanel` has always parsed it that way:
//  `NotesParser.parse` → ID-keyed annotations + freeform, re-serialised through
//  `NotesParser.serialize` on a 500 ms debounce.
//
//  iOS's `IOSNotesTab` did not. It read `publication.note` RAW into a plain
//  text editor and wrote the buffer back RAW. So on iPhone the user saw
//
//      ---
//      First Author: Pioneer in this field
//      ---
//
//      Actual reading notes…
//
//  as literal text at the top of their notes, and any edit — including the
//  Apple-Pencil and Helix paths — round-tripped the front matter as prose. Two
//  editors over one field, only one of which knew the field's format.
//
//  ## The split
//
//  * `PublicationNotesDocument` — the parse/serialise value type. Cross-platform.
//  * `PublicationNotesWriter` — the 500 ms debounced, publication-scoped save,
//    with the actual store write injected so each shell keeps its own writer
//    (macOS `LibraryViewModel.updateField`, iOS `RustStoreAdapter.updateField`).
//
//  What stays two designs is the EDITOR: macOS shows the annotation fields
//  inline plus a hybrid markdown/preview area inside a resizable panel beside
//  the PDF; iOS shows one full-screen editor with Scribble and optional Helix
//  modal editing. Those are not one surface written twice — see the matrix.
//

import Foundation

// MARK: - Document

/// A publication's `note` field, parsed into its two halves.
///
/// Annotations are **ID-keyed** here (the form the UI binds to); the on-disk
/// YAML is label-keyed, and the conversion is
/// `QuickAnnotationSettings.labelToIDAnnotations`. Unknown keys survive as
/// custom annotations in both directions, so a field renamed in Settings never
/// silently drops a user's note.
public struct PublicationNotesDocument: Equatable, Sendable {

    /// Quick-annotation values keyed by field ID.
    public var annotations: [String: String]

    /// Freeform markdown (+ LaTeX) notes.
    public var freeform: String

    public init(annotations: [String: String] = [:], freeform: String = "") {
        self.annotations = annotations
        self.freeform = freeform
    }

    /// Parse a raw `note` field.
    public init(rawNote: String, settings: QuickAnnotationSettings) {
        let parsed = NotesParser.parse(rawNote)
        self.annotations = settings.labelToIDAnnotations(parsed.annotations)
        self.freeform = parsed.freeform
    }

    /// Parse the `note` field of a store row. `nil` yields an empty document.
    public init(publication: PublicationModel?, settings: QuickAnnotationSettings) {
        self.init(rawNote: publication?.fields["note"] ?? "", settings: settings)
    }

    /// Serialise back to the single `note` field.
    public func serialized(settings: QuickAnnotationSettings) -> String {
        NotesParser.serialize(
            ParsedNotes(annotations: annotations, freeform: freeform),
            fields: settings.fields)
    }

    /// The annotation fields that currently hold text — the set macOS uses to
    /// decide which inline fields start visible.
    public var populatedAnnotationIDs: Set<String> {
        Set(annotations.filter { !$0.value.isEmpty }.map(\.key))
    }

    public var isEmpty: Bool {
        annotations.values.allSatisfy(\.isEmpty) && freeform.isEmpty
    }
}

// MARK: - Writer

/// Debounced writer for a publication's notes.
///
/// Both editors had their own copy of this state machine: cancel the pending
/// task, sleep 500 ms, bail if cancelled, bail if the selection moved on, then
/// write. The "bail if the selection moved on" guard is the one that matters —
/// without it a debounce in flight when the user arrows to the next paper
/// writes the previous paper's buffer into the new paper's `note` field. macOS
/// had the guard (`targetPublication.id == self.publication.id`); iOS captured
/// the id into the task instead, which is equivalent, and both are now this
/// one implementation.
@MainActor
public final class PublicationNotesWriter {

    private let debounce: Duration
    private let write: @MainActor (UUID, String) async -> Void
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - debounce: idle interval before the write. 500 ms is what both
    ///     editors shipped.
    ///   - write: the store write. Injectable for tests; the default writes the
    ///     `note` field through `RustStoreAdapter.shared`, which is what iOS
    ///     called directly and what macOS reached through
    ///     `LibraryViewModel.updateField` (a one-line pass-through to the same
    ///     store).
    public init(
        debounce: Duration = .milliseconds(500),
        write: @escaping @MainActor (UUID, String) async -> Void = { id, value in
            RustStoreAdapter.shared.updateField(id: id, field: "note", value: value)
        }
    ) {
        self.debounce = debounce
        self.write = write
    }

    /// Schedule a debounced save of `document` for `publicationID`.
    public func schedule(
        _ document: PublicationNotesDocument,
        for publicationID: UUID,
        settings: QuickAnnotationSettings
    ) {
        let serialized = document.serialized(settings: settings)
        task?.cancel()
        task = Task { [write, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await write(publicationID, serialized)
        }
    }

    /// Write immediately, cancelling any pending debounce (⌘S / explicit Save).
    public func saveNow(
        _ document: PublicationNotesDocument,
        for publicationID: UUID,
        settings: QuickAnnotationSettings
    ) {
        let serialized = document.serialized(settings: settings)
        task?.cancel()
        task = Task { [write] in
            await write(publicationID, serialized)
        }
    }

    /// Drop a pending save without writing — used when the selection changes,
    /// so the outgoing paper's buffer never lands on the incoming one.
    public func cancelPending() {
        task?.cancel()
        task = nil
    }
}
