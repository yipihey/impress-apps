//
//  PublicationPDFSwitcher.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — the "this paper has more than one PDF" picker.
//
//  macOS `PDFTab.pdfSwitcher` and `IOSPDFTab.pdfSwitcher` were the same view:
//  a `doc.fill` glyph, a `Menu` labelled with the current filename plus a
//  chevron, a checkmark on the current entry, the byte-count in secondary
//  style, and an "N PDFs" trailing caption. The only real differences were
//  macOS's `.menuStyle(.borderlessButton)` (no iOS equivalent) and the
//  background colour, which is an `#if` island INSIDE the shared view rather
//  than a reason to write it twice.
//
//  Kept verbatim from macOS (the frozen surface): 6pt vertical padding and the
//  size caption on every row. iOS previously used 8pt and hid the size when it
//  was zero.
//

import SwiftUI

/// Picker shown above the PDF viewer when a publication has several PDFs.
///
/// Renders nothing for zero or one PDF, so the host does not need the
/// `count > 1` test both copies had (it may still use it to avoid building the
/// row at all).
public struct PublicationPDFSwitcher: View {

    private let pdfs: [LinkedFileModel]
    private let current: LinkedFileModel
    private let isDarkModeEnabled: Bool
    private let onSelect: (LinkedFileModel) -> Void

    public init(
        pdfs: [LinkedFileModel],
        current: LinkedFileModel,
        isDarkModeEnabled: Bool = false,
        onSelect: @escaping (LinkedFileModel) -> Void
    ) {
        self.pdfs = pdfs
        self.current = current
        self.isDarkModeEnabled = isDarkModeEnabled
        self.onSelect = onSelect
    }

    public var body: some View {
        if pdfs.count > 1 {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            menu

            Spacer()

            Text("\(pdfs.count) PDFs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(background)
        .foregroundStyle(isDarkModeEnabled ? .white : .primary)
    }

    @ViewBuilder
    private var menu: some View {
        let picker = Menu {
            ForEach(pdfs, id: \.id) { pdf in
                Button {
                    onSelect(pdf)
                } label: {
                    HStack {
                        if pdf.id == current.id {
                            Image(systemName: "checkmark")
                        }
                        Text(Self.label(for: pdf))
                        Text("(\(Self.formattedFileSize(pdf.fileSize)))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.label(for: current))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }

        #if os(macOS)
        picker.menuStyle(.borderlessButton)
        #else
        picker
        #endif
    }

    private var background: Color {
        if isDarkModeEnabled { return Color.black.opacity(0.9) }
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }

    /// Byte count in the file style. `0` formats as "Zero KB" via
    /// `ByteCountFormatter`, which is what macOS shipped.
    public static func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The label for the reMarkable-annotated rendition a sync downloaded.
    public static let einkAnnotatedLabel = "reMarkable — annotated"

    /// What the picker calls a file: the rendition with the tablet's marks
    /// drawn in is named for what it IS rather than by its generated
    /// filename (ADR-025); every other file keeps its filename.
    public static func label(for file: LinkedFileModel) -> String {
        file.isEInkAnnotated ? einkAnnotatedLabel : file.filename
    }
}

public extension Array where Element == LinkedFileModel {
    /// The PDF a viewer opens by default: the PRIMARY PDF when one exists,
    /// never the reMarkable-annotated rendition (a variant the switcher
    /// offers, not the paper's own copy); then any PDF; then any file at
    /// all — the fallback both detail tabs had before ADR-025 added roles.
    var preferredPDF: LinkedFileModel? {
        // An explicit `primary` role first; older rows carry no role at all
        // and are primary by definition (`isPrimary`), so they come next.
        first(where: { $0.isPDF && $0.role == "primary" })
            ?? first(where: { $0.isPDF && $0.isPrimary })
            ?? first(where: { $0.isPDF && !$0.isEInkAnnotated })
            ?? first(where: { $0.isPDF })
            ?? first
    }
}
