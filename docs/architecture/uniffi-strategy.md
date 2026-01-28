# UniFFI Strategy for Impress Apps

This document explains the UniFFI architecture across the Impress monorepo, why code duplication exists in generated Swift bindings, and why it's an acceptable design tradeoff.

## Overview

Each app in the Impress suite has its own Rust core crate that exposes functionality to Swift via [UniFFI](https://mozilla.github.io/uniffi-rs/):

| App | Rust Crate | Swift Package | Generated Lines |
|-----|------------|---------------|-----------------|
| imbib | `imbib-core` | `ImbibRustCore` | ~12,800 |
| implore | `implore-core` | `ImploreRustCore` | ~6,200 |
| imprint | `imprint-core` | `ImprintRustCore` | ~3,000 |
| (shared) | `impress-llm` | `ImpressLLM` | ~2,500 |

## The "Duplication" Question

Each generated Swift file contains ~350-400 lines of identical boilerplate:

- `RustBuffer` allocation/deallocation (~36 lines)
- `FfiConverter` protocol and primitives (~150 lines)
- Reader/Writer functions (~65 lines)
- `UniffiInternalError` enum (~30 lines)
- `RustCallStatus` handling (~70 lines)
- `UniffiHandleMap` for objects (~40 lines)

**Total boilerplate: ~1,100 lines across all packages (5% of 22,000 total generated lines)**

## Why We Don't Consolidate

### 1. UniFFI's Design Is Intentional

All infrastructure code is generated as `fileprivate` to:

- **Avoid symbol collisions** when multiple bindings coexist in the same app
- **Ensure self-containment** - each binding is stable and independent
- **Prevent ABI compatibility issues** across crate boundaries

### 2. The Math Doesn't Justify It

- Boilerplate: ~1,100 lines (5%)
- Domain code: ~21,000 lines (95%)
- The effort to consolidate far exceeds the benefit

### 3. Consolidation Options Evaluated

| Option | Approach | Verdict |
|--------|----------|---------|
| Swift extraction | Create shared `UniffiSwiftSupport` package | Not feasible - FFI functions are crate-specific, symbols are `fileprivate` |
| Mega-crate | Merge all cores into single crate | Bad tradeoff - 3x build time, binary bloat, dependency conflicts |
| Custom codegen | Fork uniffi-bindgen-swift | Major effort, ongoing maintenance burden |
| **Status quo** | Keep current architecture | **Best option** - zero maintenance, clean separation |

## How Type Sharing Works

While infrastructure code is duplicated, **domain types are shared at the Rust level** using UniFFI's `external_packages` feature.

### Shared Crates

```
crates/
├── impress-domain/      # Shared types (Publication, Author, Annotation, etc.)
├── impress-bibtex/      # Shared BibTeX parsing
├── impress-identifiers/ # Shared DOI/arXiv/ISBN handling
├── impress-collab/      # Shared collaboration types
├── imbib-core/          # App-specific: publication management
├── imprint-core/        # App-specific: document editing
└── implore-core/        # App-specific: visualization
```

### Configuration via uniffi.toml

Each app-specific crate references shared crates:

```toml
# crates/imbib-core/uniffi.toml
[bindings.swift.external_packages.impress_domain]
crate_name = "impress_domain"

[bindings.swift.external_packages.impress_bibtex]
crate_name = "impress_bibtex"

[bindings.swift.external_packages.impress_identifiers]
crate_name = "impress_identifiers"
```

This ensures types like `Publication`, `Author`, and `BibTeXEntry` are defined once in Rust and generate compatible FFI converters in each Swift package.

## When to Add New Crates vs Extend Existing

### Add a new crate when:

- Functionality is specific to one app and doesn't need sharing
- You need different feature flags or dependencies
- Build time isolation is important

### Extend existing crates when:

- Adding functionality that multiple apps will use
- The new code fits naturally with existing types
- You want to avoid additional build complexity

### Add to shared crates (`impress-*`) when:

- Types or functionality are genuinely cross-app
- The code has no app-specific dependencies
- It represents core domain concepts

## Build Workflow

### Individual Crate Builds

Each crate has its own build script:

```bash
# Build imbib-core (macOS + iOS)
./crates/imbib-core/build-xcframework.sh

# Build imprint-core (macOS only)
./crates/imprint-core/build-xcframework.sh

# Build implore-core (macOS only)
./crates/implore-core/build-xcframework.sh

# Build impress-llm (macOS + iOS)
./crates/impress-llm/build-xcframework.sh
```

### Unified Build Script

For CI or full rebuilds, use the unified script:

```bash
# Build all xcframeworks
./scripts/build-xcframeworks.sh

# Build specific crates
./scripts/build-xcframeworks.sh imbib-core imprint-core

# Build with verbose output
./scripts/build-xcframeworks.sh --verbose
```

### What the Build Produces

For each crate, the build creates:

```
crates/<name>/frameworks/
├── <Name>Core.xcframework/     # Universal binary for Xcode
├── generated/                   # Raw UniFFI output
│   ├── <name>_core.swift       # Swift bindings
│   ├── <name>_coreFFI.h        # C header
│   └── <name>_coreFFI.modulemap
└── <name>_core.swift           # Copied for easy access
```

## Platform Support

| Crate | macOS | iOS | iOS Simulator |
|-------|-------|-----|---------------|
| imbib-core | arm64, x86_64 | arm64 | arm64, x86_64 |
| imprint-core | arm64, x86_64 | - | - |
| implore-core | arm64, x86_64 | - | - |
| impress-llm | arm64, x86_64 | arm64 | arm64, x86_64 |

iOS support can be added to imprint-core and implore-core when needed by updating their build scripts.

## When to Reconsider This Strategy

Revisit consolidation if:

1. **Adding 5+ more UniFFI-enabled crates** - At some point the overhead becomes noticeable
2. **UniFFI adds shared support module** - Upstream may eventually provide this
3. **Boilerplate grows to >20%** - Future UniFFI versions might add more infrastructure

## Summary

The current architecture is sound:

- **95% of generated code is unique domain logic**
- **5% boilerplate is auto-generated and maintenance-free**
- **Rust-level type sharing already works via `external_packages`**
- **Each binding is self-contained and stable**

The small amount of duplication is an acceptable cost for clean separation, independent builds, and UniFFI's guaranteed correctness.
