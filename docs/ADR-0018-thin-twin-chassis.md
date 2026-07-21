# ADR-0018: The Thin-Twin Chassis — One GUI, Many Apps

**Status:** Accepted (macOS shipped; iOS in progress)
**Date:** 2026-07-21
**Authors:** Claude (Fable 5 + Opus 4.8 sessions), for Tom's review
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0011 (Impress Journal — manuscripts as items), ADR-0016 (Throughline — peer items on manuscripts), imbib ADR-023 (iOS/macOS parity protocol)
**Scope:** `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Chassis/`, `.../Manuscript/`; `apps/imprint/macOS/Views/ImprintChassisRoot.swift`, `apps/imprint/Shared/ImprintApp.swift`; `crates/imbib-core`, `crates/impress-store-ffi`, `crates/impress-core/src/manuscript_ops.rs`

---

## Context

imbib and imprint were two separate GUIs over the *same* data. Both read and write
`manuscript@1.0.0` items in the *same* `impress.sqlite` (ADR-0001: "the app is
determined by which schemas and view configurations are active, not by which data
is accessible"), yet imprint carried a wholly independent ~1,600-line editor
chassis, its own sidebar, and its own detail layout. Every UX improvement had to be
built twice; the two never felt like one environment.

The goal: **launching imprint should feel exactly like launching imbib filtered to
manuscripts** — same sidebar (manuscripts in folders, like publications in
collections), same list, same detail tabs, same tags/flags/notes/enrichment, same
⌘F/⌘S grammar. Manuscripts simply support additional operations (editing, compiling).

## Decision

**One GUI package, thin app shells.** The entire macOS chassis lives in
`PublicationManagerCore` (PMC). Each app is a thin shell that hosts PMC's
`TabContentView` and declares its identity via an injected `AppShellConfiguration`.
The app is *which sections are visible and where it lands* — not which data it can
reach.

### D1 — The chassis is a package, not an app

25 chassis files (sidebar, unified list wrapper, `DetailView` + tabs, journal views,
windows, SciX, PDF browser) moved from the imbib app target into
`PMC/Chassis/` (`#if os(macOS)`). `TabContentView` is the single public entry point.
iOS keeps its own `IOSContentView` for now (ADR-023; the iOS chassis unification is
follow-up work).

### D2 — App identity is `AppShellConfiguration`, injected via the environment

`AppShellConfiguration` carries: `appID` (per-app persistence prefix),
`visibleSections` (`nil` = all), `defaultSection`, `defaultDetailTab`,
`showsSubmissionsInbox`. Two presets: `.imbib` (everything, land in Inbox/Info) and
`.imprint` (`[.manuscripts, .citedInManuscripts, .flagged, .search]`, land in
Manuscripts/Source). The sidebar's `shouldShowSection` intersects the config with
each section's own content gate; `configure()` selects `config.defaultSection`.
Default `.imbib` ⇒ imbib is byte-identical to before. imprint injects `.imprint`.

### D3 — Manuscripts are first-class rows, not a bolt-on, and NOT publications

The Rust core already stored manuscripts in the same `items` table. `imbib-core`
gained additive `ManuscriptRow`/`ManuscriptDetail`/`ManuscriptCollectionRow`/
`ManuscriptRevisionRow` shapers beside the bibliography ones (no polymorphic row
enum — manuscripts are not publication-shaped), plus list/count/get/create/search,
folder membership (reusing the schema-agnostic `Contains`-edge collection API), CAS
body save, and revision snapshots. Manuscripts deliberately stay **out of**
`PublicationSource`: they get their own ~250-line `ManuscriptListWrapper` reusing
only the shared mail-style row chrome, so the 2,231-line publication list wrapper's
enrichment / dismissed-triage / citeKey assumptions can never leak in.

### D4 — The editor lives in the detail pane, with a lifecycle outside the view tree

The Source tab hosts imprint's editor stack (moved into PMC) bound to a
`ManuscriptEditorSession`. Sessions live in an LRU `ManuscriptSessionRegistry`
**outside** the SwiftUI view tree; the detail pane resolves a session on
`.onChange(of: manuscriptID)` and carries **no `.id()`** — switching manuscripts or
tabs never tears down the `NSTextView`, its undo stack, or an in-flight compile.
Each session owns a 200 ms-debounced compare-and-set save
(`set_manuscript_body(expected_hash:)`) and a format-debounced in-process compile.

### D5 — Both apps compile in-process; capability, not `#if`, gates LaTeX

PMC links `ImprintCore` (the Typst renderer). imbib now compiles Typst natively —
no dependency on imprint being installed. LaTeX is injected via a `LaTeXCompiling`
capability: imprint installs `SystemLaTeXCompiler` (macOS TeX); imbib/iOS default to
`UnsupportedLaTeXCompiler`. There is no `#if os(macOS)` inside compile decision
logic — a capability object, so imbib-macOS-without-TeX behaves like iOS.

### D6 — Concurrent edits are safe at the write, live at the read

Two processes now routinely open the same manuscript. Safety is enforced at *save*
time by the CAS guard: `set_manuscript_body` rejects a write whose
`body_content_hash` no longer matches what the editor last loaded, and the session
raises a non-modal conflict banner (Keep mine / Take theirs). A proactive
read-side refresh (Darwin cross-process notification → `broadcastExternalChange`)
is the follow-up refinement; the CAS guard is the load-bearing invariant.

## Consequences

**Positive.** imprint is now a filtered launch of the identical imbib GUI (macOS
shipped, verified: clean launch, no TCC hang, no render loop). Every chassis
improvement now lands in both apps at once. Manuscripts gained Info-tab History
(operation timeline) and Versions (revision chain) for free. The pattern generalizes
to the other impress apps' layouts.

**Costs / risks.**
- **Binary size:** linking Typst into imbib pushed the *Debug* app to ~760 MB
  (release-stripped is far smaller). `typst-render` stays a cargo feature — the
  escape hatch is a compile-less imbib build if size ever becomes untenable.
- **Fragile chassis layout** (the `SectionContentView` toolbar/split invariants) is
  now shared by both apps; changes must respect the documented rules.
- **iOS** keeps a separate `IOSContentView`; full parity is follow-up (ADR-023).

**Invariants for future work.**
1. New sidebar sections gate on `AppShellConfiguration.permits` first.
2. The manuscript detail pane must never acquire `.id(manuscriptID)` — the registry
   owns editor lifecycle.
3. Manuscripts must not enter `PublicationSource`.
4. LaTeX support is a capability object, never a platform conditional.

## Status of the rollout

Shipped: Rust core (manuscript rows/history/CAS/revisions), chassis extraction,
Manuscripts section, Source tab + in-process compile + session registry,
Versions/History Info sections, ⌘F manuscript search, `AppShellConfiguration`, and
the imprint macOS cutover. Remaining: store-backed comments + Darwin notify +
UndoCoordinator, ⌘S citation-insert, legacy-code deletion, and iOS parity.
