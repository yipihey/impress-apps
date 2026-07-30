#if os(iOS)
// Chassis file — iOS-only. Lifted with `IOSPDFTab` in I2 (it is that tab's
// empty state), so the tab's public surface has no app-private dependency.
//
//  IOSNoPDFView.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import OSLog

/// iOS view shown in PDF tab when no PDF is attached.
/// Offers options to download PDF from publisher or import from Files.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSNoPDFView: View {
    let publicationID: UUID?
    let libraryID: UUID?

    init(publicationID: UUID? = nil, libraryID: UUID? = nil) {
        self.publicationID = publicationID
        self.libraryID = libraryID
    }

    @State private var showPDFBrowser = false
    @State private var showFilePicker = false
    @State private var publication: PublicationModel?

    private var hasPublisherAccess: Bool {
        guard let pub = publication else { return false }
        return pub.doi != nil || pub.bibcode != nil
    }

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
                if hasPublisherAccess {
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
        .task(id: publicationID) {
            if let id = publicationID {
                publication = RustStoreAdapter.shared.getPublicationDetail(id: id)
            }
        }
        .sheet(isPresented: $showPDFBrowser) {
            IOSPDFBrowserView(
                publicationID: publicationID,
                libraryID: libraryID,
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
        guard let pub = publication else { return nil }
        if pub.arxivID != nil {
            return "arXiv preprint available"
        } else if pub.bibcode != nil {
            return "Publisher access via ADS"
        } else if pub.doi != nil {
            return "Publisher access via DOI"
        }
        return nil
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        // publicationID / libraryID are immutable `let` properties — safe to read directly.
        let pubID = publicationID
        let libID = libraryID
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard let pubID else {
                Logger.files.warningCapture("iOS NoPDFView: import skipped, no publication ID", category: "files")
                return
            }

            // Start security-scoped access
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                Logger.files.infoCapture(
                    "iOS NoPDFView: importing PDF '\(url.lastPathComponent)' (\(data.count) bytes) for \(pubID)",
                    category: "files"
                )
                // Value-type store: import keyed by publication + library UUIDs.
                let linked = try AttachmentManager.shared.importPDF(
                    data: data,
                    for: pubID,
                    in: libID
                )
                Logger.files.infoCapture(
                    "iOS NoPDFView: imported PDF linked file \(linked.id) (\(linked.filename))",
                    category: "files"
                )
            } catch {
                Logger.files.errorCapture(
                    "iOS NoPDFView: failed to import PDF: \(error.localizedDescription)",
                    category: "files"
                )
            }

        case .failure(let error):
            Logger.files.errorCapture("iOS NoPDFView: file picker error: \(error.localizedDescription)", category: "files")
        }
    }
}

#endif  // os(iOS)
