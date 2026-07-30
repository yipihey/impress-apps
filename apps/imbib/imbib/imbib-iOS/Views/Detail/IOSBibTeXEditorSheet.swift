//
//  IOSBibTeXEditorSheet.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-18.
//  Stage 5d (2026-07-30): collapsed onto the shared `BibTeXTab`.
//
//  ## The third BibTeX surface (verdict: full collapse)
//
//  Stage 5b collapsed `IOSBibTeXTab` (126 lines) into `BibTeXTab`. It missed
//  this one, which the publication list presents from its row context menu —
//  so imbib-iOS still had TWO BibTeX editors: the detail pane's (shared) and
//  this sheet's (its own state machine, its own editor view, its own
//  validator, its own save path). Every difference was a defect:
//
//  * **The save path — the same bug Stage 5b fixed in the tab.** This sheet
//    looped `RustStoreAdapter.updateField` over `entry.fields`, which cannot
//    express a renamed cite key, a changed entry type, or a DELETED field.
//    Editing `@article{foo` to `@article{bar`, or deleting a `pages` line,
//    showed a saved sheet and changed nothing. `BibTeXTab` re-imports the
//    parsed entry via `LibraryViewModel.updateFromBibTeX`, so all three work.
//  * **The validator.** 35 lines of hand-rolled brace counting and an
//    `^@\w+\s*\{` regex — a FOURTH grammar for BibTeX, and the strictest:
//    it rejected `@string`/`@preamble` blocks outright. `BibTeXEditor` (which
//    `BibTeXTab` uses) has had real-time `BibTeXValidator` checking with a
//    line-numbered validation bar all along. Deleted, not ported.
//  * **The read mode.** A plain monospaced `Text` in a `ScrollView`: no syntax
//    highlighting, no line numbers, no error markers. The shared tab shows the
//    same highlighted editor it edits in, non-editable.
//  * **`IOSBibTeXEditorView` (359 lines)**, the `UITextView` wrapper this sheet
//    was the only caller of, is deleted with it. iOS is not left without a
//    hardware-keyboard BibTeX editor: `BibTeXEditor` is what the detail pane's
//    `BibTeXTab` has been using on iOS since Stage 5b.
//
//  What stays here is the SHEET, which is genuine iOS chrome and not a second
//  editor: a `NavigationStack`, the "BibTeX" title, and one Done button that
//  dismisses. Edit / Copy / Cancel / Save are `BibTeXTab`'s own inline bar —
//  they moved out of the navigation bar rather than being duplicated into it.
//  Unsaved-change confirmation still happens, via the tab's
//  `confirmsUnsavedDiscard` (which `init?(publicationID:)` defaults to `true`
//  precisely because that was the one thing the iOS copies did better).
//
//  The `onSave` parameter is gone: the sole call site
//  (`IOSUnifiedPublicationListWrapper.handleViewEditBibTeX`) never passed one,
//  and the store event the save emits is what refreshes the list.
//

import SwiftUI
import PublicationManagerCore

/// A modal sheet presenting the shared `BibTeXTab` for one publication.
///
/// Entry point preserved from the pre-collapse sheet: the publication list's
/// "View/Edit BibTeX" row action constructs it with just an id.
struct IOSBibTeXEditorSheet: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// The publication ID to edit
    let publicationID: UUID

    // MARK: - Body

    var body: some View {
        NavigationStack {
            sheetContent
                .navigationTitle("BibTeX")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("BibTeXSheetDone")
                    }
                }
        }
    }

    /// `BibTeXTab.init?(publicationID:)` is failable — it reads the detail row
    /// up front and returns nil when the publication is gone (deleted while the
    /// context menu was open, say). Same shape `IOSDetailView` uses.
    @ViewBuilder
    private var sheetContent: some View {
        if let tab = BibTeXTab(publicationID: publicationID) {
            tab
                .accessibilityIdentifier("BibTeXSheetEditor")
        } else {
            ContentUnavailableView(
                "Publication Unavailable",
                systemImage: "doc.text",
                description: Text("This publication is no longer in the library.")
            )
        }
    }
}
