//
//  PDFDataValidator.swift
//  PublicationManagerCore
//
//  "Is this a whole PDF?" — asked before a PDF becomes an attachment and
//  before one is served to a sibling app.
//
//  `%PDF` magic bytes alone cannot answer it: a download cut short still
//  starts with `%PDF`. That is how a 770 KB head of a 2.2 MB APS paper was
//  imported on 2026-09-11 and then shown as "Invalid or corrupted PDF" — two
//  browser downloads of the same file shared one temp slot, and the one that
//  finished first read the other's half-written file. So the check is the
//  one that matters to imbib: PDFKit must be able to open the bytes, and a
//  download must have delivered every byte the server announced.
//

import Foundation
import PDFKit

/// What a PDF's bytes turned out to be.
public enum PDFDataCheck: Equatable, Sendable {
    /// A PDF that PDFKit opens.
    case complete
    /// Not a PDF at all (no `%PDF` header) — typically a publisher's HTML page.
    case notPDF
    /// Starts like a PDF but cannot be used; the reason says why.
    case incomplete(String)

    public var isComplete: Bool { self == .complete }

    /// A sentence for logs and error messages, or nil when complete.
    public var problem: String? {
        switch self {
        case .complete: return nil
        case .notPDF: return "the file is not a PDF (no %PDF header)"
        case .incomplete(let reason): return reason
        }
    }
}

public enum PDFDataValidator {

    /// Check PDF bytes. `expectedLength` is the server's Content-Length when
    /// known (a value ≤ 0 means unknown).
    public static func check(_ data: Data, expectedLength: Int64 = -1) -> PDFDataCheck {
        guard hasPDFHeader(data) else { return .notPDF }
        if expectedLength > 0, Int64(data.count) < expectedLength {
            return .incomplete(
                "the download stopped early (\(data.count) of \(expectedLength) bytes)")
        }
        guard PDFDocument(data: data) != nil else {
            return .incomplete(endsWithEOFMarker(data)
                ? "PDFKit cannot open it (\(data.count) bytes)"
                : "it ends before the PDF's end marker — an unfinished download (\(data.count) bytes)")
        }
        return .complete
    }

    /// Check a file on disk.
    public static func check(fileAt url: URL) -> PDFDataCheck {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .incomplete("the file cannot be read")
        }
        return check(data)
    }

    /// `%PDF` at the start.
    public static func hasPDFHeader(_ data: Data) -> Bool {
        data.starts(with: [0x25, 0x50, 0x44, 0x46])
    }

    /// `%%EOF` within the last 2 KB — where every writer puts it (a few append
    /// a line or two after it). A truncated download has none there.
    public static func endsWithEOFMarker(_ data: Data) -> Bool {
        data.suffix(2048).range(of: Data("%%EOF".utf8)) != nil
    }
}
