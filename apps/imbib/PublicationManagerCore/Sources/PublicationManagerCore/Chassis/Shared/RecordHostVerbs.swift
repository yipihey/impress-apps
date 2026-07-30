// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): pure data over
// closures plus one SwiftUI environment key. No AppKit, no store types.
//
//  RecordHostVerbs.swift
//  PublicationManagerCore
//
//  Stage 4c (ADDITIVE seam, flagged): the two verbs a HOST APP owns that the
//  chassis cannot perform for itself, declared per record kind and injected
//  through the environment.
//
//  Why this exists at all — the alternative was worse. `RecordTriageActions`
//  already carries `onCreate`, but the action bag is BUILT INSIDE the chassis
//  (`MessageSectionView.makeActions()`), which is constructed by
//  `SectionContentView`, which is constructed by `TabContentView`. There is no
//  parameter on that chain an app can reach, so a host had exactly two ways to
//  add a create verb or observe selection:
//
//    1. register a REPLACEMENT section view in `RecordViewerRegistry` — which
//       means copying `MessageSectionView`'s pane-layout body into the app
//       target, i.e. re-introducing per-app clones of chassis layout, the exact
//       thing Stage 4b deleted;
//    2. this: one environment value the chassis consults where it already had
//       a hole.
//
//  Two verbs, and deliberately only two:
//
//  * `onCreate` — the app's answer to a kind's `CreationAffordance`. impart's
//    compose is a Core Data + SMTP flow (`ComposeView`, `DraftMessage`); the
//    chassis has no business knowing it exists, but it CAN offer the `n` key
//    and the empty-state button that call it. With this set, mail's
//    `descriptor.creation` stops being a lie.
//
//  * `onSelect` — the app's chance to react to the chassis showing a record.
//    Mail's read state is the case that forced it: `SharedItemRow.isRead` is
//    mirrored FROM impart's Core Data (`MailStoreMirror`), so the authority is
//    the app's, and a chassis-side store write would produce a read flag
//    impart's own model disagrees with and IMAP never learns about. The
//    chassis reports "the user is now looking at this row"; what read-state
//    means is the host's to decide.
//
//  NOT here, on purpose: delete/move/reply/forward. Those are row ACTIONS with
//  their own declared capability (`DeletionSemantics`, `TriageCapabilities`) or
//  no declaration at all; smuggling them through a host bag would route around
//  the descriptors instead of extending them.
//

import Foundation
import SwiftUI

/// The chassis telling a host which record it is now displaying.
///
/// `externalID` is the kind's APP-SIDE identity, which is not the store id: a
/// mail row's store id is a UUIDv5 derived from the RFC Message-ID, while
/// impart's `CDMessage.id` is a separate UUID. Carrying the RFC header (payload
/// `message_id`) is what lets the host find its own record without the chassis
/// knowing anything about Core Data.
public struct RecordSelection: Sendable, Equatable {
    /// The kind of the selected record.
    public let kind: RecordKindID
    /// The store item id (what the chassis selects with).
    public let recordID: UUID
    /// The kind's app-side identity, when the payload carries one.
    public let externalID: String?
    /// Envelope read state as the store currently holds it — so a host can skip
    /// a redundant write (and the store mutation → reload it would trigger).
    public let isRead: Bool

    public init(kind: RecordKindID, recordID: UUID, externalID: String?, isRead: Bool) {
        self.kind = kind
        self.recordID = recordID
        self.externalID = externalID
        self.isRead = isRead
    }
}

/// The host-owned verbs for ONE record kind. Both optional: absent means the
/// chassis keeps its existing behaviour (`n` is ignored, selection is inert).
public struct RecordHostVerbs: Sendable {
    public var onCreate: (@MainActor @Sendable (CreationAffordance) -> Void)?
    public var onSelect: (@MainActor @Sendable (RecordSelection) -> Void)?

    public init(
        onCreate: (@MainActor @Sendable (CreationAffordance) -> Void)? = nil,
        onSelect: (@MainActor @Sendable (RecordSelection) -> Void)? = nil
    ) {
        self.onCreate = onCreate
        self.onSelect = onSelect
    }
}

/// Per-kind host verbs, injected at the app's chassis root — the
/// `CustomSurfaceRegistry` / `RecordViewerRegistry` pattern, one notch smaller:
/// surfaces are whole panes, viewers are whole sections, these are two closures.
public struct RecordHostVerbRegistry: Sendable {

    private let byKind: [RecordKindID: RecordHostVerbs]

    public init(_ byKind: [RecordKindID: RecordHostVerbs] = [:]) {
        self.byKind = byKind
    }

    public subscript(kind: RecordKindID) -> RecordHostVerbs? { byKind[kind] }

    /// True when no host registered anything — the default every shell gets.
    public var isEmpty: Bool { byKind.isEmpty }
}

// MARK: - Environment

private struct RecordHostVerbRegistryKey: EnvironmentKey {
    static let defaultValue = RecordHostVerbRegistry()
}

public extension EnvironmentValues {
    var recordHostVerbs: RecordHostVerbRegistry {
        get { self[RecordHostVerbRegistryKey.self] }
        set { self[RecordHostVerbRegistryKey.self] = newValue }
    }
}
