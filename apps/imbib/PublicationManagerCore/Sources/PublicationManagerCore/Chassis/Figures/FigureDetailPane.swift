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
//  (DetailTab.pdf relabeled) renders the CAS artifact via NSImage, which
//  handles PNG/JPEG/PDF. SVG (no WebKit in PMC) and other formats fall back
//  to an "Open in Canvas" hint — kept minimal and honest.
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
            // Refresh the snapshot when this figure mutates elsewhere.
            for await event in ImbibImpressStore.shared.events.subscribe() {
                if case .itemsMutated(_, let ids) = event, ids.contains(figureID) {
                    row = FigureStoreReader.shared.fetchFigure(id: figureID.uuidString)
                        .flatMap { FigureRowData(from: $0) }
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

    @ViewBuilder
    private var viewTab: some View {
        if let hash = row?.dataHash,
           let data = FigureStoreReader.shared.contentData(hash: hash),
           let artifact = PlatformArtifactImage(data: data) {
            // NSImage/UIImage decode PNG/JPEG/TIFF and PDF data. SVG (and
            // anything else they can't decode) falls through to the hint below.
            ScrollView([.horizontal, .vertical]) {
                artifact.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: max(artifact.size.width, 100),
                        maxHeight: max(artifact.size.height, 100))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo").font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No renderable artifact")
                    .foregroundStyle(.secondary)
                Text("This format can't be previewed here — open the figure in the canvas.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
