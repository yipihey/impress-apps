# ADR-007: FAIR Alignment — RO-Crate Overlay and Typed Fields (imprint pointer)

## Status
Proposed — pointer to suite ADR-0014.

## Context
Suite-wide FAIR alignment is governed by [`docs/ADR-0014-fair-alignment.md`](../../../../docs/ADR-0014-fair-alignment.md). This pointer ADR records the imprint-local consequences.

## Decision

### Typed attribution fields (per ADR-0014 D54)
`CDDocumentReference` and `DocumentMetadata` gain five optional typed fields:

- `orcid: String?` (regex-validated)
- `affiliation: String?`
- `funder: String?`
- `license: String?` (SPDX id)
- `embargoUntil: Date?` (informational only)

`DocumentSchemaVersion` bumps from `v1_3 = 130` to `v1_4 = 140`. Core Data lightweight migration handles the schema delta — `shouldMigrateStoreAutomatically = true` was enabled in the prior bookmark-recovery work and remains in place.

### RO-Crate overlay (per ADR-0014 D55)
Every `.imprint` bundle written at schema version `v1_4` or later contains a top-level `ro-crate-metadata.json` conforming to RO-Crate 1.1. The overlay is a regenerated **view** of `metadata.json` plus `bibliography.bib`; it is not authoritative state.

- Read chokepoint: `ImprintDocument.init(configuration:)` (`apps/imprint/Shared/Models/ImprintDocument.swift` lines 86–201). On read, if the overlay is present and differs from `metadata.json` for the FAIR fields, the overlay's values win.
- Write chokepoint: `ImprintDocument.fileWrapper(configuration:)` (same file, lines 224–322). Overlay is regenerated on every save.
- Helper: new `apps/imprint/Shared/Services/ROCrateBuilder.swift`, pure function `buildROCrate(from doc: ImprintDocument) -> Data`.
- CRDT state (`document.crdt`) is independent and untouched.

### Figure provenance (per ADR-0014 D57)
`VeuszService.export()` (`apps/imprint/macOS/Services/VeuszService.swift` lines 106–144) writes `figures/{plot-id}.ro-crate.json` next to each rendered figure. `VeuszPlotRef` gains an optional `provenanceRelativePath: String?` field; old refs default to `nil`.

### Zenodo deposit DOI (per ADR-0014 D58)
`DocumentMetadata` gains an optional `publishedDOI: String?` field populated when a manuscript is deposited to a repository.

## Consequences

**Positive:** `.imprint` bundles become directly consumable by FAIR-tool pipelines (Galaxy, ARC, FAIR Data Point clients). Figures ship with auditable provenance. License / funder live as typed metadata, not freeform `metadata.json` blobs.

**Negative:** Two representations of the same metadata (`metadata.json` and `ro-crate-metadata.json`) must stay consistent. Mitigation: always regenerate the overlay from `metadata.json` on write; reconcile on read only when overlay disagrees on FAIR fields.

## Related
- Suite [ADR-0014](../../../../docs/ADR-0014-fair-alignment.md)
- imprint ADR-001 (CRDT document model — RO-Crate is independent of CRDT plumbing)
- imprint ADR-002 (Typst authoring format — RO-Crate sits beside the Typst source, not inside it)
- imprint ADR-006 (Sync architecture — CloudKit-synced documents carry their RO-Crate overlay through sync transparently because the bundle is a single file-wrapper)
