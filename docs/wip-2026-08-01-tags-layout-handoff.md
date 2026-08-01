# WIP handoff — 2026-08-01: tag browsing, split-view width, impress icon

**Status: everything below is COMMITTED on `main` and unpushed** (`ce418527`
→ `92c60256`, eight commits). PMC is at 1,875 tests / 0 failures; imprint's
unit tests at 112 / 0. Every app target builds on every platform it ships on:
imbib, imprint, impart, impress macOS + iOS; implore and impel macOS.

The driving requirement, from the user:
**"Every artifact should be flaggable and taggable"** — and tags are
hierarchical, so the sidebar must browse them as a tree with a filter field.

---

## 1. Done — tag browsing (chassis-wide)

| Piece | Where |
|---|---|
| `RecordSidebarScope.tag(RecordKindID, String)` | `Chassis/Shared/RecordSidebar/RecordSidebarModel.swift` |
| `TagPathMatch` — the ONE matching authority | same file |
| `TagPathFilter` — the ONE filtering authority | same file |
| `.tag` on Figure/Message/Agent scopes; `.flagged` on Agent | `Chassis/RecordKind/RecordScopeKey+ListScopes.swift` |
| Filtering | `FigureListWrapper`, `MailStoreReader`, `AgentRecordListWrapper`, `ManuscriptStoreAdapter`, `IOSImpressListColumn` |
| `RecordSidebarDataSource.tags` + `tagNodes` + `tagFilter` | `Chassis/Shared/RecordSidebar/RecordSidebarBuilder.swift` |
| `RecordTagVocabulary` — the per-kind vocabulary memo | `Chassis/Shared/RecordSidebar/RecordTagVocabulary.swift` |
| `SidebarSectionType.tags` (+ `defaultOrder`, which is what made it render) | `Files/SidebarSectionOrderStore.swift` |
| macOS rows, vocabulary cache, filter + reveal | `Chassis/TabSidebar/{ImbibSidebarNode,TabSidebarTypes,ImbibSidebarViewModel,SectionContentView,TabContentView}.swift` |
| iOS rows + filter row | `Chassis/Shared/RecordSidebar/RecordSidebarView.swift` |
| Host `tags:` closures | imbib-iOS, imprint-iOS, impart-iOS, impress-iOS bindings |
| All 6 presets opt in; `.tags` bound per app's own kind | `Chassis/AppShellConfiguration.swift` |
| Filter knobs (`label`/`placeholder`/`showsHelp`/`autoFocus`) | `packages/ImpressFTUI/.../FilterInput.swift` |
| 7 frozen truth-table tests + 9 new tag/filter tests | `Tests/…/RecordSidebarBuilderTests.swift` and the four RecordKind tests |
| Matrix rows: `section(.tags)`, `tag`, `tag` FILTER | `docs/chassis-capability-matrix.md` |

### Four decisions that must not be silently reversed

1. **Matching is DESCENDANT-INCLUSIVE**, not exact — `.tag(kind, "reading")`
   returns `reading` and `reading/queue`. Exact-match makes the tree
   decorative: every interior row reads as empty while its children show rows.
   The rule lives in exactly one place, `TagPathMatch`; the boundary is the
   SEPARATOR (`reading` matches `reading/queue`, never `reading-list`).
2. **Tag filtering is an envelope POST-FILTER**, never a query argument and
   never a new FFI verb. Tags live on the item envelope, not the payload; this
   is the shape `.flagged` already uses. (ADR-0023 W3 wrote the same rule.)
3. **The FILTER narrows the vocabulary, not the rows** (`TagPathFilter`). Both
   tree builders derive interior rows from the paths they are handed, so
   narrowing the input keeps the parents of matching leaves for free — which is
   the whole difference between filtering a tree and filtering a list.
4. **A filtered Tags section survives its own emptiness.** Everywhere else "no
   rows" drops the section; here it would take the filter field, and the user's
   focus and text, with it.

Also: agent flag/tag rows bind `.task` only — an `agent-run` is immutable
provenance with no user mark to browse back.

### Two bugs the first pass shipped, both fixed here

* **`defaultOrder` is load-bearing.** `orderedVisibleSections` FILTERS by
  `SidebarSectionOrderStore.defaultOrder`, so `.tags` missing from that array
  meant the section rendered on NEITHER platform, however many presets opted
  in. The whole feature was invisible.
* **PMC's build compiles no sibling host.** `swift test` and the imbib targets
  were green while imprint-iOS, impart-iOS and impress-iOS all failed
  exhaustiveness on the new `.tag` cases, and `ManuscriptStoreAdapter` filtered
  tags by EXACT match. Build every app target before calling chassis work done.

---

## 2. Done — split-view list width

`packages/ImpressSidebar/Sources/ImpressSidebar/ImpressSplitView.swift`

Root cause of "the list keeps coming back to half the window": the correct
explicit-width path was **opt-in**. `listIdealFraction` was `CGFloat?` and
`nil` meant `HSplitView` + `idealWidth`, which AppKit treats as a hint and
ignores. So the broken layout was what a caller got by SAYING NOTHING — and
imbib's publication surface (`SectionContentView`, the largest in the suite)
said nothing.

- `listIdealFraction` is now non-optional, **default `0.25`**.
- The dead `HSplitView` path is **deleted**, so it cannot be reached by
  omission again.
- Second defect fixed: all four opted-in surfaces shared ONE storage key, so
  dragging the divider in Mail moved Figures. Keys are now per surface:
  `impress.split.{publications,manuscripts,mail,agents,figures}`.

User's spec: remembered drag wins; a quarter of window width is the fallback.

---

## 3. Done — impress app icon

`apps/impress/Shared/Assets.xcassets/AppIcon.appiconset` (in `Shared/`, so both
the `impress` and `impress-iOS` targets compile it). macOS 16/32/128/256/512
@1x+@2x, plus one universal 1024 for iOS. Both targets got
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; `xcodegen generate` was re-run.

Verified: `xcodebuild -scheme impress` → BUILD SUCCEEDED, and `AppIcon.icns`
lands in `impress.app/Contents/Resources/`.

**Gotcha for any future icon work:** the source PNG had an alpha channel and
**iOS icons must have none** (an App Store rejection, not a build failure).
`sips` cannot composite and this machine has no PIL. A throwaway CoreGraphics
flattener (`CGImageAlphaInfo.noneSkipLast`, white fill, high interpolation) was
used and then deleted; re-create it if sizes are regenerated. Every shipped
file reports `hasAlpha: no` — keep it that way.

Source art: `~/Downloads/Gemini_Generated_Image_ojvllsojvllsojvl.png`.

---

## 4. NOT DONE

### 4a. RUNTIME verification — do this first
Everything above compiles and is unit-tested; **no app has been launched to see
a Tags row, type in the filter, or select a tag**. The repo's own rule is that
a compile is not a confirmation. Launch imbib, expand Tags, type in the foot
filter, select an interior row, and watch `/api/logs?category=sidebar` on
:23120. The two things most likely to be wrong are things unit tests cannot
see: whether the foot filter steals focus from the outline's type-select, and
whether `expandAll` reveals matches in an `NSOutlineView` that builds children
lazily.

### 4b. Tag rows are read-only, and two of those are ❌-planned
Recorded in the matrix rather than left silent:
- **Drop records onto a tag row to apply it** — the apply half already exists
  in the shared `TriageMenu`, so this is the missing symmetry.
  `handlePublicationDrop` has no `.tag` arm and `capabilities(of:)` withholds
  `.droppable` in an explicit arm.
- **Rename / delete a tag path** — a vocabulary-wide rewrite across every kind
  that carries the path and its descendants. Needs `rename_tag_path` /
  `delete_tag_path` in `impress-core` first; a menu that renamed only what one
  shell can see would fork the vocabulary.

Also no badge counts on tag rows, on either platform: one count query per row
over a 23,916-path vocabulary. A `distinct_tags(schema_ref)` Rust verb would
make both this and `tagPathsInUse` an indexed query instead of a scan.

### 4c. Keyboard: no `/` for the sidebar filter
The field is reachable by click and by Tab, not by chord. `FilterInput` has no
external focus seam (it owns its `@FocusState`), so this needs either a
`FocusState` binding parameter or a focused-value action like
`listFilterFocusAction`.

### 4d. Window frame persistence — 4 apps unwired
`View.persistentWindowFrame(_:)` exists in
`packages/ImpressKit/Sources/ImpressKit/WindowFramePersistence.swift`
(AppKit `setFrameAutosaveName`; no-op on iOS). Applied to **impel only**.
Still to wire, one line each at the `WindowGroup` content root:
- `apps/imprint/Shared/ImprintApp.swift` — THREE window groups
  (`project-browser`, `manuscript-editor`, `pdf-preview`). Use the window's
  ROLE as the name, never a per-document id, or every opened manuscript leaves
  a stored frame forever.
- `apps/implore/Implore/Sources/App/ImploreApp.swift`
- imbib and impart macOS app entry points.

### 4e. Unclarified
The user also asked for "specific row widths". Only the split divider was
addressed. If they meant list COLUMN widths, that is a separate surface and
needs scoping.

---

## 5. Before pushing

The pre-push hook runs fmt + xcodegen + dual-platform imbib builds; it does NOT
build the sibling apps, which is exactly how this pass's four broken targets got
through. CI runs on self-hosted runners (impress-mac, impress-mac-2 —
**-3 and -4 were unloaded and persistently disabled on 2026-08-01**; do not
re-enable without capping `CARGO_BUILD_JOBS`, or builds get SIGKILLed under
8× oversubscription).
