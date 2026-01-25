# impress

A suite of academic productivity apps built on a shared Rust foundation.

## Apps

| App | Description | Status |
|-----|-------------|--------|
| **imbib** | Reference manager with PDF annotation | Production |
| **imprint** | Collaborative academic writing (Typst) | Development |
| *implore* | Data visualization | Planned |
| *implement* | Code development | Planned |

## Architecture

```
impress-apps/
├── crates/                    # Shared Rust libraries
│   ├── impress-domain/        # Core domain types (Publication, Author, etc.)
│   ├── impress-bibtex/        # BibTeX parsing and formatting
│   ├── impress-identifiers/   # DOI, arXiv, ISBN extraction
│   ├── impress-collab/        # Collaboration infrastructure
│   ├── imprint-core/          # imprint document engine
│   └── imbib-core/            # imbib-specific logic (TODO)
├── apps/                      # Swift/SwiftUI applications
│   ├── imbib/                 # Reference manager app
│   └── imprint/               # Collaborative writing app
└── packages/                  # Shared Swift packages
    └── ImpressKit/            # Swift wrappers for Rust crates
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
- Source ↔ PDF mapping for direct manipulation
- LaTeX ↔ Typst conversion
- Typst rendering (optional feature)

## Building

```bash
# Check all crates
cargo check

# Run tests
cargo test

# Build with Typst rendering
cargo build -p imprint-core --features typst-render
```

## License

MIT
