# ADR-0019: The Legible Workspace — UI State as Attributed Items

**Status:** Proposed
**Date:** 2026-07-22
**Authors:** Claude (Opus 4.8 session), for Tom's review
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0002 (Operations as Overlay Items), ADR-0003 (Operations, Provenance, and Materialized State), ADR-0004 (Schema Registry and Type System), ADR-0006 (Retention Tiers and Compaction), ADR-0007 (Sync Architecture), ADR-0018 (Thin-Twin Chassis)
**Scope:** `crates/impress-core/src/schemas/` (new `ui.rs`); `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/AppState/PaneLayoutStore.swift`, `.../AppState/AppStateStore.swift`, `.../Theme/ThemeSettingsStore.swift`, `.../Automation/HTTPAutomationRouter.swift` (`/api/layout`, `/api/appearance`), `.../Sync/`; the projection/operation contract for any future GUI over the unified store

---

## Context

ADR-0001 established the founding claim: *the app is determined by which schemas and view
configurations are active, not by which data is accessible.* ADR-0018 cashed that in — imprint
is now a filtered launch of the identical imbib chassis. The store is legible; the data is
addressable; operations are attributed and time-travellable.

**The interface is not.** An audit of how workspace state is persisted today finds it trapped in
exactly the mechanisms the rest of the system was designed to escape:

- **Pane layout** (`PaneLayoutState`, saved layouts by name) lives in `UserDefaults.standard`
  under `imbib.layout.last` / `imbib.layout.saved` — local-only, per-app, per-device, JSON-encoded
  scalars.
- **Appearance / font scale / accent / sidebar style** live in `ThemeSettingsStore` (key
  `themeSettings`, `forCurrentEnvironment` UserDefaults) — local-only.
- **Selection, expanded libraries, active detail tab, notes-panel geometry** live in a *second*
  blob, `AppStateStore` (key `appState`) — local-only, and **overlapping**: detail-tab and
  notes-panel state exist in both `AppState` and `PaneLayoutState`.
- **Dozens of per-view toggles** (`manuscript.sourceTab.showPreview`, `imprint.helix.isEnabled`,
  `notesPosition`, PDF toolbar position…) are scattered `@AppStorage` keys in `UserDefaults.standard`.

Three properties follow, and all three contradict the system's own design principles:

1. **No provenance.** None of these blobs records who set a value or when. They are anonymous
   last-write-wins scalars. The attribution infrastructure (`SharedDefaults.authorIdentifier`,
   `ActorKind` on every item) exists — it simply is not applied to the interface.
2. **No sync.** Layout, saved layouts, appearance mode, font scale, and sidebar order are absent
   from `SyncedSettingsStore`'s `SyncedSettingsKey` enum and live in device-local UserDefaults.
   The *only* appearance-adjacent value that follows the user across devices is `pdfDarkModeEnabled`,
   via a bespoke KVS path. A researcher who arranges a triage layout on the office iMac opens the
   laptop to defaults.
3. **Not legible to agents.** `/api/layout` and `/api/appearance` exist, but they mutate a
   `@MainActor @Observable` store directly (`PaneLayoutStore.shared.current = …`). The interface
   state is *readable* over HTTP but it is not an operation, not attributed, not part of the record
   the agents themselves are audited against.

The opportunity a fresh GUI surface affords is to make one rule the five grown apps could never
retrofit: **the UI is a projection of the item graph, and every user action is an operation — with
no view-local source of truth.** This ADR takes that rule to its natural conclusion for the one
category of state still exempt from it. If layout, preference, and workspace arrangement are
*items*, then the interface itself keeps a lab notebook: it syncs, it carries provenance, and a
human and an agent become the same kind of user — both emit operations, both read projections.

## Decision

**Workspace state is modelled as attributed items in the unified store**, governed by the same
envelope, operation log, event bus, retention tiers, and sync path as every other item. UserDefaults
ceases to be a source of truth and becomes, at most, a device-local cold-start cache.

### D1. Two UI schemas, following the artifact-schema pattern

Add `crates/impress-core/src/schemas/ui.rs`, registered from `register_core_schemas` exactly as the
8 artifact types are (ADR-0004; `schemas/artifact.rs`). No core type changes — `schema` is a string,
`payload` is open JSON.

```rust
// impress/ui/layout@1.0.0 — a named or live workspace arrangement.
//   payload: { name?: String, sidebar_visible: Bool, detail_pane_visible: Bool,
//              detail_tab: String, sidebar_section_order: [String],
//              collapsed_sections: [String], … }  // the PaneLayoutState / AppState fields
//
// impress/ui/preference@1.0.0 — a portable interface preference.
//   payload: { appearance: String, font_scale: Number, accent_hex: String,
//              sidebar_style: String, use_serif_titles: Bool, keybinding_overrides: {…}, … }
```

`SavedPaneLayout` (name + `PaneLayoutState`) becomes an `impress/ui/layout` item whose `name` is a
payload field; the *live* arrangement is a distinguished layout item per scope (D2). `ThemeSettings`
becomes one `impress/ui/preference` item. The two overlapping local blobs (`AppState`,
`PaneLayoutState`) are reconciled into the layout schema during migration (D5) — the duplication is
resolved by construction, not left to drift.

### D2. Scope is the load-bearing decision — not everything follows you

The naïve version of "my workspace follows me" is a bug: window geometry from a 27" iMac has no
business overwriting the laptop. Every UI item therefore declares a **scope**, and scope is a pure
function of the two axes the substrate already carries — `Visibility` (ADR-0001) and `RetentionTier`
(ADR-0006) — plus an explicit device tag where needed. There is no new mechanism; scope is a
*policy* over existing fields.

| Scope | Examples | Visibility | Retention | Syncs? (ADR-0007) |
|-------|----------|------------|-----------|-------------------|
| **Portable-durable** | Saved named layouts, appearance mode, font scale, accent, keybindings | `Private` | `Durable` | Yes — rides the generic `ImpressItem` sync (D27) to all the user's devices |
| **Device-scoped** | Window frame, which display the PDF detaches to, monitor-specific splits | `Private` | `Durable` | Item carries a device tag in `origin`; the projection (D3) filters to the current device, so it persists locally but never *applies* elsewhere |
| **Ephemeral-session** | Live selection, scroll offset, expanded tree nodes, hover/focus | `Private` | `Ephemeral` | No — ADR-0007 D27 excludes the ephemeral tier from sync by design |

This mapping is the crux. It means the entire sync/no-sync and follows-me/stays-here behaviour is
expressed in fields the store *already* replicates and compacts, and the "workspace follows me from
the Mac app to the web client on the cluster" promise (ADR-0018's generalization) falls out of the
existing Phase-3 sync path with **zero new sync code** — a new engine is not required because durable
UI items are just `ImpressItem` records.

### D3. The projection/operation loop replaces direct `@Observable` mutation

Today the read path is UserDefaults → `@Observable` → view, and the write path is
`store.current = newValue`. Under this ADR both collapse into the same loop every other item obeys:

- **Read (projection).** A view reads a materialized projection of its UI item(s) via a thin
  `@MainActor @Observable` store that is *derived from* the graph, not authoritative. The store
  subscribes to the schema-filtered event bus on `impress/ui/` (prefix subscription, ADR-0015 D3;
  `sqlite_store.rs` `EventSubscriber { schema_prefix }`) and republishes on `OperationApplied`.
- **Write (operation).** Every user action — toggling the sidebar, applying a layout by name,
  switching appearance — emits an `OperationSpec` (`SetPayload` / `PatchPayload`) with `author`,
  `author_kind`, and an `OperationIntent`, applied through `apply_operation`. The materialized state
  is projected back to the view via the bus.

`POST /api/layout` and `POST /api/appearance` (`HTTPAutomationRouter`) are re-expressed as operation
emitters rather than direct store mutations. The consequence is the whole point: **an agent that
writes "open the review queue filtered to imprint proposals" is emitting the identical operation a
human click would**, the UI complies because it has no other source of truth, and the autonomous test
harness stops screen-scraping and asserts on the projected UI item (the `/api/layout`-style
verification generalized to the entire surface).

### D4. Provenance and intent come for free — and are worth having

Because each change is an attributed operation, the interface inherits an auditable history: *who*
arranged this workspace (`author` + `author_kind`: Human vs. Agent vs. System) and *why*
(`OperationIntent`, `reason`). "An agent rearranged my panes at 14:03 to surface a proposal" becomes
a real, inspectable, undoable event (`inverse_of`), not an invisible side effect. This is the grant
line stated plainly: not "we rewrote the UI in a modern framework" but "the interface is a verifiable
projection of an auditable record, testable by the same machinery that audits the agents." Few
products can claim their interface keeps a lab notebook; this one can.

### D5. Migration is a one-time import; UserDefaults degrades to a cache

On first launch after adoption, a one-shot importer reads the existing `imbib.layout.*`,
`themeSettings`, `appState`, and the load-bearing `@AppStorage` keys, and materializes them as
`impress/ui/*` items (authored `System`, intent `routine`). Thereafter:

- The graph is the source of truth.
- A **device-local mirror** of the current projection is kept in UserDefaults purely so cold start
  does not block on store-open or sync settle — the UI paints from the cache instantly, then
  reconciles to the projected item when the bus delivers. The cache is derived, never authoritative,
  and never synced.

Migration is additive and reversible: if the UI schemas are absent, the importer no-ops and the app
behaves exactly as today (the ADR-0018 "default `.imbib` ⇒ byte-identical" discipline).

### D6. Churn is bounded by tier + coalescing, and must not trip the startup guard

UI state is high-frequency (dragging a splitter emits many intermediate values). Two mechanisms,
both already in the substrate, keep the operation log from bloating:

- Transient adjustments are **debounced/coalesced** into a single `SetPayload` op on release, at
  `Ephemeral` retention, so they are compacted by the watermark-snapshot mechanism (ADR-0006;
  `emit_watermark_snapshot`) and never enter the durable audit trail or a sync payload.
- Only **committed** arrangements (saving a named layout, changing appearance) are `Durable`.

**Critical guard (do not reintroduce a known bug).** UI-item mutations during the first ~90 s of
launch would re-trip the startup render-loop invariant: a `.storeDidMutate` / `OperationApplied`
storm during the settling window compounds into perpetual SwiftUI re-evaluation (the beach ball;
see the standing invariant and imbib CLAUDE.md). The projection store MUST therefore (a) paint from
the device-local cache without emitting operations during startup, and (b) defer any
migration/reconciliation write until after the settling grace, using a single non-looping
`try? await Task.sleep` (never a `try?`-in-a-`for`-loop). This is the one place where "UI is a
projection" and "background mutations are dangerous at startup" collide, and it is designed for, not
discovered.

### D7. Boundaries and guards

- **Not every `@AppStorage` bool becomes an item on day one.** Migrate the load-bearing,
  cross-device-meaningful state first (layouts, appearance, saved arrangements, keybindings). Purely
  local, purely transient toggles may stay `@AppStorage` until there is a reason to move them;
  over-schematizing the interface is its own failure mode.
- **Device-scoped state must never sync-and-apply blindly.** Window geometry and display bindings
  carry a device tag and are filtered by the projection; they are the counterexample to "everything
  follows you."
- **The projection store is derived, never authoritative.** No view may write UI state anywhere but
  through an operation. A `@State`/`@AppStorage` field that shadows a UI item is a regression.
- **Reconcile the two blobs, don't preserve both.** `AppState` and `PaneLayoutState` collapse into
  the layout schema; the current field duplication must not survive migration.
- **Sync semantics are last-write-wins by `logical_clock`** (ADR-0007 D27), which is correct for
  discrete UI toggles and acceptable for layouts; this ADR does not introduce CRDT/OT for interface
  state, and does not depend on Phase 4.
- **Numbering hygiene.** Decisions here are local D1–D7; they do not extend the global D-series used
  by ADR-0003/0004/0007.

## Consequences

**Positive.** The interface joins the legible store: workspace arrangements, appearance, and
keybindings sync across a user's devices with zero new sync code (they are durable `ImpressItem`
records under ADR-0007 Phase 3). Every UI change carries provenance and is undoable. Humans and
agents become the same kind of user — both emit operations, both read projections — which makes the
autonomous harness assert on state instead of scraping pixels. The `AppState`/`PaneLayoutState`
duplication is resolved by construction. The pattern is the projection contract any future GUI over
the store (web client on the cluster) can adopt directly.

**Negative / costs.** A projection/operation indirection replaces a direct `@Observable` write —
more moving parts than `store.current = x`, and the startup-guard discipline (D6) is mandatory, not
optional. High-frequency UI without correct tiering would bloat the op log; the `Ephemeral`-tier +
coalescing policy must be honored per call site. Last-write-wins can discard a genuinely divergent
offline layout edit (rare, and recoverable from the op log). A device-local cache is now a second
representation to keep coherent, though strictly derived.

**Open questions.** (OQ1) Is the *live* (unsaved) arrangement one distinguished layout item per
device, or one portable item with a device-scoped override layer? The table in D2 implies the former
for geometry and the latter for logical layout — the exact split needs nailing before implementation.
(OQ2) Do UI items warrant their own retention sub-policy in compaction, or does the existing
`Ephemeral` watermark cadence suffice at UI churn rates? (OQ3) Should keybinding overrides be a third
schema (`impress/ui/keymap`) given they are structurally a map, not a flat preference? (OQ4) When the
web client and the Mac app are both live, is the live-arrangement item genuinely shared, or should
"presence"-like ephemeral UI stay device-local until Phase 4's collaboration model exists?

## References

- ADR-0001 (Unified Item Architecture) — "the app is which schemas are active"; `Item` envelope, `Visibility`
- ADR-0002 (Operations as Overlay Items), ADR-0003 (Operations, Provenance, Materialized State) — the operation/projection model this generalizes to UI
- ADR-0004 (Schema Registry and Type System) — the additive schema-registration pattern
- ADR-0006 (Retention Tiers and Compaction) — `Ephemeral`/`Durable` tiers, watermark snapshots
- ADR-0007 (Sync Architecture) — D27 generic `ImpressItem` sync; ephemeral tier excluded; HLC last-write-wins
- ADR-0018 (Thin-Twin Chassis) — "launching imprint feels like imbib filtered"; the generalization to layouts
- `crates/impress-core/src/item.rs` — `Item`, `ActorKind`, `logical_clock`, `Visibility`
- `crates/impress-core/src/schemas/artifact.rs`, `schemas/mod.rs` — schema-registration pattern to mirror in a new `schemas/ui.rs`
- `crates/impress-core/src/sqlite_store.rs` — schema-prefix event bus (`EventSubscriber`), `apply_operation`, watermark snapshots
- `apps/imbib/…/AppState/PaneLayoutStore.swift`, `.../AppState/AppStateStore.swift`, `.../Theme/ThemeSettingsStore.swift` — the UserDefaults blobs to migrate
- `apps/imbib/…/Automation/HTTPAutomationRouter.swift` — `/api/layout`, `/api/appearance` to re-express as operation emitters
- Ink & Switch, "Local-first software" (2019) — provenance and device-portable state
