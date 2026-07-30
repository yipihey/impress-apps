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
   the schemaRef↔kind assertions that ended up spread across
   `DocumentFormatParityTests`, `StoreSearchSurfaceTests`
   (`testEveryBuiltinSchemaRefResolvesToItsOwnKind`), and the per-kind
   record tests — a single `RecordKindParityTests` never landed under that
   name (see the litmus section below) — and the "Record-kind descriptor
   contract" table in docs/chassis-capability-matrix.md as
   definition-of-done.

4. **Adding a record kind is additive**: one descriptor + one
   `MailStyleItem` row struct + one `RecordScopeKey` scope + one thin list
   wrapper + a `sectionBindings` line + matrix rows + a selftest capability.
   Editing an existing chassis `switch` for a new kind is a review-blocking
   smell. (The path grew with ADR-0022 — collections, viewer registry, MCP.
   The re-run below is the current, honest version of this list.)

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

## Litmus re-run: adding an `audio-recording` kind

*Updated 2026-07-27 for ADR-0022 WP G8. D4 above states the Stage-1 path; the
collection kernel (D1/D3), the viewer registry (D4), grouped search (D6),
related items (D8) and the MCP surface (D5) all landed since, and each either
added a step or removed one. This is the whole path, as it actually is.*

The exercise: a researcher records interviews and lab-notebook voice memos.
Adding `audio-recording` as a first-class record kind — searchable, taggable,
foldered, agent-reachable — costs the following. **AUTOMATIC** = you write
nothing; **HAND-WRITTEN** = you write it, per kind, on purpose.

**1. Rust schema.** HAND-WRITTEN (~40 lines):
`crates/impress-core/src/schemas/audio_recording.rs` returning a `Schema`
(id `audio-recording`, version `1.0.0`, `FieldDef`s for `title`,
`duration_ms`, `data_hash`, `transcript`, `recorded_at`), plus one line in
`register_core_schemas` (`schemas/mod.rs`).
AUTOMATIC from there: item envelope, created/modified/author/logical clock,
`items_fts` indexing (it indexes *every* kind), sync, star/flag/tag/read
state, typed edges, blob/CAS storage for the audio payload.

**2. Shaped rows across the FFI.** HAND-WRITTEN: a `Decodable` payload struct
plus an `AudioRecordingStoreReader` (its own `SharedStore` handle, flat
`queryItems`/`countItems`, off-main) and an `AudioRowData: MailStyleItem`
value type built from `SharedItemRow` — the `MessageRowData` /
`FigureRowData` / `AgentRowData` shape, ~150 lines all told.
AUTOMATIC: **no FFI work at all.** `SharedStore.queryItems`/`countItems`/
`getItem` are generic over `schema_ref`; a new kind adds no UniFFI method, no
`.udl` edit, no XCFramework rebuild. This was not true before ADR-0022 G6.

**3. Descriptor (+ collection capability).** HAND-WRITTEN, but pure DATA:
`RecordKindID.audioRecording`, an `AudioRecordingRecordKind.descriptor`
(schemaRefs, display name, `DetailTabSpec`s, `TriageCapabilities`,
`defaultOpenBehavior`), and one line appending it to `BuiltinRecordKinds.all`.
If recordings should live in sidebar folders, add
`collection: CollectionCapability(bindingID: CollectionBindingID.generic,
canOrganize: true, dragUTTypeIdentifier: "com.impress.audio-recording-id")`
— three lines.
AUTOMATIC from that capability (the G2/D3 payoff): the ENTIRE sidebar folder
experience — create / rename / subfolder / reparent / reorder / delete,
drop targets, member counts, drag sessions (`RecordDragSession` is a registry
lookup keyed by binding), and kernel-backed undo for every one of them. The
generic `collection@1.0.0` binding already exists, so there is no new
`CollectionSchemaBinding`, no new Rust verb, and no Swift cycle check. Before
ADR-0022 this step was "copy ~400 lines of `ImbibSidebarViewModel` folder
logic and adapt the field names".
AUTOMATIC from the descriptor: detail-tab availability + coercion,
`TriageKeyGrammar` (which keys are live), `TriageSwipe`, `TriageMenu`, the
creation affordance behind `n`, and per-shell `openOverrides`.

**4. Thin wrapper + scope + views.** HAND-WRITTEN: an `AudioListScope:
RecordScopeKey`, an `AudioRecordingListWrapper`, an
`AudioRecordingSectionView` (list|detail split) and an
`AudioRecordingDetailPane` — the per-kind code ADR-0018 D3 and D2 above
deliberately keep. The waveform/transport view is real work; the chrome is
not (`MailStyleRow`, the shared triage builders, `RelatedItemsSection` all
drop in).

**5. Viewer-registry factory.** HAND-WRITTEN: ~7 lines appended to
`RecordViewerRegistry.builtin` mapping `.audioRecording` → its section view.
AUTOMATIC: `SectionContentView` resolves the pane from the registry — no
`switch` gains a case for the *view*.

**6. Section wiring.** HAND-WRITTEN, and this used to be the honest remaining
cost: a `SidebarSectionType` case, a node kind + route case
(`ImbibSidebarNodeType`, `ImbibContentRoute`, `ImbibTab`), the node→route
resolution, and a `shouldShowSection` arm. The chassis called this the
"node/tab/route case-addition pattern".

*Updated 2026-07-30 (Stage 3 — the ROUTE half is closed).* The four parallel
per-kind route enums (`ImbibJournalRoute`, `FigureRoute`, `MailRoute`,
`AgentRoute`), their four `ImbibContentRoute` wrapper cases, twelve `ImbibTab`
cases and four `SectionContentView` dispatchers collapsed into ONE
`RecordRoute` = `RecordKindID` + `RecordSidebarScope`, dispatched by ONE sink.
The registry-driven route type this paragraph called unscheduled is what
landed, and the vocabulary it routes in is the CROSS-PLATFORM one iOS's
sidebar already selects with — so macOS and iOS cannot disagree about what a
row means. A new kind now owes: a `RecordRouteScope` conformance next to its
own list scope, a viewer-registry factory line, and the lines that BUILD its
sidebar rows from its own store reader.

Still hand-written, and correctly so: a `SidebarSectionType` case (its String
rawValue backs persisted sidebar order/collapse state), the per-kind node cases
that read from the kind's own store reader, and a `shouldShowSection` arm.
**The G8 gate "zero chassis edits" now holds for BEHAVIOUR *and* for
routing**; what remains is per-kind CODE (a reader, a scope, rows), not a
chassis switch that has to learn the kind's name. Two subsets the chassis scope
vocabulary has no word for — implore's "Unfiled", impart's mail ACCOUNTS — ride
`RecordSidebarScope.host`, its declared escape hatch, with the key spelled once
next to the kind's own scope.

**7. Shell presets.** HAND-WRITTEN: one `sectionBindings` line per shell that
wants the section, one `visibleSections` entry, and — because `nil` is
retired suite-wide — an entry in `AppShellConfiguration.impress`, whose
parity tests fail until someone decides. That failure is the feature: the
unifying shell cannot silently forget a kind.

**8. Mixed-kind surfaces.** AUTOMATIC, all of it. Grouped global search
buckets the new rows the moment a row exists (`items_fts` + `search_all`),
and `KindTaggedRow` labels them correctly with no mapping table: the tolerant
`RecordKindRegistry.kind(forStoreSchemaRef:)` in `SchemaRefKindLookup.swift`
matches the descriptor's declared ref by base name, in both spellings
(`audio-recording` ↔ `audio-recording@1.0.0`). `AnyRecordListWrapper` groups
it; `RelatedItemsSection` renders its edges in every other kind's Info tab.
One-line exception: `RecordKindIconography.symbolName(for:)` needs a `case`
for the SF Symbol, or the row shows the honest "unknown kind" glyph rather
than a wrong one.

**9. MCP / agent surface.** AUTOMATIC — **zero new code**, because every tool
in the ADR-0022 D5 surface is store-generic:
`store-query-service_search-all`, `_related-items`, `_get-item`,
`_list-items`, `triage-service_set-starred` / `_set-flag` / `_add-tag` /
`_remove-tag`, and the whole `collection-service_*` verb set under
`binding: generic`. The `impress://store/schemas` resource lists the new kind
with its item count the moment the schema is registered. Nothing is
per-kind: no tool name mentions a record kind, which is why the MCP surface
does not grow when the store does. (`triage-service_set-status` is the one
op that needs the descriptor to declare `statuses` — a data edit in step 3,
not code.)

**10. Tests + matrix.** HAND-WRITTEN: a row in the "Record-kind descriptor
contract" table, sidebar/list rows in the capability matrix, and a Tier-A
selftest capability. The existing parity tests then cover the new kind for
free — `StoreSearchSurfaceTests` iterates `BuiltinRecordKinds.all` (every
declared ref must resolve back to its own kind, both spellings, and must not
collide with a `*-collection` schema), and `AppShellConfigurationParityTests`
iterates the section enum.

**Honest scorecard** *(rescored 2026-07-30 for Stage 3)*. Automatic: FFI,
search, related, triage, MCP/CLI/agent tools, collections + folder UI + undo
(and now the folder NODE — one `recordFolder(bindingID:folderID:)` case for
every binding), tab/coercion/keyboard behaviour, row chrome, and ROUTING (one
`RecordRoute`, one sink). Hand-written: the Rust schema, the payload decode +
row struct, the descriptor (data), the per-kind views, the registry factory
line, the scope + its `RecordRouteScope` conformance, the section/node lines,
preset lines, matrix rows. One wart left of the two: ADR-0021 D3 above names a
`RecordKindParityTests` that never landed under that name — descriptor↔store
schema-ref coverage lives in `StoreSearchSurfaceTests`, and a cross-check
against Rust's `register_core_schemas` is still owed. (The other, "the
navigation enums are not additive", is closed — see step 6.)
