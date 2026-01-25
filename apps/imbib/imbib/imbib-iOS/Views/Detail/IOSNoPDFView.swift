//
//  IOSNoPDFView.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore

/// iOS view shown in PDF tab when no PDF is attached.
/// Offers options to download PDF from publisher or import from Files.
struct IOSNoPDFView: View {
    let publication: CDPublication
    let libraryID: UUID

    @Environment(LibraryManager.self) private var libraryManager
    @State private var showPDFBrowser = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            // Message
            VStack(spacing: 8) {
                Text("No PDF Available")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Download from publisher or import from your files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Actions
            VStack(spacing: 12) {
                // Download from publisher (if we have identifiers)
                if publication.doi != nil || publication.bibcode != nil {
                    Button {
                        showPDFBrowser = true
                    } label: {
                        Label("Open in Browser", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Source info
                    if let source = pdfSourceDescription {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Import from Files
                Button {
                    showFilePicker = true
                } label: {
                    Label("Import from Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showPDFBrowser) {
            IOSPDFBrowserView(
                publication: publication,
                library: libraryManager.find(id: libraryID),
                onPDFSaved: nil
            )
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Computed Properties

    private var pdfSourceDescription: String? {
        if publication.arxivID != nil {
            return "arXiv preprint available"
        } else if publication.bibcode != nil {
            return "Publisher access via ADS"
        } else if publication.doi != nil {
            return "Publisher access via DOI"
        }
        return nil
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start security-scoped access
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)

                // Import via PDFManager
                try PDFManager.shared.importPDF(
                    data: data,
                    for: publication,
                    in: libraryManager.find(id: libraryID)
                )
            } catch {
                // Log error - could add alert here
                print("Failed to import PDF: \(error)")
            }

        case .failure(let error):
            print("File picker error: \(error)")
        }
    }
}
