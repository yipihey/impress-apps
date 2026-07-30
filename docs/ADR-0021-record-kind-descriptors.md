# ADR-0021: Record-Kind Descriptors — the Chassis Contract as Data

Status: Accepted (Stage 1 of the GUI unification).
D5's package extraction: **PARTIAL as of 2026-07-30** — five contract files
lifted into `packages/ImpressChassis`, 92 stayed, and the boundary map for the
rest is in "D5 extraction status" below. The third extraction trigger (build
time / binary size) has not fired and, on the measured graph, will not fire
from packaging alone.
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

   *Status 2026-07-30 (Stage 3 item C5): PARTIAL — five files lifted, 92
   stayed, and the "folder move" claim above is now known to be false for the
   descriptor itself. The measurement is below and it is the substantive
   output of C5; the code move is the small part.*

### D5 extraction status — measured 2026-07-30 (Stage 3 item C5)

**Verdict: partial lift. Five contract files moved; the chassis proper stays
in PMC, and the reason is structural rather than a matter of effort.**

The two named triggers had fired (conversions shipped; the descriptor API
survived the additions). The third — "build time or binary size measurably
hurts" — had not, and still has not; see the timings at the end. So C5
measured the cut before making it.

#### What the graph says

`Chassis/` is 97 files / 32,312 LOC. Its **transitive closure inside PMC is
348 of 545 files — 64% of PMC, 116,749 of 181,273 LOC**. Extracting the
chassis wholesale is not extracting a chassis; it is moving two thirds of
imbib, including `Domain/`, `Manuscript/`, `Search/`, `Inbox/`, `Persistence/`
and `SharedViews/`.

The asymmetry is the point. In the OTHER direction the boundary is almost
clean: only **9 chassis-declared symbols are referenced from 8 non-chassis PMC
files**, and **no PMC file extends a chassis type**. The chassis is the TOP
layer of PMC, not the bottom one. But the extraction D5 envisages
needs it to be the bottom layer — PMC must be able to depend on it — and a
top layer cannot be lifted underneath the thing it sits on.

#### The boundary table

64 of 97 chassis files name at least one non-chassis PMC symbol: **137 distinct
symbols, 771 references**. Classified by what the edge would have to BECOME for
the chassis to move:

| Class | Symbols | Refs | Chassis files touched | What it means |
|---|---:|---:|---:|---|
| **SEAM** — generic, moves WITH the chassis | 28 | 194 | 28 | `SidebarSectionType` (43), `DetailTab` (38), `PaneLayoutStore` (13), `CollectionStoreAdapter` (12), `ScreenConfigurationObserver` (12), `StoreUndoScope`/`RecordTriageStoreKernel`, `CollectionModel`, the sidebar order/collapse stores, `ListViewID`, `AppearanceMode` |
| **INJECTION POINT** — should become a protocol or closure the app supplies | 48 | 332 | 44 | `RustStoreAdapter` (115 — see below), `LibraryManager` (16), `ImbibImpressStore` (16), `InboxManager` (16), `AttachmentManager` (16), `LibraryViewModel` (15), `PDFSettingsStore` (13), `ExplorationService` (11), the SciX trio, `ManuscriptBridge`, `ManuscriptEditorSession` |
| **HARD ENTANGLEMENT** — publication/imbib types woven into shared surfaces | 61 | 245 | 41 | `PublicationModel` (33), `LinkedFileModel` (27), `PublicationSource` (17), `PublicationRowData` (15), `JournalManuscript(+Status)` (24), `PaperRepresentable` (9), `ResearchArtifact` (8), `DocumentFormat` (7), the per-source search-form views |
| **TOTAL** | **137** | **771** | **64** | |

Everything else the chassis names — `ImpressFTUI`, `ImpressMailStyle`,
`ImpressSidebar`, `ImpressTheme`, `ImpressKit`, `ImpressStoreKit` — is already
a package dependency and cost nothing to reason about. That part of ADR-0018
worked exactly as designed.

Three findings inside the table are worth more than the totals:

* **`RustStoreAdapter` is 115 of the 771 references, across 24 of the 97
  files** — a single imbib singleton reached for by a quarter of the chassis.
  It is one injection point, and it is the highest-leverage one in the suite:
  `StoreKernelScope` already proved the shape (the three host hooks a generic
  kernel needs), and nothing that generalises the chassis further can skip it.
* **The `PublicationSource` edge in `RecordScopeKey.swift` is a retroactive
  conformance, not an entanglement.** `extension PublicationSource:
  RecordScopeKey` is five lines that could sit next to `PublicationSource` in
  PMC while the protocol moves down. ADR-0018 D3 is not the obstacle it looks
  like here — the obstacle is `SidebarSectionType`, which `RecordSidebarModel`
  needs and which lives in `Files/SidebarSectionOrderStore.swift` (a SEAM,
  movable).
* **The descriptor is blocked by exactly one edge, and it is not a store
  type.** `RecordKindDescriptor.previewKind` is typed
  `DocumentFormat.PreviewKind`, and `BuiltinRecordKinds` builds the manuscript
  creation affordances from `DocumentFormat.allCases`.
  `Manuscript/Compile/DocumentFormat.swift` `import`s **ImbibRustCore** (its
  grammar table is a Rust constant, Stage 7 item 4), so moving it would make
  the suite-wide chassis package depend on imbib's Rust FFI. D5's purity rule —
  "must not import store types" — held, and was not sufficient: nobody wrote
  down "must not import a Rust core either". With `DetailTab` and
  `DocumentFormat` treated as movable seams, the clean subset jumps from **9
  chassis files / 1,674 LOC to 21 chassis files / 4,278 LOC** (4,512 LOC
  counting the two seam files themselves) — the whole descriptor core,
  `KindTaggedRow`, `RecordDragSession`, `AnyRecordListWrapper`,
  `SchemaRefKindLookup`, `RelatedItemsSection`, the Agents reader + rows. One
  enum's Rust-backed home is standing between the ADR's headline claim and its
  being true.

#### What moved

The closed subset that reaches nothing outside `Chassis/` is 9 files / 1,674
LOC. Five moved to `packages/ImpressChassis`:

| File (now `Sources/ImpressChassis/…`) | LOC |
|---|---:|
| `Settings/AppSettingsConfiguration.swift` | 817 |
| `Settings/SettingsSectionDescriptor.swift` | 273 |
| `RecordKind/RecordListHostModel.swift` | 73 |
| `Shared/ChassisNavigation.swift` | 46 |
| `Manuscripts/FocusedManuscript.swift` | 25 |

Four members of that subset stayed, on one rule: **do not split a file from
its gated companion across a module boundary.** `MarkdownPreviewTab.swift`
belongs with `MarkdownPreviewTab+Session.swift`,
`RecordTriageNewTagPrompt.swift` with `RecordTriage.swift`,
`DetachedWindowStateStore.swift` with `DetailWindowController.swift`;
`JournalEventBridge` is `internal` and lifting it would have meant widening
PMC's public surface to move 123 lines, which is a change wearing a move's
clothes.

#### The compatibility mechanism

`packages/ImpressChassis` was an eleven-line façade
(`@_exported import PublicationManagerCore`). C5 **reversed the arrow**: it
now has zero dependencies, PMC depends on it, and
`Chassis/ImpressChassisReexport.swift` does `@_exported import ImpressChassis`.
Every existing `import PublicationManagerCore` resolves every symbol exactly as
before, so **not one app target changed and not one test assertion changed**.
The only test-side edit is mechanical: the three suites that assert on chassis
SOURCE TEXT by path (`ChassisCrossPlatformContractTests`,
`SettingsSurfaceContractTests`, `RecordListHostTests`) now resolve through
`ChassisSourceRoots`, which tries PMC and falls back to the package — so they
kept their subjects, and a sixth file going down needs no edit there. One
assertion was ADDED, pinning the lift itself
(`testTheLiftedContractFilesLiveInTheChassisPackage`), because the resolver is
deliberately forgiving and a file quietly moving back would otherwise still
pass. Nothing in the tree imported `ImpressChassis` when the reversal happened,
so the façade could be retired outright rather than deprecated.

`scripts/check-chassis-deps.sh` now polices both manifests: PMC's historical
allowlist (22 local, 4 remote) plus an **empty** allowlist for ImpressChassis
and an explicit check that it never depends back on PMC.

#### Build time — the trigger that still has not fired

| | before | after |
|---|---|---|
| PMC clean `swift build` (compile / wall) | 66.7 s / 85.9 s | 68.3–74.5 s / 83.0–99.7 s (3 samples) |
| imbib macOS clean `xcodebuild` | 75.9 s | 70.6 s |
| ImpressChassis alone | — | 4.5 s |

The extraction bought nothing. An added module boundary is a serialization
point, and it costs about what five files' worth of parallelism saves. This is
the honest reading of D5's third trigger: **it has not fired, and the two-thirds
closure above says it will not fire from packaging alone.**

#### What must be untangled first, in dependency order

1. **`DocumentFormat.PreviewKind` off `RecordKindDescriptor`** (~half a day).
   Give the chassis its own preview-kind enum and typealias `DocumentFormat`'s
   nested one to it; make the manuscript kind's creation affordances declared
   data rather than a fold over `DocumentFormat.allCases`. Unlocks the whole
   descriptor core — 9 chassis files → 21, 1.7k LOC → 4.3k — with `DetailTab`
   moving alongside as the trivial seam it is. This is the highest
   value-per-hour item in the campaign, and it is a behaviour-shaped change,
   which is why C5 (moves + plumbing only) correctly did not do it.
2. **`SidebarSectionType` + the sidebar order/collapse stores down as a seam**
   (~1 day). Unlocks `RecordSidebarModel` / `RecordSidebarBuilder` /
   `RecordCollectionActions` / `RecordViewerRegistry` — the iOS shell surface —
   once (1) has moved `RecordScopeKey`, whose only blocker is a five-line
   retroactive conformance that stays behind with `PublicationSource`.
3. **`RustStoreAdapter` behind a protocol** (~1–2 weeks). 115 references, 24
   files. `StoreKernelScope` is the proven shape; this is the same move at the
   scale of the whole chassis, and until it lands `Shared/`, `TabSidebar/`,
   `Detail/` and the per-kind wrappers cannot move at all.
4. **The publication surfaces** (open-ended, and possibly never). `PublicationModel`,
   `PublicationSource`, `PublicationRowData` and `LinkedFileModel` are woven
   through `UnifiedPublicationListWrapper`, `PublicationListCore`,
   `SectionContentView`, `InfoTab` and `DetailView` — 245 references in the
   HARD class. ADR-0018 D3 forbids widening `PublicationSource`, and these are
   imbib's own types: the right end state is probably that these surfaces stay
   in PMC behind a boundary comment, and the chassis package is the contract
   plus the kinds that never name a publication.

Steps 1 and 2 are worth doing on their own merits — they make the descriptor
claim in D5 true. Step 3 is worth doing for the suite, not for the packaging.
Step 4 is not obviously worth doing at all, and no one should start 3 expecting
4 to follow.

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
