#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
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
import AppKit
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
           let image = NSImage(data: data) {
            // NSImage decodes PNG/JPEG/TIFF and PDF data. SVG (and anything
            // else it can't decode) falls through to the hint below.
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: max(image.size.width, 100),
                        maxHeight: max(image.size.height, 100))
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
#endif
