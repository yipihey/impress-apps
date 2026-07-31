#if os(macOS)
// Chassis file — macOS-only (the outline sidebar's persistence seam).
//
//  SidebarPersistenceScope.swift
//  PublicationManagerCore
//
//  The macOS sidebar's persisted state, behind closures — so the view model can
//  be built HEADLESSLY.
//
//  ── Why this exists ─────────────────────────────────────────────────────────
//
//  `ImbibSidebarViewModel` is the largest file in the repo and, until this seam,
//  the only thing that could exercise its persisted behaviour was launching a
//  macOS app: its collapse state and section order were read from
//  `UserDefaults.standard` at INIT (stored-property initialisers, so before any
//  test could intervene) and written through process-wide singletons. A unit
//  test could construct the object, but could neither seed nor observe the half
//  of it that persists — and "collapse is loaded at launch and never saved" had
//  therefore shipped, unnoticed, with `handleExpansionChange` sitting there with
//  no callers at all.
//
//  This is the `StoreKernelScope` shape, applied to the same problem one layer
//  up: a struct of host-supplied hooks, a production value that is exactly the
//  singletons the code used before, and an `inMemory()` value that makes a
//  round-trip assertable in `swift test` with zero `UserDefaults` contact. The
//  production path is byte-for-byte what it was — same keys, same actors, same
//  fire-and-forget `Task` — so nothing about the five sibling shells changes.
//

import Foundation

/// Where the sidebar's persisted state comes from and goes to.
///
/// Two key spaces, deliberately not one:
///
///   * `SidebarSectionType` — the FLAT sidebar's section order and collapse
///     state, which the five sibling apps run and which is keyed by section
///     alone.
///   * `SidebarCompositionKey` — the COMPOSED sidebar's two tiers
///     (`group:<app>` / `section:<app>:<section>`), because `.flagged` occurs in
///     several groups at once and collapsing one must not collapse the rest.
///     Sharing the flat key space would also let an impress collapse land in
///     imbib's own sidebar: both read `UserDefaults.standard`, and the suite
///     shares a container.
@MainActor
struct SidebarPersistenceScope {

    var loadSectionOrder: () -> [SidebarSectionType]
    var saveSectionOrder: ([SidebarSectionType]) -> Void

    var loadCollapsedSections: () -> Set<SidebarSectionType>
    var saveCollapsedSections: (Set<SidebarSectionType>) -> Void

    var loadComposedCollapse: () -> Set<SidebarCompositionKey>
    var saveComposedCollapse: (Set<SidebarCompositionKey>) -> Void

    // MARK: - Production

    /// The shipping value: the same three stores, with the same keys, that the
    /// sidebar has always used. `save` is fire-and-forget onto the store actor,
    /// which is what the one existing writer already did.
    static let userDefaults = SidebarPersistenceScope(
        loadSectionOrder: { SidebarSectionOrderStore.loadOrderSync() },
        saveSectionOrder: { order in
            Task { await SidebarSectionOrderStore.shared.save(order) }
        },
        loadCollapsedSections: { SidebarCollapsedStateStore.loadCollapsedSync() },
        saveCollapsedSections: { collapsed in
            Task { await SidebarCollapsedStateStore.shared.save(collapsed) }
        },
        loadComposedCollapse: { SidebarCompositionCollapsedStore.loadCollapsedSync() },
        saveComposedCollapse: { collapsed in
            Task { await SidebarCompositionCollapsedStore.shared.save(collapsed) }
        })

    // MARK: - Scratch

    /// An in-memory scope backed by a scratch box — the headless substitute for
    /// launching the app.
    ///
    /// Writes are SYNCHRONOUS here, unlike the production actor hop, so a test
    /// can assert a round-trip without awaiting anything. That difference is
    /// deliberate and is the only one: the values written and the keys they are
    /// written under are the same types the production stores encode.
    static func inMemory(
        sectionOrder: [SidebarSectionType] = SidebarSectionOrderStore.defaultOrder,
        collapsedSections: Set<SidebarSectionType> = [],
        composedCollapse: Set<SidebarCompositionKey> = []
    ) -> SidebarPersistenceScope {
        let box = ScratchBox(
            sectionOrder: sectionOrder,
            collapsedSections: collapsedSections,
            composedCollapse: composedCollapse)
        return SidebarPersistenceScope(
            loadSectionOrder: { box.sectionOrder },
            saveSectionOrder: { box.sectionOrder = $0 },
            loadCollapsedSections: { box.collapsedSections },
            saveCollapsedSections: { box.collapsedSections = $0 },
            loadComposedCollapse: { box.composedCollapse },
            saveComposedCollapse: { box.composedCollapse = $0 })
    }

    /// Storage for `inMemory()`. A class so the load and save closures share it.
    @MainActor
    final class ScratchBox {
        var sectionOrder: [SidebarSectionType]
        var collapsedSections: Set<SidebarSectionType>
        var composedCollapse: Set<SidebarCompositionKey>

        init(
            sectionOrder: [SidebarSectionType],
            collapsedSections: Set<SidebarSectionType>,
            composedCollapse: Set<SidebarCompositionKey>
        ) {
            self.sectionOrder = sectionOrder
            self.collapsedSections = collapsedSections
            self.composedCollapse = composedCollapse
        }
    }
}
#endif
