//
//  ShareableUTTypes.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-29.
//

import UniformTypeIdentifiers

// MARK: - Custom UTTypes for Sharing

extension UTType {

    /// Rich imbib bundle containing publications and optionally PDFs.
    ///
    /// This is a package (directory bundle) with the structure:
    /// ```
    /// Papers.imbib/
    /// ├── manifest.json      # Metadata and version
    /// ├── publications.json  # Array of ShareablePublication
    /// ├── bibliography.bib   # Combined BibTeX
    /// └── files/
    ///     └── {citeKey}.pdf  # Embedded PDFs
    /// ```
    public static let imbibBundle = UTType(
        exportedAs: "com.imbib.bundle",
        conformingTo: .package
    )

    /// BibTeX bibliography file.
    ///
    /// Standard BibTeX format, compatible with BibDesk, Zotero, and other
    /// reference managers.
    public static let bibtex = UTType(
        exportedAs: "com.imbib.bibtex",
        conformingTo: .plainText
    )

    /// imbib publication ID for drag-and-drop within the app.
    ///
    /// This is an internal type used for dragging publications between views.
    public static let imbibPublicationID = UTType(
        exportedAs: "com.imbib.publication-id",
        conformingTo: .data
    )
}

// MARK: - UTType Helpers

extension UTType {

    /// Check if this UTType represents a BibTeX file.
    public var isBibTeX: Bool {
        // Check by extension since BibTeX doesn't have a standard UTType
        if let ext = preferredFilenameExtension?.lowercased() {
            return ext == "bib" || ext == "bibtex"
        }
        return self == .bibtex || conforms(to: .bibtex)
    }

    /// Check if this UTType represents an imbib bundle.
    public var isImbibBundle: Bool {
        if let ext = preferredFilenameExtension?.lowercased() {
            return ext == "imbib"
        }
        return self == .imbibBundle || conforms(to: .imbibBundle)
    }

    /// Check if this UTType represents a RIS file.
    public var isRIS: Bool {
        if let ext = preferredFilenameExtension?.lowercased() {
            return ext == "ris"
        }
        return false
    }

    /// Get UTType from a file extension.
    public static func from(extension ext: String) -> UTType? {
        switch ext.lowercased() {
        case "bib", "bibtex":
            return .bibtex
        case "imbib":
            return .imbibBundle
        case "ris":
            return UTType(filenameExtension: "ris")
        case "pdf":
            return .pdf
        default:
            return UTType(filenameExtension: ext)
        }
    }
}
