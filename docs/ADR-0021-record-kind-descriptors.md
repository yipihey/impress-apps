# ADR-0021: Record-Kind Descriptors — the Chassis Contract as Data

Status: Accepted (Stage 1 of the GUI unification)
Date: 2026-07-26
Depends on: ADR-0001 (unified item architecture), ADR-0018 (thin-twin chassis)

## Context

The suite converges on one GUI mold: sidebar to organize, list to select,
info/source/view tabs to inspect — specialized per record kind (publication,
manuscript, figure, message, task…). ADR-0018 proved the thin-twin mechanism
(imprint = a 110-line shell over the shared chassis) but left the contract
encoded in closed Swift enums (`DetailTab.ItemKind`, four domain Booleans on
`AppShellConfiguration`), so each new record kind meant editing switches
across the chassis — the class of micro-bug the capability matrix exists to
catch.

## Decision

1. **The chassis contract is data.** `RecordKindDescriptor`
   (`PMC/Chassis/RecordKind/`) declares, per kind: store `schemaRefs`, detail
   tabs with availability rules (`DetailTabSpec` + `RecordTabContext`),
   `TriageCapabilities` (star/flag/tag, dismissal/archive/delete semantics,
   status lifecycle), creation affordances (drives `n` and File menus), and a
   default `OpenBehavior`. Shell presets carry a compile-time
   `RecordKindRegistry` plus `sectionBindings` (section → kind),
   `auxiliaryRoutes`, and `openOverrides` — replacing the domain Booleans.

2. **Per-kind row structs and thin list wrappers STAY** (ADR-0018 D3 is not
   overturned): descriptors describe the contract *around* the per-kind code,
   they are not a runtime rendering engine. `PublicationSource` remains
   publication-only; scopes are parallel per kind and conform to
   `RecordScopeKey` (`stableViewID` standardizes the `.id()` rule).

3. **Exhaustiveness moves from the compiler to tests + the matrix.**
   `RecordKindID` is string-backed (additive kinds). The trade is enforced by:
   `RecordKindDescriptorTests` (descriptors ≡ frozen legacy behavior),
   `AppShellConfigurationParityTests` (presets ≡ frozen truth table),
   `RecordKindParityTests` (descriptor schemaRefs ↔ Rust schema registry, both
   directions), and the "Record-kind descriptor contract" table in
   docs/chassis-capability-matrix.md as definition-of-done.

4. **Adding a record kind is additive**: one descriptor + one
   `MailStyleItem` row struct + one `RecordScopeKey` scope + one thin list
   wrapper + a `sectionBindings` line + matrix rows + a selftest capability.
   Editing an existing chassis `switch` for a new kind is a review-blocking
   smell.

5. **Descriptor purity**: `Chassis/RecordKind/` must not import store types.
   This keeps the future `ImpressChassis` package extraction a folder move.
   Extraction trigger (Stage 2+): all three app conversions shipped AND the
   descriptor API survived two consecutive record-kind additions unchanged
   AND build time or binary size measurably hurts.

## Consequences

- imbib and imprint behavior is pixel-identical post-retrofit (shim tests run
  BEFORE legacy paths are deleted).
- Custom, non-record surfaces (canvas, transcripts, dashboards, compose) are
  explicitly out of descriptor scope — they plug in as whole-pane
  `CustomSurface` registrations (Stage 2), owned by app targets.
- The status lifecycle convention (docs/status-lifecycle.md) governs the
  reserved `dismissed`/`archived` values; publications keep their
  library-move dismissal (the filter_dismissed invariant) until a guarded
  Stage-2 harmonization.
