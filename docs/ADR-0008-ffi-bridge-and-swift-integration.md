# ADR-0008: FFI Bridge and Swift Integration

**Status:** Accepted
**Date:** 2026-03-02
**Authors:** Tom (with Claude)
**Supersedes:** `docs/architecture/uniffi-strategy.md`
**Scope:** All Rust crates with `--features native`, all Swift app targets that consume them

---

## Context

The Impress suite is built on a Rust core — `impress-core` for shared primitives, and per-app crates (`imbib-core`, `imprint-core`, `implore-core`) for domain logic — paired with native Swift/AppKit UIs. The two languages must communicate without sacrificing the safety, performance, and correctness guarantees of either side.

### Why Rust at All

Rust provides:
- Safe, allocation-efficient data manipulation for large bibliographies, manuscript ASTs, and plot datasets
- A single implementation of BibTeX parsing, identifier extraction, PDF text extraction, FTS indexing, deduplication, and the unified item store, usable on both macOS and iOS without rewriting
- Fearless concurrency: the store's `Arc<Mutex<Connection>>` is sound across threads; Swift's concurrency model cannot enforce this on its own
- Long-term portability: the Rust core can be called from a CLI, a server, or a Linux port without changing the domain logic

### Alternatives Evaluated

| Option | Verdict |
|--------|---------|
| **Pure Swift** | Cannot share implementation between macOS and iOS without duplicate codebases; no mature SQLite FTS5 binding with the required performance profile; annotation and search algorithms would need full reimplementation |
| **C/cbindgen** | Manual, error-prone binding authoring; no automatic type marshaling; every Rust type crossing the boundary requires hand-written C structs and Swift wrappers |
| **C++/Swift interop** | Adds C++ to the build graph; Swift–C++ interop is still maturing and lacks the ergonomic code generation that UniFFI provides |
| **XPC service** | Appropriate for truly separate process isolation, but adds IPC latency that is unacceptable for synchronous store queries that run on every list scroll |
| **UniFFI (chosen)** | Procedural macros generate Swift bindings from Rust type annotations; the generated layer is safe, tested by Mozilla in Firefox, and covers the full type set (records, enums, interfaces, errors, async) |

### Why UniFFI over cbindgen

cbindgen generates C headers from Rust; the Swift side must then manually wrap every function. UniFFI generates a complete Swift module — types, protocols, async/await stubs, error enums — from the same annotations used to write the Rust code. The maintenance burden is on the annotation (`#[uniffi::export]`, `#[derive(uniffi::Record)]`), not on hand-maintained Swift wrappers.

### The Duplication Question

Each generated Swift file contains approximately 350–400 lines of identical UniFFI infrastructure:

- `RustBuffer` allocation/deallocation
- `FfiConverter` protocol and primitives
- Reader/Writer functions
- `UniffiInternalError` enum
- `RustCallStatus` handling
- `UniffiHandleMap` for objects

This boilerplate is `fileprivate` by design. UniFFI intentionally scopes all infrastructure to the file to prevent symbol collisions when multiple bindings coexist in the same process. Consolidating would require either a shared Swift package (not feasible — FFI function names are crate-specific) or forking `uniffi-bindgen-swift` (major maintenance burden). The boilerplate amounts to ~5% of generated code; 95% is unique domain logic. The status quo is the correct tradeoff.

### Domain-Type Sharing at the Rust Level

While Swift infrastructure code is per-crate, domain types are shared at the Rust level. `impress-core` defines the `Item`, `ItemStore`, `FieldMutation`, and schema primitives used by all per-app crates. `imbib-core` depends on `impress-core`; it does not redefine publications as a separate type family. Per-app `uniffi.toml` files reference the shared crates via `external_packages`, ensuring types like `Publication`, `Author`, and `BibTeXEntry` generate compatible FFI converters in each Swift package.

---

## Decision

### D29. UniFFI is the Rust-Swift Bridge

All Rust types that cross the FFI boundary are annotated with UniFFI proc macros:

```rust
// Value types: derive uniffi::Record
#[derive(Debug, Clone, uniffi::Record)]
pub struct BibliographyRow {
    pub id: String,
    pub cite_key: String,
    pub title: String,
    pub author_string: String,
    pub year: Option<i32>,
    pub is_read: bool,
    pub is_starred: bool,
    pub tags: Vec<TagDisplayRow>,
    // ...
}

// Object types (reference-counted, methods exported): derive uniffi::Object
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct ImbibStore {
    store: SqliteItemStore,
    registry: SchemaRegistry,
}

// Error types: derive uniffi::Error
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum StoreApiError {
    #[error("Not found: {0}")]
    NotFound(String),
    #[error("Storage error: {0}")]
    Storage(String),
    // ...
}

// Exported functions: #[uniffi::export]
#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, StoreApiError> { ... }

    pub fn list_libraries(&self) -> Result<Vec<LibraryRow>, StoreApiError> { ... }
}
```

The `native` feature flag gates all FFI annotations so that the same crate can be used in non-native contexts (wasm32, server) without the UniFFI scaffolding.

### D29a. ImbibStore is an Arc-wrapped Object, Not a Record

`ImbibStore` is a `uniffi::Object` (reference-counted, opaque handle). Swift receives an `ImbibStore` reference and calls methods on it; Rust retains ownership of the `SqliteItemStore` and its connection. This is correct: the SQLite connection must live as long as the store is in use, and `Arc<Mutex<Connection>>` provides thread-safe shared access without copying the entire database into Swift memory.

### D30. The RustStoreAdapter Pattern (Reference Implementation: imbib)

`RustStoreAdapter` is the Swift-side facade over the generated `ImbibStore` bindings. Every Swift app that has a Rust core implements this pattern. The imbib implementation at `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Persistence/RustStoreAdapter.swift` is the reference.

#### Structure

```swift
@MainActor
@Observable
public final class RustStoreAdapter {

    // MARK: - Singleton

    public static let shared: RustStoreAdapter = {
        do { return try RustStoreAdapter() }
        catch { fatalError("Failed to initialize RustStoreAdapter: \(error)") }
    }()

    // MARK: - Rust Store Handle

    /// The underlying Rust store. All mutations go through this.
    private let store: ImbibStore

    /// Thread-safe handle for background (non-main-actor) read-only FFI calls.
    /// ImbibStore uses Arc<Mutex<Connection>> internally, so concurrent reads are safe.
    /// nonisolated(unsafe) permits passing the value across actor boundaries;
    /// callers are responsible for not performing mutations off the main actor.
    public nonisolated(unsafe) let imbibStore: ImbibStore

    // MARK: - SwiftUI Invalidation

    /// Incremented by didMutate() on every mutation.
    /// SwiftUI views observe this via .onChange(of: store.dataVersion).
    public private(set) var dataVersion: Int = 0

    // MARK: - Batch Mutation State (suppresses intermediate invalidations)

    private var batchDepth: Int = 0
    private var batchHadStructural: Bool = false
    private var batchChangedFieldIDs: Set<UUID> = []
}
```

#### The Invalidation Protocol

Every method that mutates the store calls `didMutate()`. `didMutate()` does two things: bumps `dataVersion` (which SwiftUI observes) and posts a Darwin `NotificationCenter` notification (which other processes in the suite observe).

```swift
private func didMutate(structural: Bool = true) {
    dataVersion += 1
    if batchDepth > 0 {
        if structural { batchHadStructural = true }
        return  // notification deferred until endBatchMutation()
    }
    NotificationCenter.default.post(
        name: .storeDidMutate,
        object: nil,
        userInfo: ["structural": structural]
    )
}
```

The `structural` flag distinguishes two mutation classes:

- **Structural** (`structural: true`, default): items added, removed, or moved. The publication list must be fully reloaded. Example: `importBibTeX`, `deletePublications`, `movePublications`.
- **In-place field change** (`structural: false`): read state, star, flag, tag. Handled by O(1) row-level notifications (`readStatusDidChange`, `flagDidChange`, `starDidChange`, `tagDidChange`) posted with `userInfo["publicationIDs"]`. The list does not need to be reloaded; only the affected rows update. Example: `setRead`, `setStarred`, `setFlag`.

#### Batch Mutations

When multiple mutations must be applied atomically from the UI's perspective, wrap them in a `beginBatchMutation` / `endBatchMutation` pair:

```swift
store.beginBatchMutation()
defer { store.endBatchMutation() }
for id in selectedIDs {
    store.updateField(id: id, field: "note", value: newNote)
}
// One .storeDidMutate notification fires here, not N.
```

`endBatchMutation` posts a single coalesced `.storeDidMutate` and, if any field changes accumulated in `batchChangedFieldIDs`, a single coalesced `.fieldDidChange` notification summarizing all affected IDs.

#### Adding New Mutations

Adding a new operation to the adapter requires only:

1. Add the method to `RustStoreAdapter`, calling the generated `ImbibStore` method
2. Call `didMutate()` (or `didMutate(structural: false)` with a row-level notification for in-place changes)
3. Register undo info with `UndoCoordinator.shared.registerUndo(info:)` if applicable

The sidebar and list auto-update: `ImbibSidebarViewModel.refreshFromStore()` is called via `.onChange(of: store.dataVersion)` in `TabContentView`; `UnifiedPublicationListWrapper` observes `store.dataVersion` and reloads.

### D30a. Typed Swift Domain Structs

The generated `BibliographyRow`, `PublicationDetail`, `LibraryRow`, etc. are Rust-shaped structs — flat, string-typed, optimized for FFI transfer. Swift domain code does not use these types directly. Each app defines **typed domain structs** that wrap the generated types and expose typed computed properties:

```swift
// Domain struct — typed, Sendable, Hashable
public struct PublicationModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let citeKey: String
    public let entryType: String
    public let fields: [String: String]
    public let isRead: Bool
    public let isStarred: Bool
    public let flag: PublicationFlag?
    public let tags: [TagDisplayData]
    public let authors: [AuthorModel]
    public let linkedFiles: [LinkedFileModel]

    // Typed computed properties — no string-keyed access outside the initializer
    public var title: String { fields["title"] ?? "Untitled" }
    public var doi: String? { fields["doi"] }
    public var arxivID: String? { fields["arxiv_id"] }
    public var year: Int? { fields["year"].flatMap(Int.init) }

    // Initializer from generated Rust type
    public init(from detail: PublicationDetail) {
        self.id = UUID(uuidString: detail.id) ?? UUID()
        self.citeKey = detail.citeKey
        // ...
    }
}
```

The rule: **raw payload access (`fields["..."]`, optional string unwrapping) is only in adapter code and domain struct initializers.** Views, view models, and services receive typed domain structs. This prevents key-string bugs from propagating into view code and makes the Swift side of the codebase refactorable without touching FFI plumbing.

For list display, a separate `PublicationRowData` struct wraps `BibliographyRow` — a lighter Rust-shaped type pre-computed for display (all strings, all display-ready) — rather than the full detail. This keeps list-scroll allocations minimal.

### D30b. The nonisolated(unsafe) Background Read Pattern

`RustStoreAdapter.shared` is `@MainActor`. All mutations happen on the main actor. Reads that are too slow for the main thread (e.g., FTS queries across a large bibliography during a background enrichment pass) use the `nonisolated(unsafe)` handle:

```swift
// In RustStoreAdapter:
public nonisolated(unsafe) let imbibStore: ImbibStore

// In a background task (off the main actor):
let store = RustStoreAdapter.shared.imbibStore  // non-isolated access
let results = try store.fullTextSearch(query: query, parentId: nil, limit: 50)
```

`nonisolated(unsafe)` suppresses the compiler's isolation check. The safety guarantee is manual: `ImbibStore` wraps `SqliteItemStore`, which holds `Arc<Mutex<Connection>>`. Concurrent reads are safe because rusqlite's `Connection` behind a `Mutex` serializes access. **No mutations must be performed through this handle.** All writes go through the `@MainActor` methods on `RustStoreAdapter`.

### D31. Schema-Specific FTS Extractors

Each schema in `imbib-core` defines what text is indexed for full-text search. The shaped-queries module provides pre-computed `BibliographyRow` structs whose fields are ready for display and indexing. FTS queries are issued through `ImbibStore.fullTextSearch` which dispatches to the SQLite FTS5 virtual table maintained by `SqliteItemStore`. Schema accessors provide the `fts_text` extraction at insert time; Swift never manually constructs search documents.

### D29b. Per-App Adapter Instances

Each app that has a Rust core follows the same adapter pattern with its own generated types:

| App | Rust crate | Generated Swift module | Adapter class |
|-----|------------|------------------------|---------------|
| imbib | `imbib-core` | `ImbibRustCore` | `RustStoreAdapter` |
| imprint | `imprint-core` | `ImprintRustCore` | `ImprintStoreAdapter` (same pattern) |
| implore | `implore-core` | `ImploreRustCore` | (same pattern) |

Each adapter is a `@MainActor @Observable` singleton. The typed domain structs differ per app but the invalidation protocol (`dataVersion`, `didMutate`, `beginBatchMutation`/`endBatchMutation`) is identical.

### D29c. Store Initialization and StoreConfig

`ImbibStore.open(path:)` and `ImbibStore.openInMemory()` are the two constructors exposed via `#[uniffi::constructor]`. Internally they delegate to `SqliteItemStore::open_with_config` with a `StoreConfig` that carries:

- `author`: string identity of the local device/user (e.g., `"user:local"`) stamped on every operation item for provenance
- `author_kind`: `ActorKind::Human` for user-initiated operations, `ActorKind::System` for background services
- `tag_namespace`: namespace prefix for tag paths to prevent collisions in future multi-device scenarios

In `RustStoreAdapter`, initialization is:

```swift
private init() throws {
    let dbPath = Self.databasePath()
    let s = try ImbibStore.open(path: dbPath)
    self.store = s
    self.imbibStore = s  // same Arc reference, used for background reads
}
```

The database path is in `~/Library/Application Support/com.impress.imbib/imbib.sqlite`. On iOS it would be in the app's sandboxed application support directory. The in-memory constructor is available for tests:

```swift
// In test setup:
let adapter = try RustStoreAdapter(inMemory: true)
```

### Build and Update Procedure

The generated Swift bindings are **committed to the repository** alongside the Rust source. This means Xcode does not need a Rust toolchain installed to build the app; only CI and developers who modify Rust code need `cargo`.

When Rust code changes that affect the public API:

```bash
# 1. Build the crate and regenerate bindings
./crates/imbib-core/build-xcframework.sh

# 2. Copy the generated Swift bindings into the Swift package sources
cp crates/imbib-core/frameworks/imbib_core.swift \
   apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Generated/

# 3. Commit both the .xcframework and the new .swift file
git add crates/imbib-core/frameworks/ \
        apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Generated/
git commit -m "chore: regenerate imbib-core UniFFI bindings"
```

The build script (`build-xcframework.sh`) performs:
1. `cargo build --release --target <arch> --features native` for all target triples (macOS arm64, macOS x86\_64, iOS arm64, iOS Simulator arm64/x86\_64)
2. `lipo -create` to build universal binaries
3. `cargo run --bin uniffi-bindgen generate --language swift` to produce the Swift bindings and C header
4. `xcodebuild -create-xcframework` to package the universal binaries into an XCFramework

The resulting artifacts:

```
crates/imbib-core/frameworks/
├── ImbibCore.xcframework/    # Binary target for Xcode
├── generated/                # Raw uniffi-bindgen output
│   ├── imbib_core.swift      # Swift bindings (committed to Swift package)
│   ├── imbib_coreFFI.h       # C header
│   └── imbib_coreFFI.modulemap
└── imbib_core.swift          # Convenience copy
```

### Startup Safety Rule (CRITICAL)

Background services that call `RustStoreAdapter` mutations — `SmartSearchRefreshService`, `InboxScheduler`, `EnrichmentCoordinator` — **must not perform their first work cycle during the first 60–90 seconds of app launch**.

During startup, SwiftUI's body evaluation is settling. Any `.storeDidMutate` notification from a background service triggers `@Observable` invalidation, which schedules SwiftUI body re-evaluations that compound into a perpetual render loop (spinning beach ball). The diagnostic signal is:

```bash
log show --process imbib --last 15s | grep -c SHKSharingServicePicker
```

After 90 seconds of runtime, this count should be zero. Each `SHKSharingServicePicker` init corresponds to one body re-evaluation of the toolbar's two `ShareLink` views. A non-zero count after 90s indicates a background service is still firing mutations during SwiftUI startup settling.

The startup grace period is enforced as:

```swift
// CORRECT — single sleep with clean cancellation
try? await Task.sleep(for: .seconds(90))
await performFirstWorkCycle()

// WRONG — try? swallows CancellationError, loop becomes uncancellable
for _ in 0..<chunks {
    try? await Task.sleep(for: .seconds(5))  // never cancels
}
```

The `try?` pattern in a loop swallows `CancellationError`, making the Task uncancellable. Use a single `try? await Task.sleep` or check `Task.isCancelled` explicitly.

---

## Consequences

### Positive

- **Safety at the boundary.** UniFFI's generated converters handle memory ownership, error propagation, and optional unwrapping correctly. Hand-written C bridges have no such guarantee.
- **Type expressiveness.** Rust enums, structs, `Option<T>`, `Vec<T>`, and `Result<T, E>` all map to idiomatic Swift equivalents. The generated Swift API is natural to use.
- **Incremental adoption.** New Rust functionality is exposed by adding `#[uniffi::export]` and `#[derive(uniffi::Record)]` annotations — no manual bridging code required.
- **Independent builds.** Each crate has its own `build-xcframework.sh`. A change to `imbib-core` does not require rebuilding `imprint-core`. CI parallelizes across crates.
- **Background reads without actor hops.** The `nonisolated(unsafe)` pattern gives background tasks direct access to the store's read methods without marshaling through `@MainActor`. This is safe because `Arc<Mutex<Connection>>` serializes access in Rust; Swift just needs to avoid mutations off the main actor.
- **SwiftUI integration without polling.** `@Observable` + `dataVersion: Int` gives zero-overhead change detection: SwiftUI only re-evaluates views when `dataVersion` increments, which happens exactly once per logical mutation (or once per batch).

### Negative

- **Two languages to maintain.** Developers need working knowledge of both Rust and Swift. Type system differences (Rust's ownership vs. Swift's ARC) create conceptual overhead at the boundary.
- **Build time.** Rust compilation is slower than Swift for initial builds. Incremental builds are fast once the `.xcframework` is cached, but a full rebuild of `imbib-core` from source takes ~2 minutes.
- **Generated code is not editable.** The Swift bindings file is generated output. Any fix to the FFI layer must be made in Rust and the bindings regenerated. Developers must not hand-edit the generated Swift.
- **Binary size.** Each XCFramework includes the Rust standard library and all crate dependencies statically linked. The size is acceptable for desktop (a few MB per crate) but should be monitored for iOS.
- **UniFFI async.** UniFFI's async support requires the `uniffi-tokio` or `uniffi-async` features and a Tokio runtime. Current crates avoid async across the FFI boundary by performing Rust work synchronously and using Swift concurrency for the calling side. This is the correct tradeoff for the current usage patterns but limits exposing long-running Rust futures directly to Swift.
- **Startup sensitivity.** The `@Observable` invalidation chain means background services cannot safely write to the store during app startup. This is an operational constraint, not a design flaw, but it adds discipline requirements for every new background service.

---

## Open Questions

1. **UniFFI async across the boundary.** If Rust-side operations (e.g., network-fetching and parsing in a Rust background task) need to complete before returning to Swift, the current synchronous FFI model requires them to block the calling thread. Evaluate `uniffi-async` with a Tokio runtime for `impress-llm` where async Rust is already in use.

2. **Shared adapter for impress-core.** When impart and imbib both access the same SQLite database (the unified item store scenario from ADR-0001), there will be two `RustStoreAdapter` singletons writing to the same file. Evaluate whether a single shared adapter should be extracted into `ImpressKit`, or whether cross-app coordination via Darwin notifications (the current model for separate stores) is sufficient.

3. **iOS binary size.** The `imbib-core` XCFramework currently targets iOS for potential future use. Measure the binary size contribution on iOS and consider whether feature flags should be used to strip unused functionality (e.g., PDF extraction, ANN index) from the iOS slice.

4. **Undo/redo across the FFI.** `UndoInfo` carries `operation_ids` as `Vec<String>`. The Swift `UndoCoordinator` stores these IDs and calls a Rust `revert_operation(id:)` to undo. This path is implemented but not tested under concurrent mutation. Audit the undo stack behavior when batch mutations and background field changes interleave.

5. **Schema evolution and migration.** `SqliteItemStore` runs SQLite migrations at open time. As schemas evolve, the migration path must be tested with production database files before shipping. Document the migration protocol (version table, migration functions, rollback procedure) in a dedicated ADR.

6. **Codegen in CI.** Currently, developers regenerate bindings manually and commit them. A CI check that detects stale bindings (by re-running `uniffi-bindgen` and diffing) would prevent silent drift between Rust source and committed Swift bindings.

---

## References

- `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Persistence/RustStoreAdapter.swift` — reference implementation of the adapter pattern
- `crates/imbib-core/src/unified/store_api.rs` — `ImbibStore` UniFFI object with `#[uniffi::export]` methods
- `crates/imbib-core/src/unified/shaped_queries.rs` — `BibliographyRow`, `PublicationDetail`, `LibraryRow` UniFFI records
- `crates/impress-core/src/sqlite_store.rs` — `SqliteItemStore` with `StoreConfig`, `Arc<Mutex<Connection>>`, and operation-based mutations
- `crates/imbib-core/build-xcframework.sh` — per-crate build and binding generation script
- `docs/architecture/uniffi-strategy.md` — superseded; rationale for per-crate binding architecture and boilerplate duplication analysis
- ADR-0001 (Unified Item Architecture) — the `Item`, `ItemStore` trait, and schema system this bridge exposes
- ADR-0002 (Operations as Overlay Items) — operation-based mutation model, `UndoInfo`, `StoreConfig.author`
- [UniFFI documentation](https://mozilla.github.io/uniffi-rs/) — proc macro reference and binding generation guide
