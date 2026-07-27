#if os(macOS)
// Chassis file — macOS-only in GUI-meld Phase 1 (iOS keeps IOSContentView).
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

/// The surfaces one app shell registers (compile-time, like record kinds).
public struct CustomSurfaceRegistry: Sendable {
    public let surfaces: [CustomSurfaceDescriptor]
    private let byID: [String: CustomSurfaceDescriptor]

    public init(_ surfaces: [CustomSurfaceDescriptor] = []) {
        self.surfaces = surfaces
        self.byID = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
    }

    public subscript(id: String) -> CustomSurfaceDescriptor? { byID[id] }
    public var isEmpty: Bool { surfaces.isEmpty }
}
#endif
