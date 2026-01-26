# impress

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-1.75+-orange.svg)](https://www.rust-lang.org/)

A suite of academic productivity apps built on a shared Rust foundation with native SwiftUI interfaces.

## Apps

| App | Description | Status |
|-----|-------------|--------|
| [**imbib**](apps/imbib/) | Reference manager with PDF annotation and BibTeX sync | Production |
| [**imprint**](apps/imprint/) | Collaborative academic writing with Typst rendering | Development |
| [**implore**](apps/implore/) | Scientific data visualization (HDF5, FITS, Parquet) | Development |
| [**impel**](apps/impel-tui/) | Agent orchestration for autonomous research workflows | Development |

## Architecture

The suite follows a layered architecture: shared Rust crates provide core logic, wrapped via UniFFI for consumption by native SwiftUI apps. All apps share Helix-style modal editing via ImpressModalEditing.

```
impress-apps/
├── crates/                       # 14 Rust libraries
│   │
│   ├── Foundation                # Shared across all apps
│   │   ├── impress-domain/       # Core types (Publication, Author, etc.)
│   │   ├── impress-bibtex/       # BibTeX parsing with round-trip fidelity
│   │   ├── impress-identifiers/  # DOI, arXiv, ISBN extraction
│   │   └── impress-collab/       # Collaboration and permissions
│   │
│   ├── imbib                     # Reference management
│   │   └── imbib-core/           # Library, search sources, PDF handling
│   │
│   ├── imprint                   # Collaborative writing
│   │   └── imprint-core/         # CRDT document engine, Typst rendering
│   │
│   ├── implore                   # Data visualization
│   │   ├── implore-core/         # Figure model, plugin system
│   │   ├── implore-stats/        # Statistical functions
│   │   ├── implore-io/           # HDF5, FITS, Parquet, CSV I/O
│   │   └── implore-selection/    # Selection grammar parser
│   │
│   └── impel                     # Agent orchestration
│       ├── impel-core/           # Thread DAG, event sourcing, 4-level hierarchy
│       ├── impel-helix/          # Modal editing for TUI
│       └── impel-server/         # HTTP/WebSocket API
│
├── apps/                         # Native applications
│   ├── imbib/                    # macOS/iOS reference manager
│   ├── imprint/                  # macOS collaborative editor
│   ├── implore/                  # macOS data visualization
│   └── impel-tui/                # Cross-platform terminal UI
│
└── packages/                     # Shared Swift packages
    ├── ImpressModalEditing/      # Helix-style editing for all apps
    └── ImpressTestKit/           # Shared test utilities
```

## Crates

### Foundation

**impress-domain** - Core domain types shared across all apps:
- `Publication`, `Author`, `Annotation`
- `Manuscript`, `Collection`, `Tag`
- `Library`, `LinkedFile`, `Identifiers`

**impress-bibtex** - BibTeX parsing and formatting:
- Nom-based parser with round-trip fidelity
- LaTeX special character decoding
- Journal macro expansion, BibDesk compatibility

**impress-identifiers** - Academic identifier handling:
- DOI, arXiv, ISBN extraction and validation
- Cite key generation, URL resolution

**impress-collab** - Collaboration infrastructure:
- Permission model (View, Comment, Edit, Share, Admin)
- Invitation system, presence tracking

### imprint-core

CRDT-based collaborative document engine:
- Automerge integration for conflict-free editing
- Multi-cursor selection support
- Source-to-PDF mapping for direct manipulation
- LaTeX-to-Typst conversion, Typst rendering

### implore

Scientific data visualization engine:
- **implore-core**: Figure model with declarative specifications
- **implore-stats**: Descriptive stats, distributions, correlation
- **implore-io**: HDF5, FITS, Parquet, CSV readers
- **implore-selection**: Grammar for data selection expressions

### impel-core

Agent orchestration for autonomous research workflows:
- **4-level hierarchy**: Project > Program > Thread > Event
- **Thread DAG**: Directed acyclic graph of conversation threads
- **Event sourcing**: Append-only event log with SQLite persistence
- **Temperature/attention model**: Priority-based agent scheduling
- **Stigmergic coordination**: Agents communicate via shared state

See [impel ADRs](crates/impel-core/docs/adr/) for architecture decisions.

## Building

### Rust Crates

```bash
# Check all crates
cargo check

# Run tests
cargo test

# Build impel TUI
cargo build -p impel-tui --release
```

### Swift Apps

Each app uses XcodeGen. Example for imbib:

```bash
cd apps/imbib/imbib
xcodegen generate
open imbib.xcodeproj
```

See individual app READMEs for detailed instructions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Documentation

- [imbib docs](apps/imbib/docs/) - User guides and 22 ADRs
- [impel ADRs](crates/impel-core/docs/adr/) - 9 architecture decisions

## License

[MIT](LICENSE)
