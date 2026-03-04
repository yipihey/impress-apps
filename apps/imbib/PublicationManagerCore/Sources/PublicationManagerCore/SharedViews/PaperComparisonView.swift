//
//  PaperComparisonView.swift
//  PublicationManagerCore
//
//  Sheet showing structured comparison between 2-4 papers.
//

import SwiftUI

// MARK: - Paper Comparison View

/// Sheet view showing a structured comparison of 2-4 papers.
public struct PaperComparisonView: View {

    @Bindable var viewModel: PaperComparisonViewModel
    let publicationIDs: [UUID]
    var onNavigateToPaper: ((UUID) -> Void)?

    @Environment(\.dismiss) private var dismiss

    public init(
        viewModel: PaperComparisonViewModel,
        publicationIDs: [UUID],
        onNavigateToPaper: ((UUID) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.publicationIDs = publicationIDs
        self.onNavigateToPaper = onNavigateToPaper
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.purple)
                Text("Paper Comparison")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if viewModel.isComparing {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Comparing papers...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let result = viewModel.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Paper list
                        paperListSection(result.papers)

                        Divider()

                        // Comparison text (markdown)
                        Text(result.comparison)
                            .textSelection(.enabled)
                            .font(.body)
                    }
                    .padding()
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await viewModel.compare(publicationIDs: publicationIDs) }
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Preparing comparison...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 900,
               minHeight: 400, idealHeight: 600, maxHeight: 800)
        .task {
            if viewModel.result == nil {
                await viewModel.compare(publicationIDs: publicationIDs)
            }
        }
    }

    private func paperListSection(_ papers: [PaperComparisonViewModel.PaperInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Papers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(papers) { paper in
                Button {
                    onNavigateToPaper?(paper.id)
                } label: {
                    HStack {
                        Text("[\(paper.bibkey)]")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        Text(paper.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(paper.year ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
