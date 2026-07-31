#if os(macOS)
// Chassis file — macOS-only (the outline sidebar is macOS; iOS renders the
// same `SidebarComposition` through `RecordSidebarView`).
//
//  SidebarNodeGroup.swift
//  PublicationManagerCore
//
//  What a macOS sidebar node knows about WHICH APP'S sidebar it is in.
//
//  ── Why a node has to carry this at all ─────────────────────────────────────
//
//  On iOS the composed sidebar is built in one pass: `RecordSidebarBuilder
//  .groups` runs each group's preset through the builder and every row comes
//  out carrying a `RecordSidebarScope`, which names its record kind. The macOS
//  sidebar is an `NSOutlineView`, so it is built LAZILY — `children(of:)` is
//  called long after the group loop has returned, with nothing but the node.
//
//  So the group travels ON the node. That single fact answers the four
//  questions the composed macOS tree asks that the flat one never did:
//
//    1. WHICH PRESET decides this section's record kind, its availability and
//       its rows (`configuration`) — the window's shell preset is `.impress`,
//       the flat union, and reading it inside a group would reintroduce exactly
//       the loss the composition exists to undo.
//    2. WHICH KEY persists this row's collapse state
//       (`SidebarCompositionKey.section(id, …)`).
//    3. WHICH NAMESPACE its node id lives in — `.flagColor(.red)` occurs in the
//       imbib group AND the imprint group, and `ImbibSidebarNodeID.flagColor`
//       is deterministic, so ungrouped ids would COLLIDE inside
//       `SidebarOutlineView`'s UUID-keyed caches (two rows, one wrapper).
//    4. WHETHER a drag may land here — a section may reorder within its own
//       group and nowhere else.
//

import Foundation
import ImpressKit

/// One app group's identity and preset, as carried by every node beneath it.
///
/// A value, not a reference to the composition, so a node stays self-describing
/// after the tree that built it is gone — which is the state `children(of:)`,
/// `canAcceptDrop` and the context-menu builders are all called in.
struct SidebarNodeGroup: Equatable {

    /// The app id — `SiblingApp.rawValue`, and the namespace for ids and keys.
    let id: String

    /// Header label, from `SiblingApp.descriptors`.
    let title: String

    /// Header glyph, from the same table.
    let systemImage: String

    /// The app's SHIPPING preset, already intersected with the host's
    /// `presentableKinds` (`SidebarAppGroup.configuration(inHost:)`). Every
    /// kind/section question inside this group is this value's to answer.
    let configuration: AppShellConfiguration

    init(group: SidebarAppGroup, host: AppShellConfiguration) {
        self.id = group.id
        self.title = group.title
        self.systemImage = group.systemImage
        self.configuration = group.configuration(inHost: host)
    }

    /// The persisted collapse key for this group's header.
    var collapseKey: SidebarCompositionKey { .group(id) }

    /// The persisted collapse key for one of this group's section headers.
    func collapseKey(section: SidebarSectionType) -> SidebarCompositionKey {
        .section(id, section)
    }

    // MARK: - Cross-kind routing

    /// The tab a node should route to when its section's record kind is decided
    /// by the PRESET rather than by the node type — i.e. the two cross-kind
    /// sections, Flagged and Dismissed. Returns nil for every other node type,
    /// which then keeps the tab its own case already names.
    ///
    /// This is the whole of the user's report, in code. `SectionContentView`
    /// resolves a bare `.flagged(color)` tab by asking the WINDOW's shell
    /// configuration which kind Flagged means; in impress that is the flat
    /// union, which says `.publication`, so an imprint-group flag row would
    /// list papers. Retargeting here — to the tab that already carries its kind
    /// (`.record(.flagged(kind, colour))`) — makes the row say what it means
    /// and leaves `SectionContentView` completely unmodified.
    ///
    /// `.publication` deliberately falls through to nil: the imbib group then
    /// produces the identical `.flagged(colour)` / `.dismissed` tabs flat imbib
    /// produces, so the group a user already knows behaves exactly as before.
    func retargetedTab(for nodeType: ImbibSidebarNodeType) -> ImbibTab? {
        switch nodeType {
        case .anyFlag:
            return flaggedTab(colorRaw: nil)
        case .flagColor(let color):
            return flaggedTab(colorRaw: color.rawValue)
        case .dismissed:
            guard let kind = configuration.recordKind(for: .dismissed), kind != .publication,
                  let dismissed = BuiltinRecordKinds.registry[kind]?.triage.dismissedStatus
            else { return nil }
            return .record(.status(kind, dismissed))
        default:
            return nil
        }
    }

    private func flaggedTab(colorRaw: String?) -> ImbibTab? {
        guard let kind = configuration.recordKind(for: .flagged), kind != .publication
        else { return nil }
        return .record(.flagged(kind, colorRaw))
    }
}
#endif
