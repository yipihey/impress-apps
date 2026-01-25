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
    let publications: [CDPublication]
    let library: CDLibrary

    @Environment(\.dismiss) private var dismiss

    @State private var downloadTask: Task<Void, Never>?
    @State private var currentIndex: Int = 0
    @State private var currentTitle: String = ""
    @State private var isComplete = false
    @State private var successCount = 0
    @State private var skipCount = 0
    @State private var failCount = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Downloading PDFs")
                .font(.headline)

            ProgressView(value: Double(currentIndex), total: Double(publications.count))
                .progressViewStyle(.linear)

            Text("\(currentIndex) of \(publications.count)")
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
        logger.info("[BatchDownload] Starting download for \(publications.count) papers")

        downloadTask = Task {
            for (index, pub) in publications.enumerated() {
                if Task.isCancelled {
                    logger.info("[BatchDownload] Cancelled at \(index)/\(publications.count)")
                    break
                }

                await MainActor.run {
                    currentIndex = index
                    currentTitle = pub.title ?? pub.citeKey
                }

                // Skip if already has local PDF
                if hasLocalPDF(pub) {
                    logger.info("[BatchDownload] Skipping '\(pub.citeKey)' - already has PDF")
                    await MainActor.run { skipCount += 1 }
                    continue
                }

                // Download PDF
                let success = await downloadPDF(for: pub)
                await MainActor.run {
                    if success {
                        successCount += 1
                    } else {
                        failCount += 1
                    }
                }
            }

            await MainActor.run {
                currentIndex = publications.count
                isComplete = true
                logger.info("[BatchDownload] Complete: \(successCount) downloaded, \(skipCount) skipped, \(failCount) failed")
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        dismiss()
    }

    private func hasLocalPDF(_ publication: CDPublication) -> Bool {
        guard let linkedFiles = publication.linkedFiles else { return false }
        return linkedFiles.contains { $0.isPDF }
    }

    private func downloadPDF(for publication: CDPublication) async -> Bool {
        // Resolve PDF URL
        let settings = await PDFSettingsStore.shared.settings
        guard let resolvedURL = PDFURLResolver.resolveForAutoDownload(for: publication, settings: settings) else {
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

            // Import into library using PDFManager
            try PDFManager.shared.importPDF(from: tempURL, for: publication, in: library)

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
