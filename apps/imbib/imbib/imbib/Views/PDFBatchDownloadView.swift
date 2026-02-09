//
//  PDFBatchDownloadView.swift
//  imbib
//
//  Created by Claude on 2026-01-10.
//

import SwiftUI
import PublicationManagerCore
import OSLog

private let logger = Logger(subsystem: "com.imbib.app", category: "batch-download")

/// A sheet view that downloads PDFs for multiple publications with progress tracking.
struct PDFBatchDownloadView: View {
    let publicationIDs: [UUID]
    let libraryID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var downloadTask: Task<Void, Never>?
    @State private var currentIndex: Int = 0
    @State private var currentTitle: String = ""
    @State private var isComplete = false
    @State private var successCount = 0
    @State private var skipCount = 0
    @State private var failCount = 0

    private let store = RustStoreAdapter.shared

    var body: some View {
        VStack(spacing: 16) {
            Text("Downloading PDFs")
                .font(.headline)

            ProgressView(value: Double(currentIndex), total: Double(publicationIDs.count))
                .progressViewStyle(.linear)

            Text("\(currentIndex) of \(publicationIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !currentTitle.isEmpty {
                Text(currentTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isComplete {
                // Show summary
                VStack(spacing: 4) {
                    if successCount > 0 {
                        Text("\(successCount) downloaded")
                            .foregroundStyle(.green)
                    }
                    if skipCount > 0 {
                        Text("\(skipCount) skipped (already have PDF)")
                            .foregroundStyle(.secondary)
                    }
                    if failCount > 0 {
                        Text("\(failCount) failed")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .padding(.top, 8)
            }

            HStack(spacing: 12) {
                if isComplete {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        cancelDownload()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            startDownload()
        }
        .onDisappear {
            downloadTask?.cancel()
        }
    }

    // MARK: - Download Logic

    private func startDownload() {
        let ids = publicationIDs
        let libID = libraryID
        logger.info("[BatchDownload] Starting download for \(ids.count) papers")

        downloadTask = Task {
            for (index, pubID) in ids.enumerated() {
                if Task.isCancelled {
                    logger.info("[BatchDownload] Cancelled at \(index)/\(ids.count)")
                    break
                }

                guard let pub = store.getPublicationDetail(id: pubID) else {
                    logger.warning("[BatchDownload] Publication not found: \(pubID)")
                    await MainActor.run { failCount += 1 }
                    continue
                }

                await MainActor.run {
                    currentIndex = index
                    currentTitle = pub.title
                }

                // Skip if already has local PDF
                if pub.hasDownloadedPDF {
                    logger.info("[BatchDownload] Skipping '\(pub.citeKey)' - already has PDF")
                    await MainActor.run { skipCount += 1 }
                    continue
                }

                // Download PDF
                let success = await downloadPDF(for: pub, libraryID: libID)
                await MainActor.run {
                    if success {
                        successCount += 1
                    } else {
                        failCount += 1
                    }
                }
            }

            await MainActor.run {
                currentIndex = ids.count
                isComplete = true
                logger.info("[BatchDownload] Complete: \(successCount) downloaded, \(skipCount) skipped, \(failCount) failed")
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        dismiss()
    }

    private func downloadPDF(for publication: PublicationModel, libraryID: UUID) async -> Bool {
        // Resolve PDF URL using PDFURLResolverV2
        let settings = await PDFSettingsStore.shared.settings
        let accessStatus = await PDFURLResolverV2.shared.resolve(for: publication, settings: settings)

        guard let resolvedURL = accessStatus.pdfURL else {
            logger.warning("[BatchDownload] No PDF URL for '\(publication.citeKey)'")
            return false
        }

        logger.info("[BatchDownload] Downloading '\(publication.citeKey)' from: \(resolvedURL.absoluteString)")

        do {
            // Download to temp location
            let (tempURL, _) = try await URLSession.shared.download(from: resolvedURL)

            // Validate it's actually a PDF (check for %PDF header)
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let header = fileHandle.readData(ofLength: 4)
            try fileHandle.close()

            guard header.count >= 4,
                  header[0] == 0x25, // %
                  header[1] == 0x50, // P
                  header[2] == 0x44, // D
                  header[3] == 0x46  // F
            else {
                logger.warning("[BatchDownload] Not a valid PDF for '\(publication.citeKey)'")
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }

            // Import into library using AttachmentManager
            try AttachmentManager.shared.importPDF(from: tempURL, for: publication.id, in: libraryID)

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            logger.info("[BatchDownload] Downloaded '\(publication.citeKey)' successfully")
            return true

        } catch {
            logger.error("[BatchDownload] Failed '\(publication.citeKey)': \(error.localizedDescription)")
            return false
        }
    }
}
