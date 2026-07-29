// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the registry is pure
// data over SwiftUI `AnyView` factories, and `AppShellConfiguration` holds
// one, so it had to travel with the shell contract. The one macOS-only piece
// is the BUILTIN surface list (`StoreSearchSurface` imports AppKit) — that
// stays gated, and only that.
//
//  CustomSurface.swift
//  PublicationManagerCore
//
//  Stage 2 WP-X0 (ADR-0021): the plug-in seam for NON-record surfaces —
//  implore's generators, impart's chat/research transcripts, impel's
//  dashboard. A surface registers a whole-pane view; the chassis gives it a
//  selectable top-level sidebar node and renders it FULL-PANE (no list, no
//  detail toolbar cluster), which deliberately sidesteps the fragile
//  HSplitView/toolbar invariants.
//
//  The views live in APP TARGETS: PMC never links Metal, WebKit transcript
//  stacks, or dashboards. Design note: surfaces are top-level sidebar NODES,
//  not SidebarSectionType cases — the section enum's String rawValue backs
//  persisted order/collapse state, and widening it to associated values
//  would ripple through every section switch for no capability gain.
//

import SwiftUI

/// One app-owned, whole-pane surface.
public struct CustomSurfaceDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let makeView: @MainActor @Sendable () -> AnyView

    public init(
        id: String,
        title: String,
        systemImage: String,
        makeView: @escaping @MainActor @Sendable () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.makeView = makeView
    }
}

/// The surfaces one app shell registers (compile-time, like record kinds),
/// plus the CHASSIS-BUILTIN ones every shell gets whether it asks or not.
///
/// WP G4 (ADR-0022 D6) added the builtin tier. Grouped store-wide search is
/// not an app's feature — it is the chassis's answer to "where is that thing I
/// wrote", and an app that had to opt in would be an app that could forget to.
/// Composing it INTO the registry (rather than special-casing it in the
/// sidebar view model or `SectionContentView`) is the seam that costs zero
/// edits downstream: `ImbibSidebarViewModel` already emits a node per
/// registered surface, and `SectionContentView` already resolves ids through
/// `subscript(id:)`.
///
/// Builtins come LAST so an app's own surfaces keep their existing sidebar
/// order — imbib/imprint gain exactly one node, nobody's moves.
public struct CustomSurfaceRegistry: Sendable {

    /// Surfaces the chassis contributes to every shell.
    ///
    /// The one place PMC breaks the "surface views live in app targets" rule,
    /// and only because this view links nothing PMC does not already link.
    ///
    /// macOS-only content: `StoreSearchSurface` is an AppKit-linking view
    /// (NSPasteboard/NSWorkspace open routes). iOS shells get an empty
    /// builtin list until a UIKit-clean grouped-search surface exists — the
    /// REGISTRY itself is cross-platform, so nothing downstream changes.
    public static var builtin: [CustomSurfaceDescriptor] {
        #if os(macOS)
        [StoreSearchSurface.descriptor]
        #else
        []
        #endif
    }

    /// Every surface this shell shows, app-registered first then builtins.
    public let surfaces: [CustomSurfaceDescriptor]
    /// Only the surfaces the app registered — what parity tests should assert
    /// about a preset, since the builtins are not the preset's choice.
    public let appSurfaces: [CustomSurfaceDescriptor]
    private let byID: [String: CustomSurfaceDescriptor]

    public init(_ surfaces: [CustomSurfaceDescriptor] = []) {
        let builtins = Self.builtin.filter { builtin in
            // An app may deliberately replace a builtin by registering the
            // same id; its version wins rather than appearing twice.
            !surfaces.contains { $0.id == builtin.id }
        }
        self.appSurfaces = surfaces
        self.surfaces = surfaces + builtins
        self.byID = Dictionary(
            (surfaces + builtins).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: String) -> CustomSurfaceDescriptor? { byID[id] }

    /// True when the app registered no surfaces of its own. Builtins are not
    /// counted — `surfaces` is never empty.
    public var isEmpty: Bool { appSurfaces.isEmpty }
}
