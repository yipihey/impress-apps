//
//  EInkMirrorState.swift
//  PublicationManagerCore
//
//  The list-row marker for imbib's reMarkable USB mirror (ADR-025). The raw
//  values are the Rust `MirrorState` spellings that `BibliographyRow.eink_state`
//  carries (`crates/imbib-core/src/eink/`); Rust sets that field ONLY while a
//  device in `individual` mode is configured, and never to `superseded` or
//  `unmarked` — those two are bookkeeping states with no marker, which is why
//  they are not cases here and `nil` is the "no marker" value everywhere.
//
//  Everything presentational about a state (label, glyph, tint, the verb the
//  context menu shows) lives here, once, so the row marker, the PDF-tab chip,
//  the Info-tab section and the Settings counters cannot drift apart.
//

import Foundation
import ImpressMailStyle
import SwiftUI

public enum EInkMirrorState: String, Sendable, Hashable, CaseIterable {
    /// Marked; waiting for the next sync to upload.
    case queued
    /// Marked, but no local PDF/ePUB exists yet — only the running app can fetch one.
    case awaitingSource = "awaiting_source"
    /// Marked and sendable, but the tablet lacks the target folder (see the checklist).
    case awaitingFolder = "awaiting_folder"
    /// A copy is on the tablet.
    case uploaded
    /// The local source changed after the upload; "Update on tablet" re-sends.
    case stale
    /// The tablet no longer has the copy; "send again" re-uploads.
    case removedOnDevice = "removed_on_device"
    /// The last upload attempt failed (`lastError` on the mirror row says why).
    case failed

    /// The context-menu verb for a row that is NOT marked.
    public static let mirrorVerb = "Mirror to reMarkable"

    /// Short noun phrase for badges, chips and counters.
    public var label: String {
        switch self {
        case .queued: return "Queued for reMarkable"
        case .awaitingSource: return "Awaiting PDF"
        case .awaitingFolder: return "Awaiting folder on reMarkable"
        case .uploaded: return "On reMarkable"
        case .stale: return "Changed since upload"
        case .removedOnDevice: return "Removed on reMarkable"
        case .failed: return "Upload to reMarkable failed"
        }
    }

    /// One sentence for tooltips and the detail section.
    public var explanation: String {
        switch self {
        case .queued: return "Will be sent the next time the tablet is connected."
        case .awaitingSource: return "No PDF or ePUB is on this Mac yet; it is sent once one arrives."
        case .awaitingFolder: return "The tablet is missing a folder this paper belongs in; create it from the checklist in Settings."
        case .uploaded: return "A copy is on the tablet."
        case .stale: return "The PDF changed after it was sent; update the copy on the tablet."
        case .removedOnDevice: return "The copy was deleted on the tablet; send it again if you want it back."
        case .failed: return "The last upload failed; see the error in the paper's Info tab."
        }
    }

    /// SF Symbol for the row marker and chips (all verified to exist).
    public var systemImage: String {
        switch self {
        case .queued: return "arrow.up.circle"
        case .awaitingSource: return "arrow.down.doc"
        case .awaitingFolder: return "folder.badge.questionmark"
        case .uploaded: return "rectangle.portrait.fill"
        case .stale: return "arrow.triangle.2.circlepath"
        case .removedOnDevice: return "rectangle.portrait.slash"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// Named tint from the shared mail-style palette.
    public var tint: MailStyleLeadingMarker.Tint {
        switch self {
        case .queued: return .secondary
        case .awaitingSource: return .orange
        case .awaitingFolder: return .orange
        case .uploaded: return .green
        case .stale: return .yellow
        case .removedOnDevice: return .secondary
        case .failed: return .red
        }
    }

    public var color: Color { tint.color }

    /// The context-menu verb for a row in this state. Rows with a copy on the
    /// tablet remove it; rows that never got that far just stop being mirrored.
    public var menuVerb: String {
        switch self {
        case .uploaded, .stale: return "Remove from reMarkable"
        case .queued, .awaitingSource, .awaitingFolder, .removedOnDevice, .failed:
            return "Stop Mirroring to reMarkable"
        }
    }

    /// True once a copy exists on the tablet.
    public var isOnDevice: Bool {
        switch self {
        case .uploaded, .stale: return true
        default: return false
        }
    }

    /// The row marker (`MailStyleItem.leadingMarker`).
    public var marker: MailStyleLeadingMarker {
        MailStyleLeadingMarker(systemImage: systemImage, tint: tint, accessibilityLabel: label)
    }
}
