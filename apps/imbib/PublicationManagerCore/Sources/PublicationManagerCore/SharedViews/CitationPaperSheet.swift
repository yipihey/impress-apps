//
//  CitationPaperSheet.swift
//  PublicationManagerCore
//
//  The iOS counterpart of the macOS cite-key hover preview + paper panel.
//
//  On macOS, hovering `@smith2024` pops a `CiteKeyHoverView` with a
//  "Open in paper panel" button that hands the publication to
//  `PaperDetailPanel` (packages/ImpressPublicationUI) in the Source tab's
//  flanking inspector. iOS has neither hover nor a flanking inspector, so the
//  two collapse into one sheet raised by a long press — same content, same
//  "open in imbib" exit, one gesture instead of hover-then-click.
//
//  `PaperDetailPanel` itself is not reusable here: `ImpressPublicationUI`
//  declares `platforms: [.macOS(.v26)]`, imports AppKit, and its PDF tab is an
//  `NSViewRepresentable` resolving attachments under
//  `homeDirectoryForCurrentUser` — a path that does not exist on iOS. This view
//  lives in PMC (not in imprint-iOS) so imbib-iOS's manuscript editor gets the
//  same affordance from the same code.
//
//  It renders a `CitationResolution`, not a row, because the interesting half
//  of this feature is the MISS: see `ManuscriptCitationResolver` for why "no
//  such key" and "no papers on this device" must not look the same.
//

#if os(iOS)
import ImbibRustCore
import ImpressFTUI
import ImpressKit
import SwiftUI
import UIKit

/// Sheet showing the paper a cite key refers to — or an honest account of why
/// it doesn't refer to one.
public struct CitationPaperSheet: View {

    /// What the cite key resolved to.
    public let resolution: CitationResolution
    /// Host hook for "open this cite key in imbib". Defaults to opening the
    /// `impress://` URL, which is what imprint-iOS wants; injectable so a test
    /// (or a host with its own routing) can observe it instead.
    public var onOpenInImbib: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copiedBibTeX = false

    public init(
        resolution: CitationResolution,
        onOpenInImbib: ((String) -> Void)? = nil
    ) {
        self.resolution = resolution
        self.onOpenInImbib = onOpenInImbib
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch resolution {
                case .resolved(let row):
                    paper(row)
                case .unknownKey(let key, let count):
                    unknownKey(key, libraryCount: count)
                case .emptyLibrary(let key):
                    emptyLibrary(key)
                case .unavailable(let key):
                    unavailable(key)
                }
            }
            .navigationTitle("Citation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("citationPaper.done")
                }
            }
        }
        .accessibilityIdentifier("citationPaper.sheet.\(resolution.status)")
    }

    // MARK: - Resolved

    @ViewBuilder
    private func paper(_ row: BibliographyRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(row)

                if !row.authorString.isEmpty {
                    Text(row.authorString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("citationPaper.authors")
                }

                if let venue = row.venue, !venue.isEmpty {
                    Text(venue)
                        .font(.footnote)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                if !row.tags.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(row.tags, id: \.path) { tag in
                            TagChip(
                                tag: TagDisplayData(
                                    id: UUID(),
                                    path: tag.path,
                                    leaf: tag.leafName,
                                    colorLight: tag.colorLight,
                                    colorDark: tag.colorDark
                                ),
                                pathStyle: .leafOnly
                            )
                        }
                    }
                }

                if let abstract = row.abstractText, !abstract.isEmpty {
                    section("Abstract") {
                        Text(abstract)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("citationPaper.abstract")
                }

                if let note = row.note, !note.isEmpty {
                    section("Notes") {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                identifiers(row)
                actions(row)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ row: BibliographyRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.citeKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let year = row.year {
                    Text("· \(String(year))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.hasDownloadedPdf {
                    Image(systemName: "doc.fill").foregroundStyle(.blue).font(.caption)
                }
                if row.isStarred {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                }
            }
            Text(row.title.isEmpty ? row.citeKey : row.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("citationPaper.title")
        }
    }

    @ViewBuilder
    private func identifiers(_ row: BibliographyRow) -> some View {
        let pairs: [(String, String)] = [
            row.doi.map { ("DOI", $0) },
            row.arxivId.map { ("arXiv", $0) },
            row.bibcode.map { ("Bibcode", $0) },
        ].compactMap { $0 }

        if !pairs.isEmpty {
            section("Identifiers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pairs, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .leading)
                            Text(value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func actions(_ row: BibliographyRow) -> some View {
        VStack(spacing: 10) {
            Button {
                openInImbib(row.citeKey)
            } label: {
                Label("Open in imbib", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("citationPaper.openInImbib")

            Button {
                copyBibTeX(row.citeKey)
            } label: {
                Label(
                    copiedBibTeX ? "BibTeX copied" : "Copy BibTeX",
                    systemImage: copiedBibTeX ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("citationPaper.copyBibTeX")
        }
        .padding(.top, 4)
    }

    // MARK: - Misses
    //
    // Three different sentences, because they call for three different actions.

    private func unknownKey(_ key: String, libraryCount: Int?) -> some View {
        ContentUnavailableView {
            Label("No paper with this cite key", systemImage: "questionmark.circle")
        } description: {
            VStack(spacing: 6) {
                Text(verbatim: "@\(key)")
                    .font(.system(.body, design: .monospaced))
                if let libraryCount {
                    // One literal, not a `+` of two: string concatenation
                    // produces a `String`, which `Text` renders verbatim — the
                    // `^[…](inflect:)` markup would show up as itself.
                    Text("Your library has ^[\(libraryCount) paper](inflect: true), and none of them uses this cite key.")
                } else {
                    Text("No paper in your library uses this cite key.")
                }
                Text("Check the spelling, or add the paper in imbib.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("citationPaper.unknownKey")
    }

    private func emptyLibrary(_ key: String) -> some View {
        ContentUnavailableView {
            Label("No papers on this device", systemImage: "tray")
        } description: {
            VStack(spacing: 6) {
                Text(verbatim: "@\(key)")
                    .font(.system(.body, design: .monospaced))
                // Deliberately not "not in your library": the library was never
                // consulted in any meaningful sense — it is empty here.
                Text("Your library holds no papers on this device, so this cite key could not be looked up. It may still be perfectly correct.")
                Text("Add papers in imbib, or turn on sync to bring them here.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("citationPaper.emptyLibrary")
    }

    private func unavailable(_ key: String) -> some View {
        ContentUnavailableView {
            Label("Citation lookup unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(verbatim: "@\(key)")
                    .font(.system(.body, design: .monospaced))
                Text("This app has no publication library connected, so nothing could be looked up.")
            }
        }
        .accessibilityIdentifier("citationPaper.unavailable")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openInImbib(_ citeKey: String) {
        if let onOpenInImbib {
            onOpenInImbib(citeKey)
            return
        }
        if let url = ImpressURL.openPaper(citeKey: citeKey).url {
            openURL(url)
        }
    }

    /// BibTeX comes from the same store-backed export the compile pipeline
    /// uses — Rust owns round-trip fidelity, so nothing is assembled here.
    private func copyBibTeX(_ citeKey: String) {
        guard let bibtex = ManuscriptEditorEnvironment.shared
            .citationSearch?.bibliography(forKeys: [citeKey]) else { return }
        UIPasteboard.general.string = bibtex
        copiedBibTeX = true
    }
}
#endif
