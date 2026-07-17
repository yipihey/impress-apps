# imbib Testing Strategy

imbib has three test surfaces today:

- `PublicationManagerCore` SwiftPM tests: the fastest no-human layer for parsers, search intent routing, source adapters, automation commands, drag/drop payload types, settings, enrichment, and Rust bridge behavior.
- `crates/imbib-core` Rust tests and Criterion benches: the source of truth for parser/search/storage algorithms and performance-sensitive Rust paths.
- `imbibUITests` XCUITests: useful for end-to-end smoke, but slower and more fragile because they launch the app and depend on macOS UI state.

The default regression gate for agent-led development should start at the no-human layers and only escalate to UI tests when a change touches real UI composition, keyboard focus, menus, or accessibility behavior.

## Autonomous Gate

Run the fast no-human gate from the repository root:

```bash
apps/imbib/scripts/autonomous-test.sh quick
```

This runs a focused SwiftPM subset covering:

- Cmd+F/Cmd+S typed search-action plumbing
- URL/automation command parsing and search dispatch
- search presenter behavior
- drag/drop model invariants
- a coarse BibTeX parser performance smoke

Run the full no-human gate before landing broad refactors:

```bash
apps/imbib/scripts/autonomous-test.sh full
```

`full` runs all `PublicationManagerCore` SwiftPM tests, Rust `imbib-core` tests with native features, and macOS/iOS Xcode builds without launching the app.

Useful targeted modes:

```bash
apps/imbib/scripts/autonomous-test.sh swift-core
apps/imbib/scripts/autonomous-test.sh rust-core
apps/imbib/scripts/autonomous-test.sh build
apps/imbib/scripts/autonomous-test.sh performance
```

The script writes per-step logs under `/tmp/imbib-autonomous-tests/<timestamp>` by default. Override with `IMBIB_AUTONOMOUS_LOG_DIR=/path/to/logs`.

## UI Tests

Use UI tests as a second-stage smoke when the change touches view focus, list selection, menu commands, toolbar commands, split view layout, or keyboard handling:

```bash
cd apps/imbib/imbib
./fast_test.sh basic
./fast_test.sh search
./fast_test.sh keyboard
```

These tests intentionally remain outside the default autonomous gate because they launch the app and can depend on local simulator/window/accessibility state.

## Performance Guardrails

The autonomous Swift performance test is intentionally loose. It should catch hangs, accidental quadratic behavior, and parser path regressions large enough to disrupt development. It is not a replacement for benchmark work.

For serious BibTeX parser benchmarking:

```bash
IMBIB_AUTONOMOUS_RUN_CARGO_BENCH=1 apps/imbib/scripts/autonomous-test.sh performance
cargo bench -p imbib-core --bench bibtex_benchmark
```

Treat benchmark numbers as trend data. Do not tune against a single laptop run.

## Adding New Autonomous Tests

Prefer new no-human coverage when a bug can be expressed as:

- a typed command or notification contract
- a parser/normalizer/source URL invariant
- a view model or presenter state transition
- a persistence adapter behavior using an in-memory or temporary store
- a drag/drop payload type round trip
- a performance smoke with a deliberately loose catastrophic-regression budget

Avoid app-launch tests unless the defect requires AppKit/SwiftUI focus, accessibility, actual keyboard routing, or real window lifecycle. When UI is required, keep the UI test as a smoke and add a lower-level unit test for the underlying contract.

## Current Gaps To Prioritize

- Add in-memory store fixtures for large-library Cmd+F filtering so search latency can be guarded without launching the app.
- Add offline source-client fixtures for ADS/SciX/OpenAlex/arXiv edge cases and URL parser round trips.
- Add presenter/view-model tests for smart-search creation and refresh scheduling so online-source search remains testable without the HTTP server.
- Add a dedicated keyboard-command registry contract test for every flagship shortcut, especially Cmd+F and Cmd+S.
- Add deterministic row-model rebuild tests for large publication lists to catch performance regressions before UI tests become necessary.
