//
//  PublicationPDFAvailability.swift
//  PublicationManagerCore
//
//  Stage 5b (SPLIT rule) — "where is this paper's PDF, if anywhere", as data.
//
//  ## What was duplicated, and what it cost
//
//  `AttachmentManager.resolveURL(for:in:)` has been cross-platform all along
//  and knows FOUR candidate locations for a linked file (library container,
//  the alternate sandbox path, the pre-v1.3.0 legacy path, and a
//  DefaultLibrary path when no library is known). iOS did not call it. Instead
//  `IOSPDFTab.pdfFileExists` and `IOSInfoTab.resolveFileURL` each hand-rolled
//  TWO of those four candidates — the same twelve lines, twice, in one target,
//  resolving fewer files than the shared resolver they were reimplementing.
//
//  The subtlety that made the copies look necessary: `resolveURL` returns its
//  primary candidate even when nothing exists on disk (macOS callers use it to
//  reveal the enclosing folder in Finder). So "does the file exist" needs one
//  more step, and that step is what belongs in shared code — not a second
//  resolver.
//
//  ## The state machine
//
//  iOS modelled the PDF tab's state as an explicit enum; macOS modelled it as
//  five parallel `@State` booleans (`linkedFile` / `isCheckingPDF` /
//  `isDownloading` / `downloadError` / `hasRemotePDF`) and never verified that
//  the linked file exists on disk, nor had a cloud-only state at all. The two
//  state machines are genuinely different (see the matrix: PDF stays two
//  designs), so this file declares the CLASSIFICATION both can agree on and
//  iOS adopts it. macOS's `resetAndCheckPDF` is deliberately untouched: it
//  carries the fragile pane's auto-download policy, its E-Ink/Handoff
//  lifecycle and its logging contract.
//

import Foundation

// MARK: - File location

extension AttachmentManager {

    /// The linked file's on-disk URL, or `nil` when it exists nowhere.
    ///
    /// The existence-checked companion to `resolveURL(for:in:)`, which answers
    /// with a candidate path even on a miss.
    public func existingURL(for linkedFile: LinkedFileModel, in libraryID: UUID?) -> URL? {
        guard let url = resolveURL(for: linkedFile, in: libraryID) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the linked file is materialised on this device.
    public func fileExists(for linkedFile: LinkedFileModel, in libraryID: UUID?) -> Bool {
        existingURL(for: linkedFile, in: libraryID) != nil
    }
}

// MARK: - Availability

/// Where a publication's primary PDF is, as one value.
public enum PublicationPDFAvailability: Equatable, Sendable {

    /// A PDF record exists and the bytes are on this device.
    case localFile(LinkedFileModel)

    /// A PDF record exists, iCloud has it, this device has not materialised it.
    case cloudOnly(LinkedFileModel)

    /// A PDF record exists but the bytes are gone.
    case fileMissing(LinkedFileModel)

    /// No PDF record, but an identifier we can fetch one with.
    case remoteAvailable

    /// Nothing to show and nothing to fetch.
    case unavailable

    /// The linked file this state is about, if any.
    public var linkedFile: LinkedFileModel? {
        switch self {
        case .localFile(let file), .cloudOnly(let file), .fileMissing(let file):
            return file
        case .remoteAvailable, .unavailable:
            return nil
        }
    }
}

extension PublicationPDFAvailability {

    /// Classify a publication's PDF situation.
    ///
    /// `fileExists` is injected so the classification is testable without a
    /// filesystem; `resolve(publication:libraryID:)` supplies
    /// `AttachmentManager`'s answer.
    public static func resolve(
        publication: PublicationModel?,
        libraryID: UUID?,
        fileExists: (LinkedFileModel, UUID?) -> Bool
    ) -> PublicationPDFAvailability {
        guard let publication else { return .unavailable }

        if let primary = publication.linkedFiles.first(where: \.isPDF) {
            if fileExists(primary, libraryID) {
                return .localFile(primary)
            }
            if primary.pdfCloudAvailable && !primary.isLocallyMaterialized {
                return .cloudOnly(primary)
            }
            return .fileMissing(primary)
        }

        return hasFetchableIdentifier(publication) ? .remoteAvailable : .unavailable
    }

    /// `resolve` against the real filesystem via `AttachmentManager`.
    @MainActor
    public static func resolve(
        publication: PublicationModel?, libraryID: UUID?
    ) -> PublicationPDFAvailability {
        resolve(publication: publication, libraryID: libraryID) { file, library in
            AttachmentManager.shared.fileExists(for: file, in: library)
        }
    }

    /// Whether some identifier could yield a PDF.
    ///
    /// The union of what the two tabs tested: macOS also accepted a bare
    /// `eprint` field (an arXiv id that never made it into `arxivID`), iOS did
    /// not — so a paper imported with only `eprint` offered no download on
    /// iPhone.
    public static func hasFetchableIdentifier(_ publication: PublicationModel) -> Bool {
        publication.arxivID != nil
            || publication.doi != nil
            || publication.bibcode != nil
            || publication.fields["eprint"] != nil
    }
}
