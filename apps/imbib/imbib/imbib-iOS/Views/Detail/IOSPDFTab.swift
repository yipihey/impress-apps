//
//  IOSPDFTab.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import PublicationManagerCore
import OSLog

private let pdfLogger = Logger(subsystem: "com.imbib.app", category: "pdf-tab")

/// PDF tab state
private enum PDFTabState: Equatable {
    case loading
    case hasPDF(LinkedFileModel)
    case fileMissing(LinkedFileModel)
    case cloudOnly(LinkedFileModel)
    case downloading(progress: Double)
    case downloadFailed(message: String)
    case noPDF
}

/// iOS PDF tab for viewing embedded PDFs with auto-download support.
/// Uses RustStoreAdapter for all data access (no Core Data).
struct IOSPDFTab: View {
    let publicationID: UUID
    let libraryID: UUID
    @Binding var isFullscreen: Bool

    @Environment(LibraryManager.self) private var libraryManager

    @State private var state: PDFTabState = .loading
    @State private var showPDFBrowser = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var publication: PublicationModel?

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .hasPDF(let linkedFile):
                VStack(spacing: 0) {
                    // PDF switcher (only shown when multiple PDFs attached)
                    let allPDFs = publication?.linkedFiles.filter(\.isPDF) ?? []
                    if allPDFs.count > 1 {
                        pdfSwitcher(currentPDF: linkedFile, allPDFs: allPDFs)
                    }

                    PDFViewerWithControls(
                        linkedFile: linkedFile,
                        libraryID: libraryID,
                        publicationID: publicationID,
                        isFullscreen: $isFullscreen
                    )
                }

            case .fileMissing(let linkedFile):
                fileMissingView(linkedFile: linkedFile)

            case .cloudOnly(let linkedFile):
                cloudOnlyView(linkedFile: linkedFile)

            case .downloading(let progress):
                downloadingView(progress: progress)

            case .downloadFailed(let message):
                downloadFailedView(message: message)

            case .noPDF:
                IOSNoPDFView(publicationID: publicationID, libraryID: libraryID)
            }
        }
        .task(id: publicationID) {
            loadPublication()
            await checkPDFState()
        }
        .sheet(isPresented: $showPDFBrowser) {
            IOSPDFBrowserView(
                publicationID: publicationID,
                libraryID: libraryID,
                onPDFSaved: {
                    Task {
                        loadPublication()
                        await checkPDFState()
                    }
                }
            )
        }
    }

    // MARK: - Data Loading

    private func loadPublication() {
        publication = RustStoreAdapter.shared.getPublicationDetail(id: publicationID)
    }

    // MARK: - Downloading View

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView(value: progress) {
                Text("Downloading PDF...")
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 200)

            Button("Cancel") {
                downloadTask?.cancel()
                state = .noPDF
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding()
    }

    // MARK: - File Missing View

    private func fileMissingView(linkedFile: LinkedFileModel) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("PDF File Missing")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("The PDF was previously downloaded but the file is no longer available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    Task {
                        await attemptAutoDownload()
                    }
                } label: {
                    Label("Re-download PDF", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showPDFBrowser = true
                } label: {
                    Label("Open in Browser", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }

    // MARK: - Cloud Only View (On-Demand Download)

    private func cloudOnlyView(linkedFile: LinkedFileModel) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("PDF Available in iCloud")
                    .font(.title2)
                    .fontWeight(.semibold)

                if linkedFile.fileSize > 0 {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: linkedFile.fileSize, countStyle: .file)
                    Text("Tap to download (\(sizeStr))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to download")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await attemptAutoDownload()
                }
            } label: {
                Label("Download PDF", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }

    // MARK: - Download Failed View

    private func downloadFailedView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Download Failed")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    Task {
                        await attemptAutoDownload()
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showPDFBrowser = true
                } label: {
                    Label("Open in Browser", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }

    // MARK: - State Management

    private func checkPDFState() async {
        guard let pub = publication else {
            state = .noPDF
            return
        }

        pdfLogger.info("Checking PDF state for \(pub.citeKey)")

        // Check for PDF linked files
        let pdfFiles = pub.linkedFiles.filter(\.isPDF)
        if let primaryPDF = pdfFiles.first {
            pdfLogger.info("Found existing PDF record: \(primaryPDF.filename)")

            // Verify the actual file exists on disk
            if pdfFileExists(linkedFile: primaryPDF) {
                state = .hasPDF(primaryPDF)
            } else if primaryPDF.pdfCloudAvailable && !primaryPDF.isLocallyMaterialized {
                pdfLogger.info("PDF available in cloud but not locally materialized")
                state = .cloudOnly(primaryPDF)
            } else {
                pdfLogger.warning("PDF file missing from disk")
                state = .fileMissing(primaryPDF)
            }
            return
        }

        // Check if we can auto-download
        if pub.arxivID != nil || pub.doi != nil || pub.bibcode != nil {
            await attemptAutoDownload()
        } else {
            state = .noPDF
        }
    }

    private func pdfFileExists(linkedFile: LinkedFileModel) -> Bool {
        guard let library = libraryManager.find(id: libraryID),
              let path = linkedFile.relativePath else {
            return false
        }

        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let containerURL = library.containerURL.appendingPathComponent(normalizedPath)
        return FileManager.default.fileExists(atPath: containerURL.path)
    }

    private func attemptAutoDownload() async {
        guard let pub = publication else {
            state = .noPDF
            return
        }

        pdfLogger.info("Attempting auto-download for \(pub.citeKey)")
        state = .downloading(progress: 0)

        downloadTask = Task {
            do {
                // Resolve PDF URL
                guard let pdfURL = resolvePDFURL(pub) else {
                    pdfLogger.warning("No PDF URL resolved")
                    state = .noPDF
                    return
                }

                pdfLogger.info("Resolved PDF URL: \(pdfURL.absoluteString)")

                // Download the PDF
                state = .downloading(progress: 0.2)
                let (data, _) = try await URLSession.shared.data(from: pdfURL)

                guard !Task.isCancelled else { return }

                state = .downloading(progress: 0.6)

                // Verify it's a PDF
                guard isPDF(data) else {
                    pdfLogger.warning("Downloaded data is not a PDF")
                    state = .downloadFailed(message: "The file is not a valid PDF. Try the browser option.")
                    return
                }

                state = .downloading(progress: 0.8)

                // Import via AttachmentManager
                if let library = libraryManager.find(id: libraryID) {
                    try AttachmentManager.shared.importPDF(
                        data: data,
                        publicationID: publicationID,
                        in: library
                    )
                }

                pdfLogger.info("PDF saved successfully")

                state = .downloading(progress: 1.0)

                // Reload and check state
                try? await Task.sleep(for: .milliseconds(500))
                loadPublication()
                await checkPDFState()

            } catch is CancellationError {
                pdfLogger.info("Download cancelled")
            } catch {
                pdfLogger.error("Download failed: \(error.localizedDescription)")
                state = .downloadFailed(message: error.localizedDescription)
            }
        }

        await downloadTask?.value
    }

    private func resolvePDFURL(_ pub: PublicationModel) -> URL? {
        // Priority 1: arXiv direct PDF (always open access)
        if let arxivID = pub.arxivID {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }

        // Priority 2: DOI resolver
        if let doi = pub.doi {
            return URL(string: "https://doi.org/\(doi)")
        }

        return nil
    }

    private func isPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])
    }

    // MARK: - PDF Switcher

    @ViewBuilder
    private func pdfSwitcher(currentPDF: LinkedFileModel, allPDFs: [LinkedFileModel]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)

            Menu {
                ForEach(allPDFs, id: \.id) { pdf in
                    Button {
                        state = .hasPDF(pdf)
                    } label: {
                        HStack {
                            if pdf.id == currentPDF.id {
                                Image(systemName: "checkmark")
                            }
                            Text(pdf.filename)
                            if pdf.fileSize > 0 {
                                let sizeStr = ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file)
                                Text("(\(sizeStr))")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentPDF.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
            }

            Spacer()

            Text("\(allPDFs.count) PDFs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}
