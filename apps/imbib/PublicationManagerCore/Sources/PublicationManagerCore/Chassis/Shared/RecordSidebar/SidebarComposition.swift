// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). Data only: no SwiftUI,
// no store, no platform gate. The renderers (`RecordSidebarView` on iOS,
// `ImbibSidebarViewModel` on macOS) consume it; nothing here consumes them.
//
//  SidebarComposition.swift
//  PublicationManagerCore
//
//  impress's sidebar, as the COMPOSITION of the other five.
//
//  ── The report this exists to answer ────────────────────────────────────────
//
//  "It's quite hit and miss with impress. Libraries and collections and the
//   Inbox is for imbib. Imprint has its own collections for manuscripts.
//   Impart has its own for messages and all have flagged pubs, manuscripts or
//   messages. So it is ok for us to collate each of their sidebars into
//   collapsible sections of the impress sidebar rather than attempt this flat
//   but incomplete collection impress surfaces now."
//
//  The flat `AppShellConfiguration.impress` preset is a UNION of sections. A
//  union loses the one fact the sidebar most needs to carry: WHOSE section this
//  is. Flagged is the sharpest case — a union has exactly one `.flagged` entry
//  and `sectionBindings` can name exactly one kind for it, so flat impress
//  showed flagged PUBLICATIONS and silently dropped flagged manuscripts.
//  "Hit and miss" is precisely what a lossy union looks like from the outside.
//
//  ── Why this is a composition and not a hand-written truth table ────────────
//
//  Each app's `AppShellConfiguration` preset ALREADY IS its sidebar definition.
//  `.imbib` says Inbox + Libraries + … + `.flagged: .publication`; `.imprint`
//  says Manuscripts + … + `.flagged: .manuscript`. Those are not summaries of
//  the apps' sidebars — they are the values `RecordSidebarBuilder` is fed to
//  BUILD those sidebars, in the shipping apps, today.
//
//  So impress's sidebar is those five values in a list. Nothing below enumerates
//  a section, names a record kind, or decides what Flagged means in a group:
//  every one of those answers is read out of the group's own preset by the same
//  builder that has been serving imbib and imprint all along. A section added to
//  `.imprint` appears in impress's imprint group with no edit here, which is the
//  property a hand-authored per-kind list cannot have.
//
//  ── What is deliberately NOT here ──────────────────────────────────────────
//
//  * No impress-only sections. The composition is exactly the five presets; the
//    gear stays a toolbar item, global to the window, because it is chrome
//    rather than a place records live.
//  * No de-duplication. `.citedInManuscripts` is declared by BOTH `.imbib` and
//    `.imprint`, so it renders in both groups, and `.dismissed` renders in both
//    bound to different kinds. That is not a defect to fix: the user asked for
//    each app's sidebar VERBATIM, and an imbib user looking for Cited in
//    Manuscripts should find it under imbib.
//  * No group-level record kind. A group is a preset with a name and a glyph;
//    every kind question is the preset's to answer.
//

import Foundation
import ImpressKit

// MARK: - Group

/// One app's whole sidebar, as a named, collapsible unit of a composed one.
///
/// `configuration` is the app's SHIPPING preset, unmodified — passing anything
/// else would make this a second definition of that app's sidebar, which is the
/// drift ADR-0021 exists to prevent.
public struct SidebarAppGroup: Identifiable, Sendable, Equatable {

    /// Stable identity, and the namespace for this group's persisted expansion
    /// state and accessibility identifiers. Always the app's `appID`, which is
    /// also `SiblingApp.rawValue` — the two agree by construction in `init`.
    public let id: String

    /// The header's label. From `SiblingApp.descriptors`, the one table.
    public let title: String

    /// The header's glyph. Likewise from the table (`SiblingAppDescriptor
    /// .systemImage`), so a seventh app is a row there and not an edit here.
    public let systemImage: String

    /// The app's preset — the whole reason this type is three fields and not a
    /// section list.
    public let configuration: AppShellConfiguration

    /// Build a group from an app and its preset.
    ///
    /// - Precondition (asserted, not trapped): `configuration.appID` should be
    ///   `app.rawValue`. A group whose preset belongs to another app would
    ///   silently mis-title itself AND mis-key its persisted expansion state.
    public init(app: SiblingApp, configuration: AppShellConfiguration) {
        assert(
            configuration.appID == app.rawValue,
            "SidebarAppGroup(\(app.rawValue)) was handed \(configuration.appID)'s preset")
        self.id = app.rawValue
        self.title = app.displayName
        self.systemImage = app.systemImage
        self.configuration = configuration
    }

    /// Escape hatch for tests and for a host that composes a shell with no
    /// `SiblingApp` row of its own.
    public init(id: String, title: String, systemImage: String,
                configuration: AppShellConfiguration) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.configuration = configuration
    }

    /// This group's preset as the HOST can actually render it.
    ///
    /// The presets carry `presentableKinds == nil` ("this shell knows every kind
    /// it registers"), because they describe their own apps, where that is true.
    /// A composed host is a different build with a different set of panes —
    /// impress-iOS has no artifact surface — so the host's capability is
    /// intersected in here, once, rather than at five call sites.
    ///
    /// `nil` host kinds means "no narrowing", which is macOS impress: it embeds
    /// every viewer, so every group renders its preset unchanged.
    public func configuration(inHost host: AppShellConfiguration) -> AppShellConfiguration {
        guard let kinds = host.presentableKinds else { return configuration }
        return configuration.presenting(kinds)
    }
}

// MARK: - Composition

/// An ordered list of app groups — a sidebar that is other sidebars.
///
/// A shell either runs a single `AppShellConfiguration` (the five siblings) or a
/// `SidebarComposition` (impress). The two are not mixed: a composed sidebar has
/// no flat top level, because "which app is this row's" is exactly the fact the
/// flat version lost.
public struct SidebarComposition: Sendable, Equatable {

    public let groups: [SidebarAppGroup]

    public init(groups: [SidebarAppGroup]) {
        self.groups = groups
    }

    public subscript(id: String) -> SidebarAppGroup? {
        groups.first { $0.id == id }
    }

    /// The apps a composition covers, in order.
    public var appIDs: [String] { groups.map(\.id) }

    // MARK: The impress composition

    /// The five sibling presets, in the order `SiblingApp.descriptors` declares
    /// them — imbib, imprint, implore, impel, impart.
    ///
    /// The ORDER is a lookup, not a literal, for the same reason the titles and
    /// glyphs are: the suite table is where "which apps, in what order" is
    /// already decided, and a second ordering here would be a second answer.
    /// `impress` itself is filtered out — it owns no domain, so it has no
    /// sidebar of its own to contribute; it IS the window these five are in.
    ///
    /// The mapping from app to preset is the one `switch` in this file and it is
    /// unavoidable: `AppShellConfiguration`'s presets are static members, so
    /// something has to name them. It is exhaustive over `SiblingApp`, so adding
    /// a seventh app fails to compile here until someone decides whether it has
    /// a sidebar — which is the good version of the case-addition tax.
    public static let impress = SidebarComposition(
        groups: SiblingApp.descriptors.compactMap { row in
            preset(for: row.id).map { SidebarAppGroup(app: row.id, configuration: $0) }
        })

    /// The shipping preset for an app, or nil for an app that contributes no
    /// sidebar to a composition.
    static func preset(for app: SiblingApp) -> AppShellConfiguration? {
        switch app {
        case .imbib: return .imbib
        case .imprint: return .imprint
        case .implore: return .implore
        case .impel: return .impel
        case .impart: return .impart
        // The composed shell itself. Its flat preset is retained (parity tests
        // pin it, and macOS reads it for `visibleSections`/`recordKinds`), but
        // it is not a GROUP: a group of everything inside a sidebar of the same
        // everything is the flat sidebar the user reported.
        case .impress: return nil
        }
    }
}

// MARK: - Persisted expansion keys

/// The key space for a composed sidebar's expansion state.
///
/// A composed sidebar has TWO collapsible levels and the section level is no
/// longer uniquely named by its `SidebarSectionType`: `.flagged` appears in the
/// imbib group AND the imprint group, and collapsing one must not collapse the
/// other. So the persisted set is keyed by strings that carry the group.
///
/// `RawRepresentable<String>` so it drops straight into ImpressSidebar's generic
/// `SidebarCollapsedStateStore` — the same actor, the same UserDefaults shape
/// and the same `loadSync()` seam the flat sidebar has used since before
/// ADR-0021. A second persistence mechanism for a second level of the same
/// widget would be the drift, not the reuse.
public struct SidebarCompositionKey: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A whole app group.
    public static func group(_ groupID: String) -> SidebarCompositionKey {
        SidebarCompositionKey(rawValue: "group:\(groupID)")
    }

    /// One section WITHIN an app group.
    public static func section(
        _ groupID: String, _ section: SidebarSectionType
    ) -> SidebarCompositionKey {
        SidebarCompositionKey(rawValue: "section:\(groupID):\(section.rawValue)")
    }
}

/// Persists which groups and which per-group sections are collapsed.
///
/// Separate UserDefaults key from `sidebarCollapsedSections`: that one holds
/// `SidebarSectionType` values for the FLAT sidebar the five sibling apps run,
/// and the two key spaces are not interchangeable. Sharing the key would have
/// let an impress collapse land in imbib's sidebar (both read the same
/// `UserDefaults.standard` in the shared suite container).
///
/// Default is EMPTY, i.e. everything expanded. "Collate their sidebars" means a
/// user opening impress sees the five sidebars, not five closed drawers; the
/// collapsing is the affordance for making it manageable afterwards.
public final class SidebarCompositionCollapsedStore: Sendable {

    public static let shared = SidebarCompositionCollapsedStore()

    private let store: ImpressSidebar.SidebarCollapsedStateStore<SidebarCompositionKey>

    private init() {
        self.store = ImpressSidebar.SidebarCollapsedStateStore<SidebarCompositionKey>(
            key: "sidebarCompositionCollapsed")
    }

    public func save(_ collapsed: Set<SidebarCompositionKey>) async {
        await store.save(collapsed)
    }

    public func loadCollapsedSync() -> Set<SidebarCompositionKey> {
        store.loadSync()
    }

    /// Static convenience for SwiftUI `@State` initialisation — the shape
    /// `RecordSidebarView` already uses for the flat store.
    public static func loadCollapsedSync() -> Set<SidebarCompositionKey> {
        shared.loadCollapsedSync()
    }
}
