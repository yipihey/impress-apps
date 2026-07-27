#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
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
    /// intersection. `nil` means "no restriction" (imbib's default: everything).
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
        customSurfaces: CustomSurfaceRegistry = CustomSurfaceRegistry()
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
    }

    /// Does the configuration permit this section (before content gating)?
    public func permits(_ section: SidebarSectionType) -> Bool {
        guard let visibleSections else { return true }
        return visibleSections.contains(section)
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

    /// imbib: the full research environment — every section, land in Inbox.
    public static let imbib = AppShellConfiguration(
        appID: "imbib",
        visibleSections: nil,
        defaultSection: .inbox,
        defaultDetailTab: .info,
        sectionBindings: [
            .flagged: .publication,
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
        visibleSections: [.manuscripts, .citedInManuscripts, .flagged, .dismissed],
        defaultSection: .manuscripts,
        defaultDetailTab: .source,
        sectionBindings: [
            .flagged: .manuscript,
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
        visibleSections: [.figures],
        defaultSection: .figures,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            FigureRecordKind.descriptor,
        ]),
        sectionBindings: [:],
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
        visibleSections: [.mail],
        defaultSection: .mail,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            MessageRecordKind.descriptor,
        ]),
        sectionBindings: [:],
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
        visibleSections: [.agents],
        defaultSection: .agents,
        defaultDetailTab: .info,
        recordKinds: RecordKindRegistry([
            PublicationRecordKind.descriptor,
            ManuscriptRecordKind.descriptor,
            ArtifactRecordKind.descriptor,
            TaskRecordKind.descriptor,
            AgentRunRecordKind.descriptor,
        ]),
        sectionBindings: [:],
        auxiliaryRoutes: [],
        openOverrides: [:]   // task/agent-run descriptor default is .detailPane
    )

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
            customSurfaces: CustomSurfaceRegistry(surfaces)
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
#endif
