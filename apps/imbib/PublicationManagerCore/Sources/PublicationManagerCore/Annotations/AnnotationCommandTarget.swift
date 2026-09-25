//
//  AnnotationCommandTarget.swift
//  PublicationManagerCore
//
//  Which linked file a PDF command posted through NotificationCenter is for.
//

import Foundation

/// Which linked file a PDF command (Annotate ▸ Highlight / Underline /
/// Strikethrough, Go ▸ Go to Page) acts on, for a PDF view showing
/// `displayed`.
///
/// The menu items post no file id. Until 2026-09-25 the PDF view's
/// coordinator passed the post's (absent) id straight to
/// `AnnotationService.add…WithPersistence`, which draws the markup and only
/// writes the `imbib/annotation` row — whose parent IS the linked file —
/// when it has an id. So a highlight made from the menu showed until the
/// document reloaded and was never stored, while the toolbar's button, which
/// passes the view's own id, persisted.
public enum AnnotationCommandTarget {
    /// The userInfo key a poster uses to aim a command at one document.
    public static let linkedFileIDKey = "linkedFileID"

    /// The id the post names, if any.
    public static func postedFileID(_ notification: Notification) -> UUID? {
        notification.userInfo?[linkedFileIDKey] as? UUID
    }

    /// False when the post names a different file than the one displayed —
    /// that post is for another PDF view.
    public static func applies(_ notification: Notification, displayed: UUID?) -> Bool {
        applies(posted: postedFileID(notification), displayed: displayed)
    }

    public static func applies(posted: UUID?, displayed: UUID?) -> Bool {
        guard let posted, let displayed else { return true }
        return posted == displayed
    }

    /// The file the annotation belongs to: the one the post names, else the
    /// one the view shows. `nil` only for a view with no linked file (a PDF
    /// opened from a URL or data), which has nowhere to store it.
    public static func fileID(_ notification: Notification, displayed: UUID?) -> UUID? {
        postedFileID(notification) ?? displayed
    }
}
