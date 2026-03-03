# SwiftUI Layer Generalization Analysis for Impress Suite

## Context

The impress suite has 5 apps (imbib, imprint, implore, impel, impart) that share architectural principles documented in CLAUDE.md but implement SwiftUI UI patterns independently. imbib is the most mature app with the richest UI layer. As other apps grow, code duplication is emerging and the "Consistency Creates Capability" principle risks erosion. This analysis identifies what should be extracted from imbib (and elsewhere) into shared packages, and assesses the value of running `/simplify` on the SwiftUI layer.

---

## Part 1: High-Value Extraction Candidates

### Tier 1 — Immediate, High-Impact Extractions

#### 1.1 ConsoleView → `ImpressLogging` package
**What**: imbib and impart both have near-identical `ConsoleView.swift` (~280 lines each) — same log filtering, search, auto-scroll, export, copy, row rendering.
**Files**:
- `apps/imbib/imbib/imbib/Views/Console/ConsoleView.swift`
- `apps/impart/macOS/Views/Console/ConsoleView.swift`
**Benefit**: Every app needs a console (per CLAUDE.md: "All impress apps have an internal console window"). Extracting to `ImpressLogging` (which already owns `LogStore`, `LogEntry`, `LogLevel`) is natural.
**Complexity**: Simple — views are nearly identical, `LogStore` is already shared.
**Target**: Extend `packages/ImpressLogging/` with `ConsoleView.swift`, `ConsoleRowView.swift`, `FilterToggle.swift`.

#### 1.2 FlowLayout → `ImpressFTUI` or new `ImpressLayout` package
**What**: A generic wrapping horizontal layout (`FlowLayout: Layout`) that arranges chips/tags/badges. Currently buried in `PublicationManagerCore/SharedViews/FlowLayout.swift`.
**Files**: `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/SharedViews/FlowLayout.swift`
**Benefit**: Used for tag chips in imbib, but useful in implore (figure tags), impart (email labels), imprint (citation tags).
**Complexity**: Simple — self-contained 54-line `Layout` conformance with zero dependencies.
**Target**: Move to `packages/ImpressFTUI/` (which already has tag/filter UI components).

#### 1.3 ThemeColors + ThemeProvider → new `ImpressTheme` package
**What**: imbib has a rich theming system (`ThemeColors`, `ThemeEnvironment`, `ThemeProvider`, `ThemeSettings`, `ThemeSettingsStore`) with environment injection, color scheme support, serif/sans toggle, font scaling, and dark mode overrides. Other apps use hard-coded colors.
**Files**:
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Theme/ThemeColors.swift`
- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Theme/ThemeEnvironment.swift`
- Related: `ThemeSettings.swift`, `ThemeSettingsStore.swift`
**Benefit**: Unified theming across all apps. Currently imbib has a fully resolved `ThemeColors` system with accent, unread dot, sidebar tint, text colors, link colors, font preferences. Other apps would benefit from consistent appearance settings.
**Complexity**: Moderate — `ThemeColors` conforms to `MailStyleColorScheme` (coupling to `ImpressMailStyle`), and `ThemeSettings` has imbib-specific presets. Needs generalization to separate the "theme resolution engine" from imbib-specific presets.
**Target**: New `packages/ImpressTheme/` with the engine; apps provide their own `ThemeSettings` presets.

### Tier 2 — Medium-Impact Extractions

#### 2.1 Vim Pane Focus Cycling → extend `ImpressKeyboard` package
**What**: imbib's `FocusedPane` enum + `cycleFocusLeft()`/`cycleFocusRight()` pattern in `ContentView.swift`. Other apps reimplement this differently (impart uses raw string notifications like `"focusSidebar"`; impel uses its own handler).
**Files**:
- `apps/imbib/imbib/imbib/ContentView.swift` (lines 18-59, 314-347)
- `apps/impart/macOS/Views/ContentView.swift` (lines 271-279)
- `apps/impel/Shared/ContentView.swift` (keyboard handler)
**Benefit**: All apps need pane cycling. A shared `PaneFocusCycler` protocol + default implementation would enforce consistency.
**Complexity**: Moderate — each app has different pane topologies (imbib: 6 panes, impart: 3, impel: 2). Need a generic abstraction.
**Target**: Extend `packages/ImpressKeyboard/` with `PaneFocusCycler` protocol and view modifier.

#### 2.2 HSplitView Two-Pane Pattern → `ImpressSplitView` or extend `ImpressSidebar`
**What**: The documented pattern from CLAUDE.md: `HSplitView { ZStack { leftPane } ZStack { detailPane }.ignoresSafeArea(.container, edges: .top) }` with toolbar items in `.primaryAction`. Used in imbib (`SectionContentView`) and partially in impart (`CategoryView`).
**Files**:
- `apps/imbib/imbib/imbib/Views/TabSidebar/SectionContentView.swift` (lines 233-254)
- CLAUDE.md "macOS Toolbar & Split View Layout" section
**Benefit**: This is the canonical impress two-pane layout. A shared wrapper would:
  - Apply ZStack wrapping automatically
  - Apply `.ignoresSafeArea(.container, edges: .top)` on the detail pane
  - Provide `.padding(.top, 40)` scroll clearance helper
  - Eliminate the "why is my toolbar broken?" debugging cycle
**Complexity**: Moderate — the ZStack wrapping and safe area behavior are subtle. Need to parameterize left/right min widths.
**Target**: New `ImpressSplitView` wrapper component, potentially in `ImpressSidebar` package.

#### 2.3 Settings View Template → extend `ImpressKit` or new package
**What**: All apps have a `SettingsView` using `TabView { ... .tabItem { Label(...) } }` with similar tabs: General, Keyboard, AI, Automation. Settings tabs for Automation (HTTP API toggle + port) are particularly copy-pasted.
**Files**:
- `apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift`
- `apps/impart/macOS/Views/ContentView.swift` (lines 804-922 — settings, keyboard, automation)
- Automation settings in each app are near-identical (toggle + port field)
**Benefit**: Shared `AutomationSettingsTab`, `KeyboardShortcutsSettingsTab` (documentation view), and a `SettingsViewTemplate` that pre-wires common tabs.
**Complexity**: Simple for automation tab; moderate for keyboard shortcuts (each app has different shortcuts).
**Target**: Extend `ImpressAutomation` with `AutomationSettingsView`.

#### 2.4 Notification-Driven ViewModifier Pattern → document + shared infrastructure
**What**: imbib extracts notification handlers into `ViewModifier` structs (`ImportExportHandlersModifier`, `WindowManagementHandlersModifier`, `NotificationHandlersModifier` in imprint). This is a good pattern that reduces body complexity.
**Files**: Various ContentView files across all apps
**Benefit**: Not a new package, but a documented convention + helper. A `NotificationHandlerModifier` generic that takes `[(Notification.Name, (Notification) -> Void)]` would reduce boilerplate.
**Complexity**: Simple.
**Target**: Add to `ImpressKit` as a utility view modifier.

### Tier 3 — Lower-Priority / Future Extractions

#### 3.1 Global Search Palette Pattern
**What**: imbib's `GlobalSearchPaletteView` with context awareness (`SearchContext` environment key). Other apps don't have this yet but will need it.
**Complexity**: Complex — deeply tied to imbib's `PublicationRowData` and `RustStoreAdapter`.
**Target**: Generalize after other apps mature. The `ImpressCommandPalette` package (already exists but unused) should be activated first.

#### 3.2 DetailView Tab Pattern
**What**: imbib's `DetailView` with switchable tabs (Info/PDF/Notes/BibTeX), tab persistence across item changes, and auto-mark-as-read.
**Complexity**: Complex — tabs are domain-specific. The *pattern* (segmented picker binding + tab content switch + persistence) can be documented but probably shouldn't be a component.
**Target**: Document as a reference pattern in CLAUDE.md.

#### 3.3 Multi-Selection with Snapshot Display
**What**: `selectedPublicationIDs: Set<UUID>` + `displayedPublicationID: UUID?` + async detail loading pattern.
**Complexity**: Low to extract, but tightly coupled to list-detail architecture.
**Target**: Document as a reference pattern.

---

## Part 2: Cross-App Duplication to Eliminate

| Duplication | Apps | LOC Wasted | Fix |
|---|---|---|---|
| **ConsoleView** (identical) | imbib, impart | ~280 x 2 | Extract to `ImpressLogging` |
| **AutomationSettingsView** (Toggle + port field) | imbib, impart, imprint | ~30 x 3 | Extract to `ImpressAutomation` |
| **Vim j/k navigation handler** (different implementations) | all 5 apps | ~50 x 5 | Shared helper in `ImpressKeyboard` |
| **h/l pane cycling** (different approaches) | imbib, impart, impel | ~40 x 3 | `PaneFocusCycler` protocol in `ImpressKeyboard` |
| **Manual TextFieldFocusDetection checking** (impart uses raw check instead of .keyboardGuarded) | impart | ~15 | Fix impart to use `.keyboardGuarded` (it imports ImpressKeyboard but doesn't use it for all vim keys) |
| **Appearance settings** (System/Light/Dark picker) | impart, imprint, imbib | ~25 x 3 | Shared `AppearanceSettingsSection` in `ImpressKit` |
| **Modal editing settings** (Helix/Vim/Emacs toggle+description) | implore, imprint | ~60 x 2 | Move to `ImpressHelixCore` as `ModalEditingSettingsSection` |
| **ContentUnavailableView empty states** | all apps | ~10 x 5 | Not worth extracting — SwiftUI API is already clean |
| **FlowLayout** | imbib only, but needed by others | 54 | Move to `ImpressFTUI` |

---

## Part 3: Assessment of /simplify Value

### Would /simplify on the entire SwiftUI layer be valuable?

**Yes, selectively.** The imbib SwiftUI layer is ~35+ view files with varying complexity. Running `/simplify` would be most valuable on specific areas:

### Areas that WOULD benefit from /simplify:

1. **`SectionContentView.swift` (~967 lines)** — This file is the most complex view in the codebase. It mixes:
   - Content resolution logic (`resolvedContent`, `currentSource`, `currentLibraryID`)
   - Left pane switching (5 different content types)
   - Detail view construction with multi-selection handling
   - Toolbar construction with segmented picker and action buttons
   - Share menu and email composition
   - Window management (detached tabs)
   - Navigation helpers and notification handlers

   **Recommended split**: Extract toolbar and share menu into separate views/modifiers. Extract navigation helpers into an extension. The content resolution logic could be moved to the ViewModel.

2. **`ContentView.swift` (~725 lines)** — Mixes root composition with import/export business logic (`importPreviewEntries` is ~60 lines of import handling). The import/export logic should live in the ViewModel or a service, not in the view.

3. **`InfoTab.swift`** (likely large) — If it follows the pattern of having inline data fetching and formatting, those should be service methods.

4. **Notification name proliferation** — imbib uses ~30+ custom `Notification.Name` extensions. Some could be replaced by direct `@Observable` property changes or callback closures.

### Areas that should NOT be simplified:

1. **`DetailView.swift` (~415 lines)** — Appropriately complex. The tab switching, file drop support, and keyboard handling are necessary and well-structured.

2. **`TabContentView.swift` (~135 lines)** — Already clean. Just wires `NavigationSplitView` + sidebar + detail.

3. **`ConsoleView.swift`** — Clean, self-contained. Should be extracted, not simplified.

4. **Theme system (`ThemeColors`, `ThemeEnvironment`)** — Well-designed with clear responsibilities.

### /simplify recommendation:

Run `/simplify` on these files individually rather than the entire layer at once:
1. `SectionContentView.swift` — highest ROI
2. `ContentView.swift` — extract business logic to services
3. Any `SharedViews/` file over 300 lines

---

## Part 4: Recommended Implementation Order

### Phase 1 — Quick Wins (1-2 days)
1. **Extract `ConsoleView` to `ImpressLogging`** — Immediate dedup, zero risk
2. **Move `FlowLayout` to `ImpressFTUI`** — 5-minute move, enables other apps
3. **Fix impart to use `.keyboardGuarded`** — Eliminate manual text field checking

### Phase 2 — Foundation (3-5 days)
4. **Extract `AutomationSettingsView` to `ImpressAutomation`** — Dedup across 3 apps
5. **Add `PaneFocusCycler` to `ImpressKeyboard`** — Standardize h/l navigation
6. **Create `ImpressTheme` package** — Extract theme engine (without imbib presets)

### Phase 3 — Structural (5-8 days)
7. **Create `ImpressSplitView` wrapper** — Encode the HSplitView + ZStack + ignoresSafeArea pattern
8. **Add `NotificationHandlerModifier` to `ImpressKit`** — Reduce boilerplate
9. **Run `/simplify` on `SectionContentView.swift`** — Biggest single-file improvement

### Phase 4 — Integration (ongoing)
10. **Activate `ImpressCommandPalette`** — Wire into one app as pilot (imbib already has the view)
11. **Adopt shared packages in other apps** — imprint, implore, impel adopt ImpressTheme, ImpressSplitView
12. **Document patterns in CLAUDE.md** — Add "Shared UI Patterns" section with references

---

## Key Files Reference

| Purpose | Path |
|---|---|
| imbib root view | `apps/imbib/imbib/imbib/ContentView.swift` |
| imbib split layout | `apps/imbib/imbib/imbib/Views/TabSidebar/SectionContentView.swift` |
| imbib detail | `apps/imbib/imbib/imbib/Views/Detail/DetailView.swift` |
| imbib nav+sidebar | `apps/imbib/imbib/imbib/Views/TabSidebar/TabContentView.swift` |
| imbib console | `apps/imbib/imbib/imbib/Views/Console/ConsoleView.swift` |
| imbib theme | `apps/imbib/PublicationManagerCore/.../Theme/ThemeColors.swift` |
| imbib theme env | `apps/imbib/PublicationManagerCore/.../Theme/ThemeEnvironment.swift` |
| imbib FlowLayout | `apps/imbib/PublicationManagerCore/.../SharedViews/FlowLayout.swift` |
| impart console (dup) | `apps/impart/macOS/Views/Console/ConsoleView.swift` |
| impart content | `apps/impart/macOS/Views/ContentView.swift` |
| imprint content | `apps/imprint/Shared/ContentView.swift` |
| implore content | `apps/implore/Implore/Sources/App/ContentView.swift` |
| impel content | `apps/impel/Shared/ContentView.swift` |
| ImpressKeyboard | `packages/ImpressKeyboard/` |
| ImpressFTUI | `packages/ImpressFTUI/` |
| ImpressLogging | `packages/ImpressLogging/` |
| ImpressSidebar | `packages/ImpressSidebar/` |
| ImpressCommandPalette | `packages/ImpressCommandPalette/` |
| ImpressAutomation | `packages/ImpressAutomation/` |

## Verification

After each extraction:
1. Build all 5 apps to verify no regressions: `xcodebuild -workspace impress-apps.xcworkspace -scheme <app> build`
2. Run existing tests: `swift test --package-path packages/<package>`
3. Verify console window works in both imbib and impart after ConsoleView extraction
4. Verify keyboard shortcuts still work after ImpressKeyboard extensions
5. Verify theming still works in imbib after ThemeColors extraction
