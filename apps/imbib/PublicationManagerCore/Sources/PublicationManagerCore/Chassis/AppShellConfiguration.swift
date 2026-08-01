// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS). The shell preset IS
// the app's declarative identity; an iOS shell that cannot read it has to
// re-encode the same truth table by hand, which is exactly the drift
// ADR-0021 exists to prevent. Imports only SwiftUI; every type it names
// (SidebarSectionType, DetailTab, RecordKindRegistry, CustomSurfaceRegistry)
// is cross-platform.
//
//  AppShellConfiguration.swift
//  PublicationManagerCore
//
//  The thin-twin mechanism (GUI-meld plan §2/§7, generalized by ADR-0021):
//  the SAME chassis (TabContentView) runs in every impress app; the app's
//  identity is which sidebar sections are visible, which RECORD KIND each
//  section binds to, and where it lands — NOT which data is accessible
//  (ADR-0001). Injected via the SwiftUI environment at each app's root.
//
//  Stage 1 (v2): the domain Booleans (flagsShowManuscripts, …) were replaced
//  by declarative bindings/overrides (S1-WP7b removed the migration shims);
//  AppShellConfigurationParityTests pins the presets to the frozen truth
//  table in docs/chassis-capability-matrix.md.

import SwiftUI

/// Auxiliary (non-record) routes an app shell offers.
public enum AuxiliaryRoute: String, Sendable, Hashable, Codable {
    /// The reviewer-facing Submissions inbox child of the Manuscripts section.
    case submissionsInbox
}

public struct AppShellConfiguration: Sendable {
    /// Stable per-app identity — also the prefix for per-app persisted sidebar
    /// order/collapse keys, so the apps keep independent sidebar layouts.
    public let appID: String

    /// Sections the sidebar is allowed to show. A section still applies its own
    /// content gate (`shouldShowSection`) on top of this — visibility is the
    /// intersection. `nil` means "no restriction"; NO preset uses it any more
    /// — imbib became explicit with the publications-only purification and
    /// even `impress`, which wants every section, lists them (ADR-0022 D9) —
    /// so a new section is invisible everywhere until a preset opts in. It
    /// stays supported for test shells only.
    public let visibleSections: Set<SidebarSectionType>?

    /// Which section is selected on first launch.
    public let defaultSection: SidebarSectionType

    /// Default detail tab (manuscript apps land in the editor).
    public let defaultDetailTab: DetailTab

    // MARK: v2 — declarative shell contract (ADR-0021)

    /// The record kinds this shell knows about.
    public let recordKinds: RecordKindRegistry

    /// Which record kind a cross-kind section serves in THIS shell — e.g.
    /// `.flagged: .manuscript` makes imprint's Flagged section list flagged
    /// manuscripts while imbib's default (`.publication`) lists papers.
    /// Sections absent from the map use the shell's primary kind semantics.
    public let sectionBindings: [SidebarSectionType: RecordKindID]

    /// Non-record routes present in this shell (Submissions inbox, …).
    public let auxiliaryRoutes: Set<AuxiliaryRoute>

    /// Per-kind open behavior overriding the descriptor's default — imprint
    /// opens manuscripts in its own editor window; imbib hands off.
    public let openOverrides: [RecordKindID: OpenBehavior]

    /// App-owned whole-pane surfaces (Stage 2 WP-X0). Empty for imbib/imprint
    /// today; implore/impart/impel register canvas/transcript/dashboard here.
    public let customSurfaces: CustomSurfaceRegistry

    /// Record kinds this HOST actually has a surface for. `nil` = every kind
    /// in `recordKinds` (what every preset says, so this changes nothing until
    /// a host opts in).
    ///
    /// This is the fourth, orthogonal visibility axis, and it exists because a
    /// preset is shared by MORE THAN ONE HOST. `AppShellConfiguration.imprint`
    /// permits `.citedInManuscripts`, whose rows are PUBLICATIONS: macOS
    /// imprint renders them through `UnifiedPublicationListWrapper`, and
    /// imprint-iOS has no publication list surface at all. imprint-iOS used to
    /// suppress that one section with a literal `section != .citedInManuscripts`
    /// in app code — an honest gate, but a hardcoded section name at a call
    /// site, and one that says nothing about WHY.
    ///
    /// Declaring the KIND instead says why, and generalises: a host that
    /// cannot present publications drops every publication-bound section,
    /// whatever it is called, and gains nothing to edit when a new one lands.
    /// Set it with `presenting(_:)` at the app root, next to
    /// `withCustomSurfaces(_:)` — the same "host augments the preset" seam.
    ///
    /// Relationship to the other three gates (all four must pass):
    /// - `permits(_:)` — the PRESET's section list; app identity, both platforms.
    /// - `passesFacetGate(_:)` — suite POLICY about which app owns a facet
    ///   section (`facetOwnerAppIDs`); also both platforms, and it fires even
    ///   for kinds the shell does register.
    /// - the host's CONTENT gate (`RecordSidebarDataSource.sectionIsAvailable`
    ///   on iOS, `shouldShowSection`'s arms on macOS) — "is there anything in
    ///   it right now".
    /// - this — "does this BUILD have a pane for the kind at all", which is
    ///   neither policy nor content but capability. It complements the facet
    ///   gate rather than replacing it: `facetOwnerAppIDs` is a deliberate
    ///   suite-wide statement, and folding it in here would scatter it across
    ///   per-host wiring.
    public let presentableKinds: Set<RecordKindID>?

    public init(
        appID: String,
        visibleSections: Set<SidebarSectionType>?,
        defaultSection: SidebarSectionType,
        defaultDetailTab: DetailTab,
        recordKinds: RecordKindRegistry = RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
        ]),
        sectionBindings: [SidebarSectionType: RecordKindID] = [:],
        auxiliaryRoutes: Set<AuxiliaryRoute> = [],
        openOverrides: [RecordKindID: OpenBehavior] = [:],
        customSurfaces: CustomSurfaceRegistry = CustomSurfaceRegistry(),
        presentableKinds: Set<RecordKindID>? = nil
    ) {
        self.appID = appID
        self.visibleSections = visibleSections
        self.defaultSection = defaultSection
        self.defaultDetailTab = defaultDetailTab
        self.recordKinds = recordKinds
        self.sectionBindings = sectionBindings
        self.auxiliaryRoutes = auxiliaryRoutes
        self.openOverrides = openOverrides
        self.customSurfaces = customSurfaces
        self.presentableKinds = presentableKinds
    }

    /// Does the configuration permit this section (before content gating)?
    public func permits(_ section: SidebarSectionType) -> Bool {
        guard let visibleSections else { return true }
        return visibleSections.contains(section)
    }

    /// Does this host have a surface for records of `kind`?
    public func canPresent(_ kind: RecordKindID) -> Bool {
        guard let presentableKinds else { return true }
        return presentableKinds.contains(kind)
    }

    /// Copy of this configuration restricted to the kinds this host can
    /// actually render. Hosts apply it at their root, like
    /// `withCustomSurfaces(_:)`.
    public func presenting(_ kinds: Set<RecordKindID>) -> AppShellConfiguration {
        AppShellConfiguration(
            appID: appID,
            visibleSections: visibleSections,
            defaultSection: defaultSection,
            defaultDetailTab: defaultDetailTab,
            recordKinds: recordKinds,
            sectionBindings: sectionBindings,
            auxiliaryRoutes: auxiliaryRoutes,
            openOverrides: openOverrides,
            customSurfaces: customSurfaces,
            presentableKinds: kinds)
    }

    /// The record kind a section serves in this shell (nil = shell default).
    public func recordKind(for section: SidebarSectionType) -> RecordKindID? {
        sectionBindings[section]
    }

    /// Effective open behavior for a record kind in this shell.
    public func openBehavior(for kind: RecordKindID) -> OpenBehavior {
        openOverrides[kind] ?? recordKinds[kind]?.defaultOpenBehavior ?? .detailPane
    }

    // MARK: Presets

    /// imbib: PUBLICATIONS ONLY — every publication-centric section, land in
    /// Inbox.
    ///
    /// Purity is the policy (ADR-0022 D9): imbib is the bibliography facet,
    /// other record kinds get their own shells (manuscripts → imprint,
    /// figures → implore, mail → impart, tasks/runs → impel), and `impress`
    /// is the preset that will unify them. imbib's `visibleSections` used to
    /// be `nil` ("no restriction"), which made every new chassis section
    /// surface here by default — the Manuscripts section rode in that way.
    /// It is now an EXPLICIT set: a future section must opt IN to imbib,
    /// consciously, in this list.
    ///
    /// Excluded on purpose: `.manuscripts` (imprint's facet; the chassis code
    /// stays — imprint and implore run on it), `.figures` (implore), `.mail`
    /// (impart), `.agents` (impel). Kept on purpose: `.citedInManuscripts` —
    /// its children are "All Cited Papers", i.e. PUBLICATIONS, and it is
    /// imbib's half of the imprint bridge; `.dismissed` — in imbib it is
    /// bound to `.publication` (see `sectionBindings` below) and is the
    /// destination of the publication dismiss gesture, so removing it would
    /// strand dismissed papers.
    ///
    /// Note: `.submissionsInbox` stays in `auxiliaryRoutes` but is currently
    /// UNREACHABLE in imbib — it hung off the Manuscripts section. The route
    /// and its feature are retained deliberately, pending a new home in
    /// imprint or impress (tracked in docs/chassis-capability-matrix.md
    /// "Known gaps").
    public static let imbib = AppShellConfiguration(
        appID: "imbib",
        visibleSections: [
            .inbox,
            .libraries,
            .sharedWithMe,
            .scixLibraries,
            .search,
            .exploration,
            .flagged,
            .tags,
            .citedInManuscripts,
            .artifacts,
            .reviewQueue,
            .dismissed,
        ],
        defaultSection: .inbox,
        defaultDetailTab: .info,
        sectionBindings: [
            .flagged: .publication,
            .tags: .publication,
            .dismissed: .publication,
        ],
        auxiliaryRoutes: [.submissionsInbox],
        openOverrides: [.manuscript: .appHandoff]
    )

    /// imprint: the authoring facet — Manuscripts (+ cited-in-manuscripts,
    /// flagged manuscripts, dismissed manuscripts), land in Manuscripts on
    /// the Source tab. No libraries / Inbox / SciX / search forms.
    public static let imprint = AppShellConfiguration(
        appID: "imprint",
        visibleSections: [.manuscripts, .citedInManuscripts, .flagged, .tags, .dismissed],
        defaultSection: .manuscripts,
        defaultDetailTab: .source,
        sectionBindings: [
            .flagged: .manuscript,
            .tags: .manuscript,
            .dismissed: .manuscript,
        ],
        auxiliaryRoutes: [],
        openOverrides: [.manuscript: .window(id: "manuscript-editor")]
    )

    /// implore: the visualization facet — the Figures section only (Stage
    /// 2-B), landing on Figures/Info. Flagged is deliberately SKIPPED in v1
    /// (would need a `.flagged: .figure` binding + routing). The Metal canvas
    /// and Generate/Analyze modes are app-owned custom surfaces registered
    /// APP-SIDE (a PMC preset cannot hold app views) via
    /// `withCustomSurfaces(_:)` in ImploreChassisRoot.
    public static let implore = AppShellConfiguration(
        appID: "implore",
        visibleSections: [.figures, .tags],
        defaultSection: .figures,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            FigureRecordKind.descriptor,
        ]),
        // Tags must bind THIS app's kind: an empty map falls back to the
        // canonical impress table, where `.tags` is `.publication` — so a
        // silent inherit would put paper tags in this shell's sidebar.
        sectionBindings: [.tags: .figure],
        auxiliaryRoutes: [],
        openOverrides: [:]   // figure's descriptor default is .window(id: "canvas")
    )

    /// impart: the communication facet — the Mail section only (Stage 2-A),
    /// landing on All Inboxes/Info. Chat/research/development are app-owned
    /// custom surfaces registered APP-SIDE (a PMC preset cannot hold app
    /// views) via `withCustomSurfaces(_:)` in ImpartChassisRoot. Flagged is
    /// deliberately skipped in v1 (same reasoning as implore: it would need
    /// a `.flagged: .message` binding + routing).
    public static let impart = AppShellConfiguration(
        appID: "impart",
        visibleSections: [.mail, .tags],
        defaultSection: .mail,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            MessageRecordKind.descriptor,
        ]),
        // Tags must bind THIS app's kind: an empty map falls back to the
        // canonical impress table, where `.tags` is `.publication` — so a
        // silent inherit would put paper tags in this shell's sidebar.
        sectionBindings: [.tags: .message],
        auxiliaryRoutes: [],
        openOverrides: [:]   // message's descriptor default is .detailPane
    )

    /// impel: the agent-orchestration facet — the Agents section only
    /// (Stage 2-C), landing on Tasks/Info. The dashboard / escalations /
    /// suggestions / counsel experiences are app-owned custom surfaces
    /// registered APP-SIDE (a PMC preset cannot hold app views) via
    /// `withCustomSurfaces(_:)` in ImpelChassisRoot. Flagged is deliberately
    /// skipped in v1 (same reasoning as implore/impart: it would need a
    /// `.flagged: .task` binding + routing).
    public static let impel = AppShellConfiguration(
        appID: "impel",
        visibleSections: [.agents, .tags],
        defaultSection: .agents,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            TaskRecordKind.descriptor,
            AgentRunRecordKind.descriptor,
        ]),
        // Tags must bind THIS app's kind: an empty map falls back to the
        // canonical impress table, where `.tags` is `.publication` — so a
        // silent inherit would put paper tags in this shell's sidebar.
        sectionBindings: [.tags: .task],
        auxiliaryRoutes: [],
        openOverrides: [:]   // task/agent-run descriptor default is .detailPane
    )

    /// impress: the shell that shows EVERYTHING (ADR-0022 D9).
    ///
    /// **No app target ships this preset.** There is no `impress` executable,
    /// no `ImpressChassisRoot`, no Info.plist. It exists so the seams the
    /// future app will stand on are exercised by parity tests TODAY —
    /// `AppShellConfigurationParityTests` freezes the truth table below, so a
    /// chassis change that would have quietly made impress impossible fails a
    /// test instead of being discovered in a year. The app itself waits for
    /// the sibling apps and their renderers to mature (D7); when it comes it
    /// should be a ~120-line shell over seams that have been green for months.
    ///
    /// `visibleSections` is the EXPLICIT union of every section the chassis
    /// has — `nil` ("no restriction") is retired suite-wide, including here.
    /// A shell that opted in by omission would be exactly the mechanism that
    /// rode the Manuscripts section into imbib. `impress` wants every section,
    /// so it says every section, and `testImpressPermitsEverySection` fails
    /// when the enum grows until someone decides.
    ///
    /// `sectionBindings` names the kind each section serves. Three deliberate
    /// notes:
    /// - `.flagged` / `.dismissed` bind to `.publication` for now. They are
    ///   the two cross-kind sections, and in the real impress they should list
    ///   flagged/dismissed records of EVERY kind through `AnyRecordListWrapper`
    ///   — a single `RecordKindID` cannot express that. `.publication`
    ///   reproduces imbib's behaviour exactly and keeps imprint's
    ///   manuscript-only routing (`== .manuscript`) off; the mixed-kind
    ///   version is a follow-up, not a preset edit.
    /// - `.reviewQueue` is deliberately UNBOUND: its rows are
    ///   `review-request@1.0.0` items, which have no `RecordKindDescriptor`.
    ///   Binding it to a kind it does not list would be a lie a future reader
    ///   trusts. When a review-request descriptor lands, this is its home.
    /// - `.agents` binds to `.task`; `agent-run` has no section of its own by
    ///   design (runs are a tree child of Agents and share `AgentSectionView`
    ///   — the scope decides which schema it lists). It is the one registry
    ///   kind that is not a `sectionBindings` value.
    ///
    /// `auxiliaryRoutes` gives the homeless Submissions inbox its designated
    /// future home. It hung off imbib's Manuscripts section and became
    /// unreachable with the publications-only purification; the route and
    /// `SubmissionsInboxView` were retained for exactly this
    /// (docs/chassis-capability-matrix.md, Known gaps: "Submissions inbox is
    /// unreachable in imbib after publications-only purification").
    ///
    /// `openOverrides` is EMPTY on purpose: impress embeds every viewer, so
    /// every kind should use its descriptor default. Note the one behaviour
    /// this leaves temporarily wrong — the manuscript descriptor's default is
    /// `.appHandoff` (hand off to imprint), which is right *today* because
    /// impress does not exist to open anything; when impress ships it becomes
    /// `.detailPane`. That is a descriptor/override decision to make at ship
    /// time, not a line of code to write now, and it is asserted as-is by the
    /// parity test so the change is deliberate.
    ///
    /// Keychain caveat: this preset permits `.search`, which means the
    /// ADS/SciX credential read in `TabContentView` WOULD run in impress. Those
    /// keychain items are ACL'd to imbib's code signature (see the invariant in
    /// apps/imbib/CLAUDE.md), so impress must either ship with imbib's keychain
    /// access group or the read must move behind a reachability check — a
    /// signing decision that has to be made before the target exists.
    public static let impress = AppShellConfiguration(
        appID: "impress",
        visibleSections: [
            .inbox,
            .libraries,
            .sharedWithMe,
            .scixLibraries,
            .search,
            .exploration,
            .flagged,
            .tags,
            .citedInManuscripts,
            .artifacts,
            .manuscripts,
            .figures,
            .mail,
            .agents,
            .reviewQueue,
            .dismissed,
        ],
        defaultSection: .inbox,
        defaultDetailTab: .info,
        recordKinds: BuiltinRecordKinds.registry,
        sectionBindings: [
            .inbox: .publication,
            .libraries: .publication,
            .sharedWithMe: .publication,
            .scixLibraries: .publication,
            .search: .publication,
            .exploration: .publication,
            .flagged: .publication,
            .tags: .publication,
            .citedInManuscripts: .publication,
            .artifacts: .artifact,
            .manuscripts: .manuscript,
            .figures: .figure,
            .mail: .message,
            .agents: .task,
            .dismissed: .publication,
        ],
        auxiliaryRoutes: [.submissionsInbox],
        openOverrides: [:]
    )

    // MARK: Facet gates

    /// App IDs allowed to SURFACE a facet-owned section, on top of
    /// `visibleSections` (ADR-0022 D9).
    ///
    /// `.figures` / `.mail` / `.agents` carry a pragmatic app-ID gate in
    /// `ImbibSidebarViewModel.shouldShowSection` from Stage 2 — belt-and-braces
    /// against a shell that leaves `visibleSections` nil. Each is a SET, not an
    /// equality test, because the owning app is no longer the only legitimate
    /// host: `impress` unifies every kind, and an `==` gate would let it permit
    /// these sections in its preset and still never show them.
    ///
    /// nil = no app-ID gate for that section.
    public static func facetOwnerAppIDs(for section: SidebarSectionType) -> Set<String>? {
        switch section {
        case .figures: return ["implore", "impress"]
        case .mail: return ["impart", "impress"]
        case .agents: return ["impel", "impress"]
        default: return nil
        }
    }

    /// Does this shell pass the sidebar's pragmatic app-ID gate for `section`?
    /// Orthogonal to `permits(_:)`: visibility is the intersection of both.
    public func passesFacetGate(_ section: SidebarSectionType) -> Bool {
        guard let owners = Self.facetOwnerAppIDs(for: section) else { return true }
        return owners.contains(appID)
    }

    /// Copy of this configuration with the given custom surfaces registered.
    /// Surfaces hold app-target views, so shells register them at the app
    /// root on top of the PMC preset (WP-X0 seam).
    public func withCustomSurfaces(_ surfaces: [CustomSurfaceDescriptor]) -> AppShellConfiguration {
        AppShellConfiguration(
            appID: appID,
            visibleSections: visibleSections,
            defaultSection: defaultSection,
            defaultDetailTab: defaultDetailTab,
            recordKinds: recordKinds,
            sectionBindings: sectionBindings,
            auxiliaryRoutes: auxiliaryRoutes,
            openOverrides: openOverrides,
            customSurfaces: CustomSurfaceRegistry(surfaces),
            presentableKinds: presentableKinds
        )
    }
}

// Equatable by shell identity + declarative fields (RecordKindRegistry holds
// closures, so descriptor equality is by id set — sufficient: registries are
// compile-time constants per shell).
extension AppShellConfiguration: Equatable {
    public static func == (lhs: AppShellConfiguration, rhs: AppShellConfiguration) -> Bool {
        lhs.appID == rhs.appID
            && lhs.visibleSections == rhs.visibleSections
            && lhs.defaultSection == rhs.defaultSection
            && lhs.defaultDetailTab == rhs.defaultDetailTab
            && lhs.recordKinds.descriptors.map(\.id) == rhs.recordKinds.descriptors.map(\.id)
            && lhs.sectionBindings == rhs.sectionBindings
            && lhs.auxiliaryRoutes == rhs.auxiliaryRoutes
            && lhs.openOverrides == rhs.openOverrides
            && lhs.customSurfaces.surfaces.map(\.id) == rhs.customSurfaces.surfaces.map(\.id)
            && lhs.presentableKinds == rhs.presentableKinds
    }
}

// MARK: - Environment

private struct AppShellConfigurationKey: EnvironmentKey {
    static let defaultValue = AppShellConfiguration.imbib
}

public extension EnvironmentValues {
    var appShellConfiguration: AppShellConfiguration {
        get { self[AppShellConfigurationKey.self] }
        set { self[AppShellConfigurationKey.self] = newValue }
    }
}
