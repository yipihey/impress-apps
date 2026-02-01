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

## App-Specific Guidance

See `apps/*/CLAUDE.md` for detailed app documentation:
- [imbib CLAUDE.md](apps/imbib/CLAUDE.md) - Bibliography manager specifics

## The North Star

A researcher should be able to:

> Wake up, open impress, read and annotate papers, respond to emails, write manuscript sections, explore and visualize data, run analyses, direct AI agents to handle routine tasks, and prepare submissions—all without leaving the environment, all with hands on keyboard, all in flow.

Build toward that.

---

*This document governs the design and development of the impress suite. All contributors—human and agent—should internalize these principles and apply them consistently.*
