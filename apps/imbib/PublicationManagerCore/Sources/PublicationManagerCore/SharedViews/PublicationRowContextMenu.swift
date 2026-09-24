//
//  PublicationRowContextMenu.swift
//  PublicationManagerCore
//
//  A publication row's context menu — ONE definition for every publication
//  list. Moved verbatim out of `PublicationListView.contextMenuItems(for:)`
//  (plan wave 6, W4) so the layout tree's `list` pane shows the menu the
//  legacy list shows, not a second one that drifts. What the list read from
//  its own state it now takes as inputs: the row data (`row`), the libraries
//  the organise submenus offer, and the host's step before Delete (the legacy
//  list clears its selection there).
//

import SwiftUI
import ImpressFTUI

@MainActor
struct PublicationRowContextMenu: View {

    /// The rows the menu acts on — the selection when the clicked row is in
    /// it, else the clicked row (what `.contextMenu(forSelectionType:)`
    /// hands its closure).
    let ids: Set<UUID>
    let actions: PublicationListActions
    /// The row the menu phrases itself from (read, starred, identifiers,
    /// e-ink state, cite key). `nil` hides the items that need it.
    let row: (UUID) -> PublicationRowData?
    /// The library the list is scoped to; the library submenus leave it out.
    let libraryID: UUID?
    let allLibraries: [(id: UUID, name: String)]
    let allScixLibraries: [(id: UUID, name: String)]
    /// Run before Delete's action.
    let willDelete: () -> Void

    @ViewBuilder
    var body: some View {
        // MARK: PDF & Browser Actions

        // Open PDF
        if let onOpenPDF = actions.onOpenPDF {
            Button {
                if let first = ids.first { onOpenPDF(first) }
            } label: {
                Label("Open PDF", systemImage: "doc.text")
            }
        }

        // Download PDF (single item without PDF)
        if ids.count == 1, let first = ids.first,
           let rowData = row(first), !rowData.hasDownloadedPDF,
           let onDownloadPDF = actions.onDownloadPDF {
            Button {
                onDownloadPDF(first)
            } label: {
                Label("Download PDF", systemImage: "arrow.down.doc")
            }
        }

        // Download PDFs (multiple papers)
        if let onDownloadPDFs = actions.onDownloadPDFs, ids.count > 1 {
            Button {
                onDownloadPDFs(ids)
            } label: {
                Label("Download PDFs", systemImage: "arrow.down.doc")
            }
        }

        // Open in Browser submenu
        if let onOpenInBrowser = actions.onOpenInBrowser, let first = ids.first,
           let rowData = row(first) {
            let hasLinks = rowData.arxivID != nil || rowData.bibcode != nil || rowData.doi != nil
            if hasLinks {
                Menu {
                    if rowData.arxivID != nil {
                        Button {
                            onOpenInBrowser(first, .arxiv)
                        } label: {
                            Label(BrowserDestination.arxiv.displayName, systemImage: BrowserDestination.arxiv.systemImage)
                        }
                    }
                    if rowData.bibcode != nil {
                        Button {
                            onOpenInBrowser(first, .ads)
                        } label: {
                            Label(BrowserDestination.ads.displayName, systemImage: BrowserDestination.ads.systemImage)
                        }
                    }
                    if rowData.doi != nil {
                        Button {
                            onOpenInBrowser(first, .doi)
                        } label: {
                            Label(BrowserDestination.doi.displayName, systemImage: BrowserDestination.doi.systemImage)
                        }
                    }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }

        // Mirror to reMarkable (ADR-025). Present only while a device in
        // individual mode is configured (the host leaves the action nil
        // otherwise); the label follows the first selected row's state.
        if let onToggleEink = actions.onToggleEink,
           let first = ids.first, let rowData = row(first) {
            let state = rowData.einkState
            Button {
                onToggleEink(ids)
            } label: {
                Label(
                    state?.menuVerb ?? EInkMirrorState.mirrorVerb,
                    systemImage: state == nil ? "rectangle.portrait" : "rectangle.portrait.slash"
                )
            }
        }

        Divider()

        // MARK: Copy & Share

        if let onCopy = actions.onCopy {
            Button("Copy") {
                Task { await onCopy(ids) }
            }
        }

        if let onCut = actions.onCut {
            Button("Cut") {
                Task { await onCut(ids) }
            }
        }

        Button("Copy Cite Key") {
            if let first = ids.first,
               let rowData = row(first) {
                Self.copyToClipboard(rowData.citeKey)
            }
        }

        // View/Edit BibTeX
        if let onViewEditBibTeX = actions.onViewEditBibTeX, let first = ids.first {
            Button {
                onViewEditBibTeX(first)
            } label: {
                Label("View/Edit BibTeX", systemImage: "doc.plaintext")
            }
        }

        // Share
        if actions.onShare != nil || actions.onShareByEmail != nil {
            if let first = ids.first {
                Menu {
                    if let onShare = actions.onShare {
                        Button {
                            onShare(first)
                        } label: {
                            Label("Share Paper", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let onShareByEmail = actions.onShareByEmail {
                        Button {
                            onShareByEmail(first)
                        } label: {
                            Label("Share by Email", systemImage: "envelope")
                        }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }

        Divider()

        // MARK: Read Status, Star, Flag, Tag

        // Toggle Read
        if let onToggleRead = actions.onToggleRead {
            if let first = ids.first, let rowData = row(first) {
                Button {
                    for id in ids {
                        Task { await onToggleRead(id) }
                    }
                } label: {
                    Label(
                        rowData.isRead ? "Mark as Unread" : "Mark as Read",
                        systemImage: rowData.isRead ? "envelope.badge" : "envelope.open"
                    )
                }
            }
        }

        // Toggle Star
        if let onToggleStar = actions.onToggleStar {
            if let first = ids.first, let rowData = row(first) {
                Button {
                    Task { await onToggleStar(ids) }
                } label: {
                    Label(
                        rowData.isStarred ? "Unstar" : "Star",
                        systemImage: rowData.isStarred ? "star.slash" : "star"
                    )
                }
            }
        }

        // Flag submenu
        if actions.onSetFlag != nil || actions.onClearFlag != nil {
            Menu {
                if let onSetFlag = actions.onSetFlag {
                    ForEach(FlagColor.allCases, id: \.self) { color in
                        Button {
                            Task { await onSetFlag(ids, color) }
                        } label: {
                            Label(color.displayName, systemImage: "flag.fill")
                        }
                    }
                }
                if let onClearFlag = actions.onClearFlag {
                    Divider()
                    Button("Clear Flag") {
                        Task { await onClearFlag(ids) }
                    }
                }
            } label: {
                Label("Flag", systemImage: "flag")
            }
        }

        // Add Tag
        if let onAddTag = actions.onAddTag {
            Button {
                onAddTag(ids)
            } label: {
                Label("Add Tag", systemImage: "tag")
            }
        }

        // Remove Tag › — every tag the targets carry. Each item removes the
        // path from the targets that carry it (so Undo restores exactly
        // those); hidden when no target carries a tag.
        if let onRemoveTag = actions.onRemoveTag {
            let tags = PublicationTagRemoval.removableTags(ids: ids, row: row)
            if !tags.isEmpty {
                Menu {
                    ForEach(tags, id: \.path) { tag in
                        Button(tag.path) {
                            onRemoveTag(
                                PublicationTagRemoval.carriers(of: tag.path, in: ids, row: row),
                                tag.path)
                        }
                    }
                } label: {
                    Label("Remove Tag", systemImage: "tag.slash")
                }
            }
        }

        Divider()

        // MARK: Organization

        // Add to Library submenu
        if let onAddToLibrary = actions.onAddToLibrary, !allLibraries.isEmpty {
            let otherLibraries = allLibraries.filter { $0.id != libraryID }
            if !otherLibraries.isEmpty {
                Menu("Add to Library") {
                    ForEach(otherLibraries, id: \.id) { targetLibrary in
                        Button(targetLibrary.name) {
                            Task {
                                await onAddToLibrary(ids, targetLibrary.id)
                            }
                        }
                    }
                }
            }
        }

        // Add to SciX Library submenu
        if let onAddToScixLibrary = actions.onAddToScixLibrary, !allScixLibraries.isEmpty {
            Menu {
                ForEach(allScixLibraries, id: \.id) { lib in
                    Button(lib.name) {
                        Task { await onAddToScixLibrary(ids, lib.id) }
                    }
                }
            } label: {
                Label("Add to SciX Library", systemImage: "cloud.fill")
            }
        }

        // Remove from all collections
        if let onRemoveFromAllCollections = actions.onRemoveFromAllCollections {
            Button("Remove from All Collections") {
                Task {
                    await onRemoveFromAllCollections(ids)
                }
            }
        }

        // MARK: Move/Triage Actions

        // Move to Library
        if let onSaveToLibrary = actions.onSaveToLibrary, !allLibraries.isEmpty {
            let moveLibraries = allLibraries.filter { $0.id != libraryID }
            if !moveLibraries.isEmpty {
                Menu("Move to Library") {
                    ForEach(moveLibraries, id: \.id) { targetLibrary in
                        Button(targetLibrary.name) {
                            Task {
                                await onSaveToLibrary(ids, targetLibrary.id)
                            }
                        }
                    }
                }
            }
        }

        // Dismiss from Inbox
        if let onDismiss = actions.onDismiss {
            Button("Dismiss from Inbox") {
                Task { await onDismiss(ids) }
            }
        }

        // Explore submenu
        if actions.onExploreReferences != nil || actions.onExploreCitations != nil || actions.onExploreSimilar != nil {
            if let first = ids.first {
                Divider()
                Menu {
                    if let onExploreReferences = actions.onExploreReferences {
                        Button {
                            onExploreReferences(first)
                        } label: {
                            Label("Find References", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    if let onExploreCitations = actions.onExploreCitations {
                        Button {
                            onExploreCitations(first)
                        } label: {
                            Label("Find Citations", systemImage: "quote.bubble")
                        }
                    }
                    if let onExploreSimilar = actions.onExploreSimilar {
                        Button {
                            onExploreSimilar(first)
                        } label: {
                            Label("Find Similar Papers", systemImage: "rectangle.stack")
                        }
                    }
                } label: {
                    Label("Explore", systemImage: "sparkle.magnifyingglass")
                }
            }
        }

        // Mute options
        if actions.onMuteAuthor != nil || actions.onMutePaper != nil {
            Divider()

            if let onMuteAuthor = actions.onMuteAuthor {
                if let first = ids.first,
                   let rowData = row(first) {
                    let firstName = rowData.authorString.split(separator: ",").first.map(String.init) ?? rowData.authorString
                    Button("Mute Author: \(firstName)") {
                        onMuteAuthor(firstName)
                    }
                }
            }

            if let onMutePaper = actions.onMutePaper {
                if let first = ids.first {
                    Button("Mute This Paper") {
                        onMutePaper(first)
                    }
                }
            }
        }

        Divider()

        // Delete
        if let onDelete = actions.onDelete {
            Button("Delete", role: .destructive) {
                willDelete()
                Task {
                    await onDelete(ids)
                }
            }
        }
    }

    private static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
