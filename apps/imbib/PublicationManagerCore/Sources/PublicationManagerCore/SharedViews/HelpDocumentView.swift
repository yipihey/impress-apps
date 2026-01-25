//
//  HelpDocumentView.swift
//  PublicationManagerCore
//
//  View for rendering help document markdown content.
//

import SwiftUI
import MarkdownUI

/// View for rendering a help document's markdown content.
public struct HelpDocumentView: View {

    // MARK: - Properties

    /// The document being displayed.
    public let document: HelpDocument

    /// The markdown content to render.
    public let content: String

    // MARK: - Initialization

    public init(document: HelpDocument, content: String) {
        self.document = document
        self.content = content
    }

    // MARK: - Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Document header
                header

                Divider()

                // Markdown content
                Markdown(content)
                    .markdownTheme(.helpDocument)
                    .textSelection(.enabled)

                Spacer(minLength: 40)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(documentBackground)
        .accessibilityIdentifier(AccessibilityID.Help.documentContent(document.id))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Category badge
            HStack {
                Image(systemName: document.category.iconName)
                    .font(.caption)
                Text(document.category.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.secondary)

            // Title
            Text(document.title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .accessibilityIdentifier(AccessibilityID.Help.documentTitle)

            // Summary
            if !document.summary.isEmpty {
                Text(document.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Styling

    private var documentBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(Color(nsColor: .textBackgroundColor))
        #else
        return AnyShapeStyle(Color(.systemBackground))
        #endif
    }
}

// MARK: - Help Document Theme

public extension Theme {
    /// A theme optimized for help documentation.
    ///
    /// Similar to GitHub theme but with adjusted sizing for help content.
    static var helpDocument: Theme {
        Theme.gitHub
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.75))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: 20, bottom: 12)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.4))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: 16, bottom: 8)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.2))
                    }
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(codeBackground)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                        }
                        .padding(12)
                }
                .background(codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 8, bottom: 8)
            }
    }

    private static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    private static var codeBlockBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}

// MARK: - Preview

#Preview {
    HelpDocumentView(
        document: HelpDocument(
            id: "getting-started",
            title: "Getting Started",
            category: .gettingStarted,
            filename: "getting-started.md",
            keywords: ["setup", "install"],
            summary: "Learn how to set up imbib and import your first papers."
        ),
        content: """
        # Getting Started with imbib

        Welcome to **imbib**, a scientific publication manager for macOS and iOS.

        ## Installation

        Download the latest release from GitHub and drag the app to your Applications folder.

        ## Creating Your First Library

        On first launch, imbib will create a default library for you. You can:

        1. **Import existing BibTeX** - Use File > Import to add your existing papers
        2. **Search online sources** - Use the Search tab to find papers on arXiv, ADS, and more
        3. **Drag and drop PDFs** - Simply drag PDF files into the app to import them

        ## Key Features

        - **Multi-source search** - Search arXiv, ADS, Crossref, PubMed, and more
        - **Smart collections** - Organize papers with saved searches
        - **CloudKit sync** - Keep your library in sync across devices
        - **BibTeX compatible** - Import and export standard BibTeX files

        ```swift
        // Example code block
        let library = Library()
        library.import(from: url)
        ```

        For more details, see the [Features](/features) documentation.
        """
    )
}
