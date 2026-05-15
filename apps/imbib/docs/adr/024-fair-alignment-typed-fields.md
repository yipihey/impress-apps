# ADR-024: FAIR Alignment — Typed Attribution Fields (imbib pointer)

## Status
Proposed — pointer to suite ADR-0014.

## Date
2026-05-15

## Context
Suite-wide FAIR alignment is governed by [`docs/ADR-0014-fair-alignment.md`](../../../../docs/ADR-0014-fair-alignment.md). This pointer ADR records the imbib-local consequences.

## Decision
Per ADR-0014 D54, imbib adopts five typed optional fields on every `Publication` and `ResearchArtifact`:

- `orcid: String?` (regex-validated)
- `affiliation: String?` (freeform)
- `funder: String?` (freeform; Crossref Funder ID encouraged)
- `license: String?` (SPDX id)
- `embargoUntil: Date?` (informational only — no enforcement)

The Rust source of truth is `crates/impress-core/src/schemas/bibliography.rs::bibliography_entry_schema()` (bumps `1.0.0` → `1.1.0`) and `crates/impress-core/src/schemas/artifact.rs::artifact_fields()`. The Swift accessors live in `Publication.swift` and `ResearchArtifact.swift`. The detail-view UI grows a collapsed-by-default "Attribution" section in `InfoTab.swift` and `BibTeXTab.swift`.

Per ADR-0014 D56, `Publication.references` (currently `[UUID]?` flat array) migrates to `[TypedReference]`. Bare-UUID arrays continue to read; writes always emit typed.

Per ADR-0014 D58, `BibTeXEntry.fields["doi"]` is the DOI-write-back target for Zenodo deposits of papers. `ResearchArtifact` gains a `publishedDOI: String?` field for non-paper deposits.

## Consequences

**Positive:** imbib publications gain the GISAID-style attribution structure (license, ORCID, funder) that funders and journals expect. Typed cross-references replace bare UUID joins with no migration drama. Zenodo deposit puts a "publish to repository" verb on every paper.

**Negative:** The Info tab gains five new rows. We keep the Attribution section collapsed by default so existing reading flow is unchanged.

## Related
- Suite [ADR-0014](../../../../docs/ADR-0014-fair-alignment.md)
- ADR-002 (BibTeX as source of truth — license/funder also live in BibTeX-extensible custom fields when round-tripped)
- ADR-008 (API key management — Zenodo tokens reuse the existing `CredentialManager`)
