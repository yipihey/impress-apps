//
//  FileTypeIcon.swift
//  PublicationManagerCore
//
//  Created by Claude on 2026-01-06.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - File Type Icon

/// A view that displays an appropriate SF Symbol icon for a file type.
///
/// Determines the icon based on file extension, MIME type, or UTType.
/// Falls back to a generic document icon if the type is unknown.
public struct FileTypeIcon: View {

    // MARK: - Properties

    let fileExtension: String?
    let mimeType: String?
    let size: CGFloat

    // MARK: - Initialization

    /// Create an icon for a file extension.
    public init(extension ext: String, size: CGFloat = 20) {
        self.fileExtension = ext.lowercased()
        self.mimeType = nil
        self.size = size
    }

    /// Create an icon from a MIME type.
    public init(mimeType: String, size: CGFloat = 20) {
        self.fileExtension = nil
        self.mimeType = mimeType.lowercased()
        self.size = size
    }

    /// Create an icon for a CDLinkedFile.
    public init(linkedFile: CDLinkedFile, size: CGFloat = 20) {
        self.fileExtension = linkedFile.fileExtension
        self.mimeType = linkedFile.mimeType
        self.size = size
    }

    // MARK: - Body

    public var body: some View {
        Image(systemName: iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(iconColor)
    }

    // MARK: - Icon Resolution

    private var iconName: String {
        // Try extension first
        if let ext = fileExtension {
            if let icon = Self.extensionIcons[ext] {
                return icon
            }
        }

        // Try MIME type
        if let mime = mimeType {
            if let icon = Self.mimeIcons[mime] {
                return icon
            }
            // Check MIME categories
            if mime.hasPrefix("image/") {
                return "photo"
            }
            if mime.hasPrefix("text/") || mime.hasPrefix("application/json") {
                return "doc.text"
            }
            if mime.hasPrefix("audio/") {
                return "waveform"
            }
            if mime.hasPrefix("video/") {
                return "video"
            }
        }

        // Fallback: try UTType
        if let ext = fileExtension,
           let utType = UTType(filenameExtension: ext) {
            return iconForUTType(utType)
        }

        return "doc"
    }

    private var iconColor: Color {
        // Color by category
        if let ext = fileExtension {
            if Self.pdfExtensions.contains(ext) {
                return .red
            }
            if Self.imageExtensions.contains(ext) {
                return .purple
            }
            if Self.archiveExtensions.contains(ext) {
                return .brown
            }
            if Self.codeExtensions.contains(ext) {
                return .orange
            }
            if Self.dataExtensions.contains(ext) {
                return .green
            }
        }
        return .secondary
    }

    private func iconForUTType(_ utType: UTType) -> String {
        if utType.conforms(to: .pdf) { return "doc.fill" }
        if utType.conforms(to: .image) { return "photo" }
        if utType.conforms(to: .archive) { return "doc.zipper" }
        if utType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if utType.conforms(to: .spreadsheet) { return "tablecells" }
        if utType.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if utType.conforms(to: .plainText) { return "doc.text" }
        if utType.conforms(to: .audio) { return "waveform" }
        if utType.conforms(to: .movie) { return "video" }
        return "doc"
    }

    // MARK: - Icon Mappings

    private static let extensionIcons: [String: String] = [
        // Documents
        "pdf": "doc.fill",
        "doc": "doc.richtext",
        "docx": "doc.richtext",
        "rtf": "doc.richtext",
        "txt": "doc.text",
        "md": "doc.text",
        "markdown": "doc.text",
        "tex": "doc.text",
        "bib": "doc.text",

        // Spreadsheets
        "xls": "tablecells",
        "xlsx": "tablecells",
        "csv": "tablecells",
        "tsv": "tablecells",
        "numbers": "tablecells",

        // Presentations
        "ppt": "rectangle.on.rectangle",
        "pptx": "rectangle.on.rectangle",
        "key": "rectangle.on.rectangle",

        // Images
        "png": "photo",
        "jpg": "photo",
        "jpeg": "photo",
        "gif": "photo",
        "tiff": "photo",
        "tif": "photo",
        "bmp": "photo",
        "webp": "photo",
        "heic": "photo",
        "svg": "photo",
        "eps": "photo",
        "ai": "photo",
        "psd": "photo",

        // Archives
        "zip": "doc.zipper",
        "tar": "doc.zipper",
        "gz": "doc.zipper",
        "tgz": "doc.zipper",
        "bz2": "doc.zipper",
        "7z": "doc.zipper",
        "rar": "doc.zipper",
        "xz": "doc.zipper",

        // Code
        "py": "chevron.left.forwardslash.chevron.right",
        "swift": "chevron.left.forwardslash.chevron.right",
        "c": "chevron.left.forwardslash.chevron.right",
        "cpp": "chevron.left.forwardslash.chevron.right",
        "h": "chevron.left.forwardslash.chevron.right",
        "hpp": "chevron.left.forwardslash.chevron.right",
        "java": "chevron.left.forwardslash.chevron.right",
        "js": "chevron.left.forwardslash.chevron.right",
        "ts": "chevron.left.forwardslash.chevron.right",
        "rs": "chevron.left.forwardslash.chevron.right",
        "go": "chevron.left.forwardslash.chevron.right",
        "rb": "chevron.left.forwardslash.chevron.right",
        "php": "chevron.left.forwardslash.chevron.right",
        "r": "chevron.left.forwardslash.chevron.right",
        "m": "chevron.left.forwardslash.chevron.right",
        "f90": "chevron.left.forwardslash.chevron.right",
        "f95": "chevron.left.forwardslash.chevron.right",
        "sh": "terminal",
        "bash": "terminal",
        "zsh": "terminal",

        // Data
        "json": "curlybraces",
        "xml": "curlybraces",
        "yaml": "list.bullet.rectangle",
        "yml": "list.bullet.rectangle",
        "plist": "list.bullet.rectangle",
        "fits": "tablecells",
        "hdf5": "tablecells",
        "h5": "tablecells",
        "nc": "tablecells",
        "npy": "tablecells",
        "npz": "tablecells",
        "mat": "tablecells",
        "sav": "tablecells",
        "dat": "tablecells",

        // Scientific/LaTeX (eps already in Images)
        "ps": "photo",
        "dvi": "doc",

        // Audio
        "mp3": "waveform",
        "wav": "waveform",
        "m4a": "waveform",
        "flac": "waveform",
        "aiff": "waveform",

        // Video
        "mp4": "video",
        "mov": "video",
        "avi": "video",
        "mkv": "video",
        "webm": "video",
    ]

    private static let mimeIcons: [String: String] = [
        "application/pdf": "doc.fill",
        "application/json": "curlybraces",
        "application/xml": "curlybraces",
        "application/zip": "doc.zipper",
        "application/gzip": "doc.zipper",
        "application/x-tar": "doc.zipper",
        "application/x-bzip2": "doc.zipper",
    ]

    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic", "svg", "eps", "ai", "psd"]
    private static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz"]
    private static let codeExtensions: Set<String> = ["py", "swift", "c", "cpp", "h", "hpp", "java", "js", "ts", "rs", "go", "rb", "php", "r", "m", "f90", "f95", "sh", "bash", "zsh"]
    private static let dataExtensions: Set<String> = ["json", "xml", "yaml", "yml", "csv", "tsv", "fits", "hdf5", "h5", "nc", "npy", "npz", "mat", "sav", "dat"]
}

// MARK: - Preview

#if DEBUG
struct FileTypeIcon_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Label { Text("PDF") } icon: { FileTypeIcon(extension: "pdf") }
                Label { Text("Image") } icon: { FileTypeIcon(extension: "png") }
                Label { Text("Archive") } icon: { FileTypeIcon(extension: "tar.gz") }
                Label { Text("Code") } icon: { FileTypeIcon(extension: "py") }
                Label { Text("Data") } icon: { FileTypeIcon(extension: "json") }
                Label { Text("Spreadsheet") } icon: { FileTypeIcon(extension: "csv") }
                Label { Text("Unknown") } icon: { FileTypeIcon(extension: "xyz") }
            }
        }
        .padding()
    }
}
#endif
