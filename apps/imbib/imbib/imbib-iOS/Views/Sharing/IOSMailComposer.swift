//
//  IOSMailComposer.swift
//  imbib-iOS
//
//  Created by Claude on 2026-01-18.
//

import SwiftUI
import MessageUI
import PublicationManagerCore

/// A SwiftUI wrapper for MFMailComposeViewController that allows sharing papers
/// with PDF and BibTeX attachments.
struct IOSMailComposer: UIViewControllerRepresentable {

    // MARK: - Properties

    /// The publication to share
    let publication: CDPublication

    /// Closure called when the mail composer is dismissed
    let onDismiss: () -> Void

    // MARK: - Static Check

    /// Check if the device can send email
    static var canSendEmail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    // MARK: - UIViewControllerRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator

        // Set subject
        let title = publication.title ?? "Untitled"
        composer.setSubject("Paper: \(title)")

        // Build email body
        var body = buildEmailBody()
        composer.setMessageBody(body, isHTML: false)

        // Attach PDF if available
        attachPDF(to: composer)

        // Attach BibTeX
        attachBibTeX(to: composer)

        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        // No updates needed
    }

    // MARK: - Email Body

    private func buildEmailBody() -> String {
        var lines: [String] = []

        // Title
        if let title = publication.title {
            lines.append(title)
            lines.append("")
        }

        // Authors
        let authors = publication.sortedAuthors.map { $0.displayName }.joined(separator: ", ")
        if !authors.isEmpty {
            lines.append("Authors: \(authors)")
        }

        // Year
        if publication.year > 0 {
            lines.append("Year: \(publication.year)")
        }

        // Venue
        let fields = publication.fields
        if let journal = fields["journal"], !journal.isEmpty {
            lines.append("Journal: \(journal)")
        } else if let booktitle = fields["booktitle"], !booktitle.isEmpty {
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

    private func attachPDF(to composer: MFMailComposeViewController) {
        // Get the first linked PDF file
        guard let linkedFiles = publication.linkedFiles,
              let pdfFile = linkedFiles.first(where: { $0.fileExtension == "pdf" }) else {
            return
        }

        let filename = pdfFile.filename

        // Construct the PDF path
        guard let library = publication.libraries?.first,
              let folderURL = library.folderURL else {
            return
        }

        let pdfURL = folderURL.appendingPathComponent("Papers").appendingPathComponent(filename)

        // Read and attach
        guard let pdfData = try? Data(contentsOf: pdfURL) else {
            return
        }

        let attachmentName = pdfFile.effectiveDisplayName
        composer.addAttachmentData(pdfData, mimeType: "application/pdf", fileName: attachmentName)
    }

    private func attachBibTeX(to composer: MFMailComposeViewController) {
        // Generate BibTeX
        let bibtex: String
        if let rawBibTeX = publication.rawBibTeX, !rawBibTeX.isEmpty {
            bibtex = rawBibTeX
        } else {
            // Generate BibTeX entry from LocalPaper wrapper
            if let libraryID = publication.libraries?.first?.id,
               let paper = LocalPaper(publication: publication, libraryID: libraryID) {
                let entry = BibTeXExporter.generateEntry(from: paper)
                bibtex = BibTeXExporter().export(entry)
            } else {
                // Fallback: construct minimal BibTeX manually
                let title = publication.title ?? "Untitled"
                let authors = publication.sortedAuthors.map { $0.bibtexName }.joined(separator: " and ")
                let year = publication.year > 0 ? String(publication.year) : ""
                bibtex = """
                @article{\(publication.citeKey),
                    title = {\(title)},
                    author = {\(authors)},
                    year = {\(year)}
                }
                """
            }
        }

        guard let bibtexData = bibtex.data(using: .utf8) else {
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
    /// Presents a mail composer sheet for sharing a publication.
    func mailComposer(
        isPresented: Binding<Bool>,
        publication: CDPublication?
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            if let publication = publication, IOSMailComposer.canSendEmail {
                IOSMailComposer(publication: publication) {
                    isPresented.wrappedValue = false
                }
                .ignoresSafeArea()
            } else {
                // Fallback when mail is not configured
                VStack(spacing: 16) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("Mail Not Configured")
                        .font(.headline)

                    Text("Please configure a mail account in Settings to share papers by email.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)

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
