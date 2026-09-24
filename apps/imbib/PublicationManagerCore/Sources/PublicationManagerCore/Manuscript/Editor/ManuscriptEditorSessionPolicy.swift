// CONTRACT file — CROSS-PLATFORM (macOS + iOS).
//
//  ManuscriptEditorSessionPolicy.swift
//  PublicationManagerCore
//
//  Which manuscripts may take a live editor session (ADR-0023 D4/W3).
//
//  A manuscript whose payload carries `external_source` indexes a FILE the
//  user owns and edits elsewhere; its `body_content` is a snapshot. An editor
//  session over it would have a debounced save, and a save landing late
//  would write the store's older copy over somebody's working file. So such
//  a manuscript never gets a session — the gate is at CREATION, not at save,
//  because a session that is never made has nothing to fire.
//
//  The predicate lived in imprint (`WatchedManuscriptGuard`), where the
//  chassis could not reach it: the layout tree's `source` pane is chassis
//  code and must apply the same rule. It lives here now, and imprint's guard
//  calls it.

import Foundation

public enum ManuscriptEditorSessionPolicy {

    /// The payload key whose presence makes the file authoritative.
    public static let externalSourceKey = "external_source"

    /// True when the file — not the store — is authoritative for this body:
    /// the payload's `external_source` is present and not null. The single
    /// predicate every no-write-back gate reads.
    public static func isExternalReference(externalSource: Any?) -> Bool {
        guard let value = externalSource else { return false }
        return !(value is NSNull)
    }

    /// Whether a manuscript with this `external_source` value may take a live
    /// editor session.
    public static func allowsEditorSession(externalSource: Any?) -> Bool {
        !isExternalReference(externalSource: externalSource)
    }

    /// The same question for a decoded payload.
    public static func allowsEditorSession(payload: [String: Any]) -> Bool {
        allowsEditorSession(externalSource: payload[externalSourceKey])
    }
}
