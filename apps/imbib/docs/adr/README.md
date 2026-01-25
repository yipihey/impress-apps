# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) documenting significant technical decisions for imbib.

## Index

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [001](001-core-data-over-swiftdata.md) | Core Data over SwiftData | Accepted | 2026-01-04 |
| [002](002-bibtex-source-of-truth.md) | BibTeX as Source of Truth | Accepted | 2026-01-04 |
| [003](003-plugin-architecture.md) | Hybrid Plugin Architecture | Accepted | 2026-01-04 |
| [004](004-human-readable-pdf-names.md) | Human-Readable PDF Filenames | Accepted | 2026-01-04 |
| [005](005-swiftui-frontend.md) | SwiftUI for Cross-Platform UI | Accepted | 2026-01-04 |
| [006](006-ios-file-handling.md) | iOS File Handling Strategy | Accepted | 2026-01-04 |
| [007](007-conflict-resolution.md) | Conflict Resolution Strategy | Accepted | 2026-01-04 |
| [008](008-api-key-management.md) | API Key Management | Accepted | 2026-01-04 |
| [009](009-deduplication-service.md) | Cross-Source Deduplication | Accepted | 2026-01-04 |
| [010](010-bibtex-parser-strategy.md) | BibTeX Parser Strategy | Accepted | 2026-01-04 |
| [011](011-console-window.md) | Console Window for Debugging | Accepted | 2026-01-04 |
| [012](012-unified-library-experience.md) | Unified Library Experience | Accepted | 2026-01-04 |
| [014](014-publication-enrichment.md) | Publication Enrichment | Accepted | 2026-01-05 |
| [015](015-pdf-settings.md) | PDF Settings | Accepted | 2026-01-06 |
| [016](016-imbib-safari-extension-adr.md) | Safari Extension | Accepted | 2026-01-11 |

## What is an ADR?

An Architecture Decision Record captures a significant architectural decision along with its context and consequences. We use ADRs to:

- Document why we made certain choices
- Help new contributors understand the codebase
- Provide context for AI-assisted development sessions
- Enable revisiting decisions when circumstances change

## ADR Template

```markdown
# ADR-NNN: Title

## Status

[Proposed | Accepted | Deprecated | Superseded by ADR-XXX]

## Date

YYYY-MM-DD

## Context

What is the issue that we're seeing that is motivating this decision?

## Decision

What is the change that we're proposing and/or doing?

## Rationale

Why is this the best choice among the alternatives?

## Consequences

What are the positive and negative results of this decision?

## Alternatives Considered

What other options were evaluated?
```

## Adding a New ADR

1. Create a new file: `NNN-short-title.md`
2. Use the next sequential number
3. Fill in the template
4. Add to the index in this README
5. Reference in `CLAUDE.md` if relevant to ongoing development

## Superseding an ADR

If a decision is revisited:

1. Update the original ADR status to `Superseded by ADR-XXX`
2. Create new ADR explaining the change
3. Reference the original ADR in the new one's context
