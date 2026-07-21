#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
//
//  AppShellConfiguration.swift
//  PublicationManagerCore
//
//  The thin-twin mechanism (GUI-meld plan §2/§7): the SAME chassis
//  (TabContentView) runs in both apps; the app's identity is which sidebar
//  sections are visible and where it lands, NOT which data is accessible
//  (ADR-0001). imbib shows everything; imprint shows only the Manuscripts
//  facet. Injected via the SwiftUI environment at each app's root.

import SwiftUI

public struct AppShellConfiguration: Sendable, Equatable {
    /// Stable per-app identity — also the prefix for per-app persisted sidebar
    /// order/collapse keys, so the two apps keep independent sidebar layouts.
    public let appID: String

    /// Sections the sidebar is allowed to show. A section still applies its own
    /// content gate (`shouldShowSection`) on top of this — visibility is the
    /// intersection. `nil` means "no restriction" (imbib's default: everything).
    public let visibleSections: Set<SidebarSectionType>?

    /// Which section is selected on first launch.
    public let defaultSection: SidebarSectionType

    /// Default detail tab (manuscript apps land in the editor).
    public let defaultDetailTab: DetailTab

    /// Whether the Manuscripts section shows the Submissions inbox child
    /// (reviewer-facing; hidden in the authoring-only imprint shell).
    public let showsSubmissionsInbox: Bool

    public init(
        appID: String,
        visibleSections: Set<SidebarSectionType>?,
        defaultSection: SidebarSectionType,
        defaultDetailTab: DetailTab,
        showsSubmissionsInbox: Bool
    ) {
        self.appID = appID
        self.visibleSections = visibleSections
        self.defaultSection = defaultSection
        self.defaultDetailTab = defaultDetailTab
        self.showsSubmissionsInbox = showsSubmissionsInbox
    }

    /// Does the configuration permit this section (before content gating)?
    public func permits(_ section: SidebarSectionType) -> Bool {
        guard let visibleSections else { return true }
        return visibleSections.contains(section)
    }

    // MARK: Presets

    /// imbib: the full research environment — every section, land in Inbox.
    public static let imbib = AppShellConfiguration(
        appID: "imbib",
        visibleSections: nil,
        defaultSection: .inbox,
        defaultDetailTab: .info,
        showsSubmissionsInbox: true
    )

    /// imprint: the authoring facet — Manuscripts (+ cited-in-manuscripts and
    /// flagged), land in Manuscripts on the Source tab. No libraries / Inbox /
    /// SciX / review-queue / dismissed.
    public static let imprint = AppShellConfiguration(
        appID: "imprint",
        visibleSections: [.manuscripts, .citedInManuscripts, .flagged, .search],
        defaultSection: .manuscripts,
        defaultDetailTab: .source,
        showsSubmissionsInbox: false
    )
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
