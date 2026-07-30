#if os(iOS)
// Chassis file — iOS-only. Lifted out of the imbib app target in I2; see
// `IOSPublicationDetailPane.swift` for why, and for the injection points.
//
//  IOSPDFTab.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-07.
//

import SwiftUI
import OSLog

private let pdfLogger = Logger(subsystem: "com.imbib.app", category: "pdf-tab")

/// PDF tab state.
///
/// Stage 5b: the three FILE states (`hasPDF` / `cloudOnly` / `fileMissing`) and
/// `noPDF` are no longer classified here — `PublicationPDFAvailability` in PMC
/// answers "where is this paper's PDF" for both platforms. What stays local are
/// the TRANSIENT states, which are this tab's own touch-flow chrome: a
/// determinate download progress bar with a Cancel button, and a failure state
/// that offers the in-app browser.
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
public struct IOSPDFTab: View {
    let publicationID: UUID
    let libraryID: UUID?
    @Binding var isFullscreen: Bool

    public init(publicationID: UUID, libraryID: UUID? = nil, isFullscreen: Binding<Bool>) {
        self.publicationID = publicationID
        self.libraryID = libraryID
        self._isFullscreen = isFullscreen
    }

    @State private var state: PDFTabState = .loading
    @State private var showPDFBrowser = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var publication: PublicationModel?

    public var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .hasPDF(let linkedFile):
                VStack(spacing: 0) {
                    // The SHARED switcher (Stage 5b) — it renders nothing for a
                    // single PDF, so the `count > 1` test lives in one place.
                    PublicationPDFSwitcher(
                        pdfs: publication?.linkedFiles.filter(\.isPDF) ?? [],
                        current: linkedFile
                    ) { pdf in
                        state = .hasPDF(pdf)
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
                onPDFSaved: { _ in
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

    /// Classify via the shared `PublicationPDFAvailability` (Stage 5b) and map
    /// its answer onto this tab's states.
    ///
    /// The classification it replaces was 25 lines here plus a hand-rolled
    /// two-candidate file-existence check that duplicated
    /// `AttachmentManager.resolveURL`'s four. It also missed `eprint`-only
    /// papers: an import that carried an arXiv id in `eprint` rather than
    /// `arxivID` offered NO download on iPhone, while macOS's PDF tab has
    /// always accepted it.
    private func checkPDFState() async {
        let availability = PublicationPDFAvailability.resolve(
            publication: publication, libraryID: libraryID)

        if let pub = publication {
            pdfLogger.info("Checking PDF state for \(pub.citeKey)")
        }

        switch availability {
        case .localFile(let file):
            pdfLogger.info("Found existing PDF on disk: \(file.filename)")
            state = .hasPDF(file)
        case .cloudOnly(let file):
            pdfLogger.info("PDF available in cloud but not locally materialized")
            state = .cloudOnly(file)
        case .fileMissing(let file):
            pdfLogger.warning("PDF file missing from disk: \(file.filename)")
            state = .fileMissing(file)
        case .remoteAvailable:
            await attemptAutoDownload()
        case .unavailable:
            state = .noPDF
        }
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
                // Resolve the PDF URL through the SAME resolver macOS uses
                // (Stage 5b). The local `resolvePDFURL` this replaces knew two
                // rules — arXiv id, then the bare DOI resolver — where
                // `PDFURLResolverV2` (cross-platform since it was written)
                // honours the user's PDF settings, OpenAlex open-access
                // locations, the publisher registry, landing-page scraping and
                // bibcode/eprint identifiers, and reports a browser fallback
                // URL when it cannot get bytes.
                let settings = await PDFSettingsStore.shared.settings
                let status = await PDFURLResolverV2.shared.resolve(for: pub, settings: settings)
                guard let pdfURL = status.pdfURL else {
                    pdfLogger.warning("No PDF URL resolved")
                    if status.browserURL != nil {
                        // There IS a page to try by hand — say so instead of
                        // rendering the "no PDF" dead end.
                        state = .downloadFailed(
                            message: "No direct PDF link was found. Try the browser option.")
                    } else {
                        state = .noPDF
                    }
                    return
                }

                pdfLogger.info("Resolved PDF URL: \(pdfURL.absoluteString)")

                // Download the PDF with a bounded timeout. URLSession.shared's
                // default resource timeout is 7 DAYS — a stalled connection
                // (publisher paywall dropping bytes, captive network) left the
                // spinner "loading" forever with nothing arriving. 30s to
                // first byte / 2min total, then fail into .downloadFailed so
                // the user gets the browser fallback instead of a phantom load.
                state = .downloading(progress: 0.2)
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 120
                let session = URLSession(configuration: config)
                defer { session.finishTasksAndInvalidate() }
                let (data, _) = try await session.data(from: pdfURL)

                guard !Task.isCancelled else { return }

                state = .downloading(progress: 0.6)

                // Verify it's a PDF
                guard isPDF(data) else {
                    pdfLogger.warning("Downloaded data is not a PDF")
                    state = .downloadFailed(message: "The file is not a valid PDF. Try the browser option.")
                    return
                }

                state = .downloading(progress: 0.8)

                // Import via AttachmentManager (value-type store: keyed by UUIDs)
                try AttachmentManager.shared.importPDF(
                    data: data,
                    for: publicationID,
                    in: libraryID
                )

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

    private func isPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])
    }

}

#endif  // os(iOS)
