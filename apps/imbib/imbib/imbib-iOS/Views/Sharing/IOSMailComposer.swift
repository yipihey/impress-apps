//
//  IOSMailComposer.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-18.
//  Revived 2026-07-20: migrated from the CDPublication reference type to the
//  value-type `PublicationModel` store. The view now takes a `publicationID`
//  (matching the interim stub's init) and resolves the full detail via
//  `RustStoreAdapter.shared.getPublicationDetail(id:)`.
//

import SwiftUI
import MessageUI
import PublicationManagerCore

/// A SwiftUI wrapper for MFMailComposeViewController that allows sharing papers
/// with PDF and BibTeX attachments.
struct IOSMailComposer: UIViewControllerRepresentable {

    // MARK: - Properties

    /// The publication to share, resolved from the value-type store by id.
    let publicationID: UUID?

    /// Closure called when the mail composer is dismissed
    let onDismiss: () -> Void

    init(publicationID: UUID? = nil, onDismiss: @escaping () -> Void = {}) {
        self.publicationID = publicationID
        self.onDismiss = onDismiss
    }

    // MARK: - Static Check

    /// Check if the device can send email
    static var canSendEmail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    // MARK: - Resolution

    /// Resolve the full publication detail from the shared value-type store.
    @MainActor
    private var publication: PublicationModel? {
        guard let publicationID else { return nil }
        return RustStoreAdapter.shared.getPublicationDetail(id: publicationID)
    }

    // MARK: - UIViewControllerRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    @MainActor
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator

        guard let publication else { return composer }

        // Set subject
        composer.setSubject("Paper: \(publication.title)")

        // Build email body
        let body = buildEmailBody(for: publication)
        composer.setMessageBody(body, isHTML: false)

        // Attach PDF if available
        attachPDF(to: composer, publication: publication)

        // Attach BibTeX
        attachBibTeX(to: composer, publication: publication)

        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        // No updates needed
    }

    // MARK: - Email Body

    private func buildEmailBody(for publication: PublicationModel) -> String {
        var lines: [String] = []

        // Title
        lines.append(publication.title)
        lines.append("")

        // Authors
        let authors = publication.authors.map { $0.displayName }.joined(separator: ", ")
        if !authors.isEmpty {
            lines.append("Authors: \(authors)")
        }

        // Year
        if let year = publication.year, year > 0 {
            lines.append("Year: \(year)")
        }

        // Venue
        if let journal = publication.journal, !journal.isEmpty {
            lines.append("Journal: \(journal)")
        } else if let booktitle = publication.booktitle, !booktitle.isEmpty {
            lines.append("Conference: \(booktitle)")
        }

        // DOI link
        if let doi = publication.doi {
            let doiURL = doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            lines.append("")
            lines.append("DOI: \(doiURL)")
        }

        // arXiv link
        if let arxivID = publication.arxivID {
            lines.append("arXiv: https://arxiv.org/abs/\(arxivID)")
        }

        // ADS link
        if let bibcode = publication.bibcode {
            lines.append("ADS: https://ui.adsabs.harvard.edu/abs/\(bibcode)")
        }

        // Abstract
        if let abstract = publication.abstract, !abstract.isEmpty {
            lines.append("")
            lines.append("Abstract:")
            lines.append(abstract)
        }

        // Footer
        lines.append("")
        lines.append("---")
        lines.append("Shared from imbib")

        return lines.joined(separator: "\n")
    }

    // MARK: - Attachments

    private func attachPDF(to composer: MFMailComposeViewController, publication: PublicationModel) {
        // Get the first linked PDF file that resolves to an on-disk URL.
        guard let libraryID = publication.libraryIDs.first else { return }

        for pdfFile in publication.linkedFiles where pdfFile.isPDF {
            guard let pdfURL = resolveFileURL(pdfFile, libraryID: libraryID),
                  let pdfData = try? Data(contentsOf: pdfURL) else {
                continue
            }
            composer.addAttachmentData(pdfData, mimeType: "application/pdf", fileName: pdfFile.filename)
            return
        }
    }

    /// Resolve a linked file to an on-disk URL using the value-type store's
    /// UUID-keyed container path (mirrors IOSInfoTab.resolveFileURL), with a
    /// fallback to the legacy pre-v1.3.0 `imbib/` app-support location.
    private func resolveFileURL(_ file: LinkedFileModel, libraryID: UUID) -> URL? {
        guard let path = file.relativePath else { return nil }
        let normalizedPath = path.precomposedStringWithCanonicalMapping
        let fileManager = FileManager.default

        let containerURL = AttachmentManager.shared.containerURL(for: libraryID)
            .appendingPathComponent(normalizedPath)
        if fileManager.fileExists(atPath: containerURL.path) { return containerURL }

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("imbib") {
            let legacyURL = appSupport.appendingPathComponent(normalizedPath)
            if fileManager.fileExists(atPath: legacyURL.path) { return legacyURL }
        }
        return nil
    }

    @MainActor
    private func attachBibTeX(to composer: MFMailComposeViewController, publication: PublicationModel) {
        // Prefer the stored raw BibTeX; otherwise export a fresh entry from the store.
        let bibtex: String
        if let rawBibTeX = publication.rawBibTeX, !rawBibTeX.isEmpty {
            bibtex = rawBibTeX
        } else {
            bibtex = RustStoreAdapter.shared.exportBibTeX(ids: [publication.id])
        }

        guard !bibtex.isEmpty, let bibtexData = bibtex.data(using: .utf8) else {
            return
        }

        let filename = "\(publication.citeKey).bib"
        composer.addAttachmentData(bibtexData, mimeType: "application/x-bibtex", fileName: filename)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true) {
                self.onDismiss()
            }
        }
    }
}

// MARK: - Mail Composer View Modifier

extension View {
    /// Presents a mail composer sheet for sharing a publication by id.
    func mailComposer(
        isPresented: Binding<Bool>,
        publicationID: UUID?
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            if let publicationID, IOSMailComposer.canSendEmail {
                IOSMailComposer(publicationID: publicationID) {
                    isPresented.wrappedValue = false
                }
                .ignoresSafeArea()
            } else {
                // Fallback when mail is not configured
                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)

                    Text("Mail Not Configured")
                        .font(.headline)

                    Text("Please configure a mail account in Settings to share papers by email.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button("OK") {
                        isPresented.wrappedValue = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }
}
