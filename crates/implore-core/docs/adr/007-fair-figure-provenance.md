# ADR-007: FAIR Alignment — Figure Provenance Sidecars (implore pointer)

## Status
Proposed — pointer to suite ADR-0014.

## Context
Suite-wide FAIR alignment is governed by [`docs/ADR-0014-fair-alignment.md`](../../../../docs/ADR-0014-fair-alignment.md). This pointer ADR records the implore-local consequences.

## Decision
Per ADR-0014 D57, every implore export emits a JSON-LD provenance sidecar next to the rendered file.

- `ExportMetadata` in `crates/implore-core/src/export.rs` (lines 233–284) gains:
    - `dataset_hash: Option<String>` — SHA-256 of the input dataset file at render time.
    - `parameters: BTreeMap<String, serde_json::Value>` — free-form keyed parameters (camera, axes, colormap, generator-specific knobs).
- New function `emit_provenance_sidecar(export_path: &Path, metadata: &ExportMetadata) -> std::io::Result<()>` writes `{stem}.ro-crate.json` next to the rendered figure file. JSON-LD payload `@type: CreativeWork` with `wasDerivedFrom` pointing at the dataset and `creator` software-tagged.
- Called from every export entry point in `export.rs` (PNG, PDF, SVG, EPS, Typst).

Per ADR-0014 D58, `DataProvenance.data_dois: Vec<String>` (already present in `crates/implore-core/src/dataset.rs` line 347) is the write-back target when a dataset is deposited to a repository via the new `DepositTarget` flow.

## Consequences

**Positive:** Every implore figure is reproducible — given the dataset (verifiable via hash), the software version, and the parameters, the figure can be regenerated. FAIR pipelines downstream of impress can ingest figures with their provenance intact.

**Negative:** SHA-256 hashing adds a small per-export cost (≪ render time). Acceptable.

## Related
- Suite [ADR-0014](../../../../docs/ADR-0014-fair-alignment.md)
- implore ADR-001 (Generator plugin architecture — sidecar emission is generator-agnostic, lives at the export layer)
- implore ADR-005 (FFI serialization — no FFI changes; sidecar is a host-side file emission)
- implore ADR-006 (Figure library — figure-library entries will carry sidecar paths once persisted)
