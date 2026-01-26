# impress

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-1.75+-orange.svg)](https://www.rust-lang.org/)

A suite of academic productivity apps built on a shared Rust foundation.

## Apps

| App | Description | Status |
|-----|-------------|--------|
| [**imbib**](apps/imbib/) | Reference manager with PDF annotation | Production |
| [**imprint**](apps/imprint/) | Collaborative academic writing (Typst) | Development |
| [**implore**](apps/implore/) | Data visualization | Development |
| [**impel**](apps/impel-tui/) | Agent orchestration TUI | Development |

## Architecture

```
impress-apps/
├── crates/                    # Shared Rust libraries
│   ├── Foundation
│   │   ├── impress-domain/    # Core types (Publication, Author, etc.)
│   │   ├── impress-bibtex/    # BibTeX parsing and formatting
│   │   ├── impress-identifiers/ # DOI, arXiv, ISBN extraction
│   │   └── impress-collab/    # Collaboration infrastructure
│   │
│   ├── App Cores
│   │   ├── imbib-core/        # Reference manager logic
│   │   ├── imprint-core/      # CRDT document engine
│   │   ├── implore-core/      # Visualization engine
│   │   ├── implore-stats/     # Statistical functions
│   │   ├── implore-io/        # Data I/O (HDF5, FITS, Parquet)
│   │   └── implore-selection/ # Selection grammar parser
│   │
│   └── Impel
│       ├── impel-core/        # Agent orchestration
│       ├── impel-helix/       # Modal editing
│       └── impel-server/      # HTTP/WebSocket API
│
├── apps/                      # Swift/SwiftUI applications
│   ├── imbib/                 # Reference manager
│   ├── imprint/               # Collaborative writing
│   ├── implore/               # Data visualization
│   └── impel-tui/             # Terminal UI for impel
│
└── packages/                  # Shared Swift packages
    ├── ImpressKit/            # UniFFI wrapper (planned)
    ├── ImpressModalEditing/   # Helix-style editing
    └── ImpressTestKit/        # Test utilities
```

## Crates

### impress-domain
Core domain types shared across all apps:
- `Publication`, `Author`, `Annotation`
- `Manuscript`, `Collection`, `Tag`
- `Library`, `LinkedFile`, `Identifiers`

### impress-bibtex
BibTeX parsing and formatting with round-trip fidelity:
- Nom-based parser
- LaTeX special character decoding
- Journal macro expansion
- BibDesk compatibility

### impress-identifiers
Academic identifier handling:
- DOI, arXiv, ISBN extraction and validation
- Cite key generation
- URL resolution

### impress-collab
Shared collaboration infrastructure:
- Permission model (View, Comment, Edit, Share, Admin)
- Invitation system (email, secure links)
- Presence tracking

### imprint-core
CRDT-based collaborative document engine:
- Automerge integration for conflict-free editing
- Multi-cursor selection support
- Source to PDF mapping for direct manipulation
- LaTeX to Typst conversion
- Typst rendering (optional feature)

## Building

### Rust Crates

```bash
# Check all crates
cargo check

# Run tests
cargo test

# Build with specific features
cargo build -p imprint-core --features typst-render
```

### Swift Apps

See individual app READMEs for build instructions. In general:

```bash
cd apps/imbib/imbib
xcodegen generate
open imbib.xcodeproj
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Documentation

- [imbib documentation](apps/imbib/docs/) - User guides and ADRs
- [impel ADRs](crates/impel-core/docs/adr/) - Architecture decisions

## License

[MIT](LICENSE)
