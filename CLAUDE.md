# Impress Apps - Claude Code Briefing

## Foundational Philosophy

Impress is a **research operating environment**—not a collection of apps, but a unified substrate where researchers conduct their entire intellectual workflow without context-switching friction.

**The goal: sustained flow for human and agentic colleagues working together on research.**

### The Suite

| Tool | Domain | Verb Form |
|------|--------|-----------|
| **imbib** | bibliography, paper management, reading | "imbib papers" |
| **imprint** | manuscript authoring, Typst-based writing | "imprint manuscripts" |
| **implore** | data visualization, exploratory plotting | "implore data" |
| **impel** | AI agent orchestration, task delegation | "impel agents" |
| **implement** | coding, reproducible computation | "implement code" |
| **impart** | communication—email, chat, messaging | "impart ideas" |

These are **facets of a single environment** that share state, context, and interaction paradigms.

## Design Principles

### 1. Flow Above All
Every design decision must answer: *does this preserve or break flow?*
- Transitions between tools must be instantaneous and contextual
- No modal dialogs that halt work; prefer inline, non-blocking interactions
- The user should forget they are using "separate tools"

### 2. Keyboard-First, Always
- Every action must be keyboard-accessible
- Prefer modal interaction patterns (vim/Helix philosophy)
- Command palettes and fuzzy finding over menu hierarchies
- Consistent keybinding grammar across all tools

### 3. Agent-Native Architecture
Agents are first-class participants, not afterthoughts.
- Every tool exposes its full capability surface to impel
- State is legible: agents can read what the human sees
- Actions are composable: agents can chain operations across tools
- Human review points are explicit and respected

### 4. Integration Over Independence
Cross-tool workflows that must feel native:
- Email (impart) → extract paper → add to imbib → open in reader
- Writing (imprint) → cite from imbib → embed figure from implore
- Agent (impel) → read email → draft response → queue for review

### 5. Researchers Are the Users
- Assume intelligence; don't over-explain
- Respect domain conventions (BibTeX, DOI, arXiv, LaTeX math)
- Performance matters: large bibliographies, big datasets, long manuscripts
- Offline capability is essential
- Privacy and data ownership are non-negotiable

### 6. Typst as the Document Substrate
- Superior to LaTeX for authoring experience
- Programmatic and composable, fast compilation
- Clean syntax that agents can reliably generate and modify

### 7. Consistency Creates Capability
- Same navigation keys everywhere
- Same search/filter paradigm everywhere
- Same selection model everywhere
- When a user learns one tool, they've partially learned them all

## Decision-Making Heuristic

When facing a design or implementation choice, ask in order:

1. **Does this preserve flow?** If it adds friction, find another way.
2. **Is this keyboard-accessible?** If not, make it so.
3. **Can agents participate?** If not, expose the capability.
4. **Is this consistent with other tools?** If not, reconcile or have strong reasons.
5. **Does this respect the researcher's intelligence?** Don't patronize.

## Technical Architecture

### Rust Core + Native UI Layer

```
┌─────────────────────────────────┐
│  Native UI (Swift/AppKit)       │  ← Platform-appropriate, keyboard-optimized
├─────────────────────────────────┤
│  Rust Core Library              │  ← Business logic, data structures, algorithms
├─────────────────────────────────┤
│  Shared Integration Layer       │  ← Cross-tool communication, agent interface
├─────────────────────────────────┤
│  Persistent State (SQLite/fs)   │  ← Local-first, syncable
└─────────────────────────────────┘
```

**Why Rust:** Performance, safety, cross-platform potential, excellent ecosystem for parsing/data/async.

**Why Swift/AppKit:** Native macOS experience, system integration, accessibility. SwiftUI where appropriate, AppKit where control is needed.

### Local-First, Sync-Capable
- All data lives locally by default
- User owns their data completely
- Sync via user-controlled mechanisms (iCloud, git, etc.)
- No mandatory cloud dependency

### Agent Integration Protocol
- **State queries:** What is currently open/selected/visible?
- **Action requests:** Perform operation X with parameters Y
- **Context sharing:** Relevant state from other tools
- **Review checkpoints:** Pause for human approval

All tools implement this protocol. Agents never scrape UI; they use structured interfaces.

## What Impress Is Not

- **Not a browser.** We do research workflows, not everything.
- **Not cloud-first.** Local-first with optional sync.
- **Not cross-platform initially.** macOS-native first. Quality over reach.
- **Not a walled garden.** Import/export standard formats. Users can leave.

## Repository Structure

```
impress-apps/
├── apps/
│   ├── imbib/          # Bibliography & paper management
│   ├── imprint/        # Typst manuscript authoring
│   └── implore/        # Data visualization
├── packages/
│   ├── ImpressKit/     # Shared Swift utilities
│   ├── ImpressAI/      # AI integration layer
│   └── impress-mcp/    # MCP server for agent integration
└── crates/
    └── imbib-core/     # Rust core for imbib
```

## Coding Conventions

- Swift 5.9+, strict concurrency
- `actor` for stateful services, `struct` for DTOs, `final class` for view models
- Prefer `async/await` over Combine
- Domain errors conform to `LocalizedError`
- **Naming**: Protocols `*ing`/`*able`, implementations no suffix, view models `*ViewModel`

## Swift Concurrency & SwiftUI Pitfalls

These rules prevent subtle bugs that are hard to diagnose. Follow them strictly.

### Capture @State Before Async Work

**Never read `@State`/`@Binding` properties inside `Task { }` closures.** Always capture into local variables first.

```swift
// CORRECT
let targetIDs = self.targetIDs   // capture the snapshot
let items = self.items
Task {
    for id in targetIDs { ... }  // uses captured value
}

// WRONG — @State may change before Task body runs
Task {
    for id in self.targetIDs { ... }  // may be empty/stale
}
```

SwiftUI `@State` is backed by heap storage. A `Task` closure captures a reference to that storage, not a snapshot of the value. If another view (e.g., an overlay dismissing, a binding resetting) modifies the state between `Task { }` creation and execution, the Task sees the modified value. This class of bug is invisible without logging.

### Console-First Debugging

All impress apps have an internal console window. When implementing features that involve async data flow:

1. **Log the mutation** — what was requested, with what parameters
2. **Log the save** — did the persistence layer see changes?
3. **Log the display** — did the UI layer read the data back?

This three-point trace makes async timing bugs immediately visible (as seen above: "applying to 0 pubs" instantly reveals the capture bug).

### Core Data To-Many Relationships

Use `mutableSetValue(forKey:)` for to-many relationship mutations, not direct property assignment. See [imbib CLAUDE.md](apps/imbib/CLAUDE.md) for details.

### Keyboard Shortcuts Must Not Steal Text Field Input

All impress apps use vim-style single-key shortcuts (h, j, k, l, s, d, etc.) for navigation. These **must not fire when the user is typing in a text field, TextEditor, or search field.**

**The rule: Always use `.keyboardGuarded {}` instead of `.onKeyPress {}` for any handler that matches unmodified character keys.**

The `ImpressKeyboard` package provides the solution:
- `TextFieldFocusDetection.isTextFieldFocused()` — checks if an editable NSTextView/NSTextField is the first responder
- `.keyboardGuarded { press in ... }` — view modifier that wraps `.onKeyPress` with the text field guard

```swift
// CORRECT — shortcuts are suppressed when user is typing
.keyboardGuarded { press in
    if press.characters == "j" { navigateDown(); return .handled }
    if press.characters == "k" { navigateUp(); return .handled }
    return .ignored
}

// WRONG — "j" and "k" get intercepted while typing in a comment field
.onKeyPress { press in
    if press.characters == "j" { navigateDown(); return .handled }
    ...
}
```

**When `.onKeyPress` is still OK:**
- Handlers that only match special keys (Escape, Return, arrows, Tab) — these don't conflict with text input
- Handlers that only match modified keys (Cmd+1, Shift+Cmd+R) — modifiers prevent conflict
- Handlers inside focused text input components (CommandPalette, FilterInput) that manage their own focus

**Every app must depend on `ImpressKeyboard`** and use `.keyboardGuarded` for character-key handlers. Currently wired in: imbib, imprint, implore, impel, impart.

**Do NOT put `.focusable()` on views that contain text editors.** A `.focusable()` wrapper on a parent view creates a SwiftUI focus target that can intercept key events before they reach an AppKit NSTextView (TextEditor, HelixTextView) inside. Even when `.keyboardGuarded` returns `.ignored`, the `.focusable()` wrapper may consume the event from the AppKit responder chain. Place `.focusable().keyboardGuarded` on the outermost container only (e.g., the detail view wrapping all tabs), not on individual child views containing text input. In imbib, `DetailView` handles h/l pane cycling for all tabs — individual tabs (NotesTab, InfoTab, BibTeXTab) must NOT have their own `.focusable()` wrappers.

### macOS Toolbar & Split View Layout

These rules apply to any impress app using `NavigationSplitView` with an inner `HSplitView` (e.g., imbib's list + detail split). The macOS toolbar system has undocumented limitations that cause hours of debugging.

**Toolbar item placement does NOT work as expected inside NavigationSplitView detail with HSplitView:**

| Placement | Expected | Actual |
|-----------|----------|--------|
| `.primaryAction` | Trailing edge | Clusters left, right after `.navigation` items |
| `.principal` | Center of detail column | Centers over full content area (at HSplitView divider) |
| `Spacer()` / `.frame(maxWidth: .infinity)` inside `ToolbarItem` | Expands item | Ignored — macOS toolbar sizes items to natural content |
| `.safeAreaInset(edge: .top)` on detail pane | Inline toolbar | Creates SECOND strip below window toolbar (double height) |
| Inline VStack toolbar in pane content | Toolbar in pane | Items render below window toolbar, wastes vertical space |

**The proven pattern (used in imbib, adopt in other apps):**

1. **Accept left-aligned toolbar items.** Put all toolbar items in `.toolbar { ToolbarItem(placement: .primaryAction) { } }`. They will cluster on the left. Don't fight this.
2. **Extend the detail pane upward.** Apply `.ignoresSafeArea(.container, edges: .top)` on the detail pane's container. This makes detail content fill the empty toolbar space above it, eliminating the dead gap.
3. **Add scroll clearance in detail content.** Each detail tab's first content element gets `.padding(.top, 40)` so content starts below the toolbar icons but can be scrolled up into that space.

```swift
// PATTERN: HSplitView detail pane in SectionContentView
HSplitView {
    ZStack { listPane }
        .frame(minWidth: 200, idealWidth: 300)

    ZStack { detailView }
        .frame(minWidth: 300)
        .ignoresSafeArea(.container, edges: .top)  // ← reclaim toolbar space
}
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        // detail items — will be on the left, that's OK
    }
}
```

**Do not** attempt to right-align, center, or reposition toolbar items within this layout. Every approach was tried and either failed silently or looked worse.

## Observability & Debugging

### Always Verify with Logs

When implementing new features or debugging issues, **use the live log infrastructure** to confirm behavior. Do not assume code works just because it compiled. All impress apps expose logs via HTTP and MCP.

### Shared Logging Infrastructure (`ImpressLogging`)

All apps share the `ImpressLogging` package (`packages/ImpressLogging/`). Use these APIs:

```swift
// In any service or view model — logs to both OSLog and in-app console
Logger.library.infoCapture("message", category: "tags")   // app-specific Logger
logInfo("message", category: "tags")                        // global convenience

// Performance timing
measureTime("rebuild row data", count: rows.count) { ... }
```

### Live Log Access

Each app runs a local HTTP server exposing `GET /api/logs`:

| App | Port | Endpoint |
|-----|------|----------|
| imbib | 23120 | `curl 'http://localhost:23120/api/logs?limit=20&level=info,warning,error'` |
| impart | 23122 | `curl 'http://localhost:23122/api/logs?limit=20'` |

Query parameters: `limit`, `offset`, `level` (comma-separated), `category`, `search`, `after` (ISO8601).

The MCP server (`impress-mcp`) also exposes `imbib_get_logs` and `impart_get_logs` tools for AI agent access.

### Three-Point Trace Pattern

When adding features that touch persistence (Core Data, UserDefaults, files), always add logging at three points:

1. **Mutation** — what was requested, with what parameters
2. **Save** — did the persistence layer see changes?
3. **Display** — did the UI layer read the data back?

```swift
Logger.library.infoCapture("Applying tag '\(tagPath)' to \(pubIDs.count) pubs", category: "tags")
// ... perform mutation ...
Logger.library.infoCapture("Save: context.hasChanges = \(context.hasChanges)", category: "tags")
// ... after rebuild ...
Logger.library.infoCapture("Display: \(taggedCount) rows now show tags", category: "tags")
```

### Debugging Workflow for Claude Code Sessions

1. **Build and launch** the app from the debug build
2. **Verify** the HTTP server is responding: `curl http://localhost:23120/api/status`
3. **Watch logs** while testing: `curl 'http://localhost:23120/api/logs?level=info,warning,error&limit=30'`
4. **Filter by category** to focus: `curl 'http://localhost:23120/api/logs?category=tags'`
5. **Use `after` timestamp** to see only new entries since last poll

If the HTTP server isn't responding, check:
- Settings > General > Automation: both "Enable Automation API" and "Enable HTTP server" must be on
- The `com.apple.security.network.server` entitlement must be in the app's `.entitlements` file

## App-Specific Guidance

See `apps/*/CLAUDE.md` for detailed app documentation:
- [imbib CLAUDE.md](apps/imbib/CLAUDE.md) - Bibliography manager specifics

## The North Star

A researcher should be able to:

> Wake up, open impress, read and annotate papers, respond to emails, write manuscript sections, explore and visualize data, run analyses, direct AI agents to handle routine tasks, and prepare submissions—all without leaving the environment, all with hands on keyboard, all in flow.

Build toward that.

---

*This document governs the design and development of the impress suite. All contributors—human and agent—should internalize these principles and apply them consistently.*
