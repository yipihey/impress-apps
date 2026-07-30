// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): two notification
// names. The HANDLER lives in `TabContentView` (macOS), the way
// `.openStoreSearch`'s does.
//
//  ChassisNavigation.swift
//  ImpressChassis (lifted out of PublicationManagerCore by C5)
//
//  Stage 4c (ADDITIVE seam, flagged): programmatic navigation INTO the chassis
//  from an app's own menu commands and URL scheme.
//
//  `.openStoreSearch` (WP G4) already proved the shape — a notification that
//  `TabContentView` turns into `viewModel.navigateToTab(...)` — but it is
//  hardcoded to ONE surface, the builtin search one. Every app that made the
//  chassis its default window immediately needed the general case:
//
//    * impart's ⌘1-5 select Mail / Chat / Category / Research / Development.
//      Four of those five are registered custom surfaces; the fifth is the
//      shell's default landing section.
//    * impel's `impel://navigate/{dashboard,escalations,suggestions,counsel,
//      threads,agents}` used to set a `DashboardTab` that only the classic
//      window observed, so with the chassis as default the URL scheme
//      navigated nothing.
//
//  Deliberately NOT a general "select any tab" seam: `ImbibTab` is internal
//  chassis vocabulary (and Stage 3 spent real effort collapsing it), so the
//  two things an app legitimately names — "my surface, by the id I registered"
//  and "wherever this shell lands by default" — are the two things that cross
//  the boundary. Anything else is a sidebar node, which the user clicks.
//

import Foundation

public extension Notification.Name {

    /// Select an app-owned custom surface. `object` is the surface id String,
    /// exactly as registered in `CustomSurfaceDescriptor.id`; an id no surface
    /// claims is ignored (no navigation, no empty pane).
    static let chassisNavigateToSurface =
        NSNotification.Name("impress.chassisNavigateToSurface")

    /// Select this shell's default landing leaf — imbib's Inbox, impart's All
    /// Inboxes, impel's Tasks. The same resolution the sidebar performs at
    /// first launch, so "go home" cannot drift from "start here".
    static let chassisNavigateToDefaultSection =
        NSNotification.Name("impress.chassisNavigateToDefaultSection")
}
