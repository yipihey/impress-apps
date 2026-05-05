//
//  ExternalCitationPicker.swift
//  imprint
//
//  Extracted from CitedPapersSection — presented at `ContentView.mainContent`
//  level (not inside the sidebar List's Section) so Section body re-evals
//  during import don't interrupt the sheet's dismiss animation.
//

import SwiftUI
import ImpressKit
import ImpressLogging

/// Modal sheet that shows external-source candidates for a cite key that
/// couldn't be resolved locally. Picking a row imports that paper into
/// imbib (using its DOI / arXiv id) and re-queries the library.
public struct ExternalCitationPicker: View {
    // Use SwiftUI's own dismiss so we don't manually toggle the parent's
    // sheet binding — that was causing the macOS sheet-presentation
    // animation to re-fire repeatedly. `dismiss()` runs SwiftUI's native
    // dismissal path which cleans up atomically.
    @Environment(\.dismiss) private var dismiss

    public let paper: CitationResult
    public let candidates: [ImbibExternalCandidate]
    public let onPick: (ImbibExternalCandidate) -> Void

    public init(
        paper: CitationResult,
        candidates: [ImbibExternalCandidate],
        onPick: @escaping (ImbibExternalCandidate) -> Void
    ) {
        self.paper = paper
        self.candidates = candidates
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a paper to add to imbib").font(.headline)
                    Text("For citation `\(paper.citeKey)` — external candidates from ADS / arXiv / Crossref")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No external matches").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { candidate in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title).font(.headline).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(candidate.authors).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                if let y = candidate.year { Text("· \(String(y))").font(.subheadline).foregroundStyle(.secondary) }
                                if let v = candidate.venue, !v.isEmpty {
                                    Text("· \(v)").font(.subheadline).foregroundStyle(.secondary).italic().lineLimit(1)
                                }
                            }
                            Text("\(candidate.sourceID) · \(identifierLabel(for: candidate))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Add") {
                            // Dismiss first so SwiftUI can run the sheet
                            // close animation without interference from
                            // re-renders triggered by `onPick` kicking off
                            // state mutations on the parent.
                            dismiss()
                            onPick(candidate)
                        }
                        .controlSize(.small)
                        .disabled(candidate.identifier.isEmpty)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            logInfo("ExternalCitationPicker appeared for '\(paper.citeKey)' (\(candidates.count) candidates)", category: "citations")
        }
        .onDisappear {
            logInfo("ExternalCitationPicker disappeared for '\(paper.citeKey)'", category: "citations")
        }
    }

    private func identifierLabel(for candidate: ImbibExternalCandidate) -> String {
        if let doi = candidate.doi, !doi.isEmpty { return "doi:\(doi)" }
        if let arxiv = candidate.arxivID, !arxiv.isEmpty { return "arXiv:\(arxiv)" }
        if let bib = candidate.bibcode, !bib.isEmpty { return bib }
        return candidate.identifier
    }
}
