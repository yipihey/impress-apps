// Chassis file — CROSS-PLATFORM (macOS + iOS) since ADR-0022 D9.
//
// It was gated `#if os(macOS)` with the comment "macOS-only in GUI-meld Phase 1
// (iOS keeps IOSContentView)", which was historical rather than technical: the
// whole file was plain SwiftUI over `RelatedItemsSection` (already
// cross-platform) and `FigureStoreReader` (already cross-platform), with
// exactly ONE AppKit call — `NSImage(data:)` in the View tab. impress-iOS was
// the first host to want a figure detail on a phone, and the honest answer to
// "the chassis has no iOS figure pane" is to fix the chassis, not to write a
// sixth app's private copy. `UIImage` decodes the same PNG/JPEG/PDF data.
//
//  FigureDetailPane.swift
//  PublicationManagerCore
//
//  The tabbed figure detail (Stage 2-B): the standard chassis detail
//  experience for a figure item, mirroring ManuscriptDetailPane's tab host —
//  Info / View. Tabs come from FigureRecordKind.descriptor; the View tab
//  (DetailTab.pdf relabeled) renders the CAS artifact via NSImage/UIImage:
//  PNG (what implore stores), JPEG, TIFF, PDF, and on macOS SVG too
//  (NSImage's SVG rep). An artifact that cannot be drawn gets a hint naming
//  why — kept minimal and honest.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import ImpressFTUI
import ImpressRustCore
import ImpressStoreKit

public struct FigureDetailPane: View {

    let figureID: UUID
    @Binding var selectedTab: DetailTab

    /// Top clearance for the tab picker (the section host reclaims the
    /// toolbar band with `.ignoresSafeArea(.top)` — same as manuscripts).
    let topInset: CGFloat

    @State private var row: FigureRowData?

    public init(
        figureID: UUID,
        selectedTab: Binding<DetailTab>,
        topInset: CGFloat = 0
    ) {
        self.figureID = figureID
        self._selectedTab = selectedTab
        self.topInset = topInset
    }

    /// RecordTabContext has isEditable/previewKind only — figures encode
    /// "has a rendered artifact" through previewKind: `.compiledPDF` when the
    /// payload carries a data_hash, `.none` otherwise. This is what gates the
    /// View tab in FigureRecordKind.descriptor.
    private var tabContext: RecordTabContext {
        RecordTabContext(
            previewKind: row?.dataHash != nil ? .compiledPDF : DocumentFormat.PreviewKind.none)
    }

    private var availableTabs: [DetailTab] {
        FigureRecordKind.descriptor.availableTabs(for: tabContext)
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, topInset)
            Divider()
            content
        }
        .onChange(of: figureID, initial: true) { _, id in
            row = FigureStoreReader.shared.fetchFigure(id: id.uuidString)
                .flatMap { FigureRowData(from: $0) }
            let coerced = FigureRecordKind.descriptor.coercedTab(selectedTab, for: tabContext)
            if coerced != selectedTab { selectedTab = coerced }
        }
        .task(id: figureID) {
            // Refresh the snapshot when this figure mutates elsewhere. A
            // write from ANOTHER process (implore storing a new artifact
            // while impress shows this tab) arrives as `.structural` with no
            // ids — the Darwin note carries none — so that re-reads too, and
            // assigns only when the row actually changed.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if FigureArtifactRefresh.shouldReread(event, figureID: figureID) {
                    let fresh = FigureStoreReader.shared.fetchFigure(id: figureID.uuidString)
                        .flatMap { FigureRowData(from: $0) }
                    if fresh != row { row = fresh }
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                // The figure "PDF" tab is really the rendered-artifact
                // surface — label it "View".
                Label(tab == .pdf ? "View" : tab.label,
                      systemImage: tab == .pdf ? "photo" : tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .info:
            infoTab
        case .pdf:
            viewTab
        case .source, .notes, .bibtex:
            // Not part of the figure tab set; coerced away on entry.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Info tab

    @ViewBuilder
    private var infoTab: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(row.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)

                    if let caption = row.caption, !caption.isEmpty {
                        Text(caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        infoRow("Format", row.format.isEmpty ? "—" : row.format.capitalized)
                        infoRow("Added", row.dateAdded.formatted(date: .abbreviated, time: .shortened))
                        infoRow("Modified", row.dateModified.formatted(date: .abbreviated, time: .shortened))
                        if let hash = row.dataHash {
                            infoRow("Data hash", hash, monospaced: true)
                        }
                        if let hash = row.scriptHash {
                            infoRow("Script hash", hash, monospaced: true)
                        }
                    }

                    // ADR-0022 D8 (G5): edges this figure sits on — the
                    // manuscripts that embed it, the run that produced it.
                    // Renders nothing when it has none.
                    RelatedItemsSection(itemID: figureID)

                    if row.flag != nil || !row.tagDisplays.isEmpty {
                        Divider()
                    }
                    if let flag = row.flag {
                        HStack(spacing: 6) {
                            Image(systemName: "flag.fill")
                                .foregroundStyle(flag.color.displayColor)
                            Text(flag.color.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !row.tagDisplays.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(row.tagDisplays) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Figure Unavailable",
                systemImage: "photo",
                description: Text("This figure could not be read from the store.")
            )
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }

    // MARK: View tab (CAS artifact)

    /// The rendered artifact, drawn by `FigureArtifactView` — the same view
    /// the layout tree's `plot` pane shows, so the two cannot disagree.
    private var viewTab: some View {
        FigureArtifactView(dataHash: row?.dataHash)
    }
}

// MARK: - Figure artifact

/// A figure's rendered plot: the CAS artifact its `data_hash` names, decoded
/// by `PlatformArtifactImage` (PNG / JPEG / TIFF / PDF), or the honest "no
/// renderable artifact" hint when there is none or it cannot be decoded.
///
/// Moved out of `FigureDetailPane`'s View tab (plan wave 6 follow-up: the
/// `plot` view kind) so the tab and the layout tree's `plot` pane
/// (`LayoutPlotPaneView`) draw a figure ONE way. Unchanged except that the
/// image now fits its space instead of scrolling at natural size (below). A figure in the store
/// carries no plot spec — implore renders from its own session and mirrors
/// the result into the CAS — so this artifact is the figure's plot as every
/// app other than implore can see it.
public struct FigureArtifactView: View {

    let dataHash: String?

    public init(dataHash: String?) {
        self.dataHash = dataHash
    }

    public var body: some View {
        switch FigureArtifactState.resolve(
            dataHash: dataHash, bytes: { FigureStoreReader.shared.contentData(hash: $0) })
        {
        case .image(let artifact):
            // NSImage/UIImage decode PNG (implore's stored artifact),
            // JPEG/TIFF and PDF data; NSImage also decodes SVG.
            //
            // Fitted to the space it is given, never enlarged past its
            // natural size. It sat in a two-axis ScrollView, which proposes
            // unlimited space, so a 1384 pt plot drew at 1384 pt and a pane
            // (or a narrow detail column) showed its top-left corner — seen
            // live in implore's `plot` pane, 2026-09-24.
            artifact.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    maxWidth: max(artifact.size.width, 100),
                    maxHeight: max(artifact.size.height, 100))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noArtifact:
            hint("No renderable artifact",
                 "This figure has no stored image yet — save or export it from implore.")
        case .missingBytes(let hash):
            hint("Artifact not found",
                 "No file \(hash.prefix(12))… in this workspace's content store.")
        case .undecodableSVG:
            hint("SVG artifact",
                 "This device can't draw SVG — open the figure in implore on a Mac.")
        case .undecodable:
            hint("No renderable artifact",
                 "This format can't be previewed here — open the figure in the canvas.")
        }
    }

    private func hint(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What `FigureArtifactView` can draw for a `data_hash`: decided apart from
/// the view so it is testable without a store (the bytes come from a
/// closure), and so each reason it cannot draw has its own name.
enum FigureArtifactState {
    case image(PlatformArtifactImage)
    /// The row names no artifact.
    case noArtifact
    /// The row names bytes this workspace does not have.
    case missingBytes(String)
    /// SVG bytes the platform cannot decode (UIImage has no SVG decoder).
    case undecodableSVG
    /// Bytes nothing here decodes.
    case undecodable

    static func resolve(dataHash: String?, bytes: (String) -> Data?) -> FigureArtifactState {
        guard let hash = dataHash, !hash.isEmpty else { return .noArtifact }
        guard let data = bytes(hash) else { return .missingBytes(hash) }
        if let artifact = PlatformArtifactImage(data: data) { return .image(artifact) }
        return looksLikeSVG(data) ? .undecodableSVG : .undecodable
    }

    /// An `<svg` root within the first KB (after any XML prolog/comments).
    static func looksLikeSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(1024), encoding: .utf8) else { return false }
        return head.range(of: "<svg", options: .caseInsensitive) != nil
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// When a figure surface re-reads its row: an id-scoped mutation naming it,
/// or a `.structural` event — which is how a write from another process
/// (implore storing a figure's artifact) reaches this one, since the
/// cross-process Darwin note carries no ids.
enum FigureArtifactRefresh {
    static func shouldReread(_ event: StoreEvent, figureID: UUID) -> Bool {
        switch event {
        case .itemsMutated(_, let ids): return ids.contains(figureID)
        case .structural: return true
        case .collectionMembershipChanged: return false
        }
    }
}

// MARK: - Platform artifact image

/// The ONE platform bridge this pane needs: decode CAS artifact bytes and hand
/// back a SwiftUI `Image` plus its natural size.
///
/// Deliberately local rather than another `ImpressTheme` helper: that package
/// bridges COLORS, and an image decoder is not a colour. If a second chassis
/// surface needs it, it graduates — the `PlatformColors` file header states the
/// same rule.
struct PlatformArtifactImage {
    let image: Image
    let size: CGSize

    init?(data: Data) {
        #if os(macOS)
        guard let decoded = NSImage(data: data) else { return nil }
        self.image = Image(nsImage: decoded)
        self.size = decoded.size
        #else
        guard let decoded = UIImage(data: data) else { return nil }
        self.image = Image(uiImage: decoded)
        self.size = decoded.size
        #endif
    }
}
