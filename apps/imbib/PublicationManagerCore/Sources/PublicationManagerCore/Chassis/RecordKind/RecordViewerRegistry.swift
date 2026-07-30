// Chassis CONTRACT file — CROSS-PLATFORM (macOS + iOS): the registry, the
// factory value type and the section context are pure data over SwiftUI
// `AnyView` closures. iOS had no registry at all while this was gated, so a
// kind's viewer could not even be NAMED there. The one macOS-only piece is the
// BUILTIN factory list (its section views are AppKit-adjacent) — split out to
// `RecordViewerRegistry+Builtin.swift`, the CustomSurface.swift precedent.
//
//  RecordViewerRegistry.swift
//  PublicationManagerCore
//
//  WP G3 (ADR-0022 D4): RecordKindID → view factories, so `SectionContentView`
//  resolves a kind's section view instead of naming the concrete type in a
//  switch.
//
//  Factories live HERE, never on `RecordKindDescriptor` — descriptors stay
//  Sendable DATA (ADR-0021 D3 discipline); this file is the one place in
//  Chassis/RecordKind/ that knows views exist.
//
//  What is deliberately NOT registered: publications and manuscripts. Both
//  keep their legacy routing in SectionContentView (the publication path owns
//  the fragile HSplitView + toolbar cluster; the manuscript path owns the
//  editor session, which must stay host-owned — see imbib CLAUDE.md). The
//  absence is asserted by RecordViewerRegistryTests so adding them is a
//  conscious act, not a drive-by.
//

import Foundation
import SwiftUI
import ImpressMailStyle

// MARK: - Section context

/// What a section factory needs to build one kind's list|detail split.
///
/// Per-kind scopes stay PARALLEL (ADR-0021 D2: `FigureListScope` is
/// figure-only), so the scope crosses the registry boundary in the CHASSIS
/// vocabulary (`RecordSidebarScope`, what both platforms' sidebars select
/// with) and each factory rebuilds the one type it owns.
///
/// Stage 3: this used to carry `any RecordScopeKey` and each factory
/// DOWNCAST — which meant the caller had to know the concrete per-kind type
/// already, i.e. the chassis had to switch on kind to build it. Carrying the
/// generic scope and letting the kind rebuild its own (`RecordRouteScope`)
/// moves that knowledge to the kind, where adding one is additive. Factory
/// bodies are unchanged: `scope(as:)` still hands back the concrete scope or
/// nil.
public struct RecordSectionContext {
    public let scope: RecordSidebarScope

    public init(scope: RecordSidebarScope) {
        self.scope = scope
    }

    /// The scope as its concrete per-kind type, or nil when a factory is
    /// handed a scope it doesn't own.
    public func scope<Scope: RecordRouteScope>(as type: Scope.Type) -> Scope? {
        Scope(routeScope: scope)
    }
}

// MARK: - Factory

/// The view surfaces one record kind contributes to the chassis.
public struct RecordViewerFactory: Identifiable, Sendable {
    public var id: RecordKindID { kind }
    public let kind: RecordKindID
    /// The whole list|detail section for a scope of this kind.
    public let makeSectionView: @MainActor @Sendable (RecordSectionContext) -> AnyView
    /// One heterogeneous-list row. Defaults to the shared mail-style chrome,
    /// which is what every kind renders today.
    public let makeListRow: @MainActor @Sendable (KindTaggedRow) -> AnyView

    public init(
        kind: RecordKindID,
        makeSectionView: @escaping @MainActor @Sendable (RecordSectionContext) -> AnyView,
        makeListRow: @escaping @MainActor @Sendable (KindTaggedRow) -> AnyView = {
            AnyView(MailStyleRow(item: $0))
        }
    ) {
        self.kind = kind
        self.makeSectionView = makeSectionView
        self.makeListRow = makeListRow
    }
}

// MARK: - Registry

/// Runtime registry of per-kind view factories, injected through the
/// environment (the `CustomSurfaceRegistry` pattern, one level up: surfaces
/// are app-owned whole panes, viewers are kind-owned sections).
///
/// Registration is expected at construction or app boot; the lock is there so
/// the type can be a plain `Sendable` environment value without pinning the
/// whole registry to the main actor.
public final class RecordViewerRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var factories: [RecordKindID: RecordViewerFactory]

    public init(_ factories: [RecordViewerFactory] = []) {
        self.factories = Dictionary(
            factories.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Register (or replace) the factory for a kind.
    public func register(_ factory: RecordViewerFactory) {
        lock.withLock { factories[factory.kind] = factory }
    }

    /// Lookup by kind; nil when no factory is registered.
    public subscript(kind: RecordKindID) -> RecordViewerFactory? {
        lock.withLock { factories[kind] }
    }

    public var registeredKinds: Set<RecordKindID> {
        lock.withLock { Set(factories.keys) }
    }

    // MARK: Builtin

    /// The kinds the shared chassis ships section views for.
    ///
    /// macOS-only CONTENT: the factories construct `FigureSectionView` /
    /// `MessageSectionView` / `AgentSectionView`, chassis views that are
    /// AppKit-adjacent today. They live in `RecordViewerRegistry+Builtin.swift`
    /// (gated); iOS gets an EMPTY registry — exactly the shape
    /// `CustomSurfaceRegistry.builtin` uses, and for the same reason. The
    /// registry itself is cross-platform, so nothing downstream changes.
    public static let builtin: RecordViewerRegistry = {
        #if os(macOS)
        RecordViewerRegistry(macOSBuiltinFactories)
        #else
        RecordViewerRegistry()
        #endif
    }()
}

// MARK: - Environment

private struct RecordViewerRegistryKey: EnvironmentKey {
    static let defaultValue = RecordViewerRegistry.builtin
}

public extension EnvironmentValues {
    var recordViewerRegistry: RecordViewerRegistry {
        get { self[RecordViewerRegistryKey.self] }
        set { self[RecordViewerRegistryKey.self] = newValue }
    }
}
