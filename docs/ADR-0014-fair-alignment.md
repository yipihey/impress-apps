# ADR-0014: FAIR Alignment

**Status:** Proposed
**Date:** 2026-05-15
**Authors:** Tom (with architectural exploration via Claude)
**Depends on:** ADR-0001 (Unified Item Architecture), ADR-0003 (Operations and Provenance), ADR-0004 (Schema Registry and Type System), ADR-0011 (impress Journal)
**Scope:** `crates/impress-core/src/schemas/`, `crates/impress-core/src/reference.rs`, `crates/implore-core/src/export.rs`, `apps/imbib/PublicationManagerCore/`, `apps/imprint/Shared/`, `apps/imprint/macOS/Services/`, new package `packages/ImpressDeposit/`

---

## Context

The FAIR principles (Findable, Accessible, Interoperable, Reusable) — particularly as framed by GISAID, with its emphasis on **mandatory attribution, rich metadata, persistent identifiers, indexed access, and balanced openness vs. contributor protection** — are increasingly the lingua franca of research-data sharing. Funders, journals, and institutional repositories expect FAIR-aligned outputs.

The impress suite is well-aligned on the local-first dimensions of FAIR:

- **Findable (locally):** Every primary item carries a UUID (per ADR-0001 D1) plus canonical external identifiers (DOI, arXiv, PMID, bibcode, OpenAlex, Semantic Scholar, DBLP). Cite keys are deterministic.
- **Accessible:** Data lives in known, user-owned paths. SQLite stores plus flat-file `.imprint` packages are walkable with standard tools. No mandatory cloud dependency.
- **Interoperable (academic-domain):** BibTeX is a first-class source of truth (ADR-0002 per imbib local ADRs); RIS is bidirectional; Typst manuscripts are plaintext-readable. HTTP automation API and the MCP server expose every item to agents and other tools.
- **Reusable:** `Operation` items (ADR-0003 D11) record every durable mutation with actor identity (D15), intent (D17), and HLC ordering (D14), making the suite already auditable in a way most reference managers are not.

It is **less aligned** on the global / community-interop dimensions of FAIR:

1. **Attribution is loose.** Author names are stored as freeform strings. ORCID, affiliation (ROR), funder (Crossref Funder ID), license (SPDX), and embargo are not modeled as typed fields on any object. GISAID makes attribution structural and mandatory; impress treats it as freeform string content.
2. **`.imprint` packages are not FAIR-tool-discoverable.** A `.imprint` bundle is well-formed for impress and for a human with a text editor, but a generic FAIR pipeline (Galaxy, ARC, FAIR Data Point clients) can't parse it without a wrapper.
3. **Cross-object links are bare UUIDs.** `crates/impress-core/src/reference.rs` defines a rich `TypedReference` struct with an `EdgeType` enum (19 standard variants — `Cites`, `References`, `Supersedes`, `Contains`, `HasVersion`, `Attaches`, `RelatesTo`, and more) — but most cross-object joins today are still bare UUID arrays. The infrastructure exists; adoption hasn't happened.
4. **Figures lack provenance metadata.** A rendered PNG/SVG/PDF in implore or imprint has no machine-readable record of the input dataset, render code, or parameters.
5. **No path to global findability.** A researcher cannot publish an artifact from inside the suite to a repository (Zenodo, OSF) that would mint a DOI. The system is FAIR-for-one.

### Forces

1. **Don't break local-first.** Any change must be additive. Adoption of new fields is opt-in. A user who never touches the new fields has byte-identical artifacts.
2. **Don't bypass the operation log.** All mutations to the new fields produce `Operation` items (ADR-0003 D11). FAIR alignment integrates with provenance, it doesn't bolt on parallel state.
3. **Don't fork the schema registry.** New schemas and new fields use ADR-0004 D16 (Rust code) and D18 (additive-only evolution). The schema version bumps cleanly.
4. **Don't bloat cross-app DTOs.** `ImpressKit/DataModels/*` are drag-drop wire formats. They stay lightweight. FAIR metadata lives on the source-of-truth items, not on every transient reference.
5. **Honor contributor protection.** GISAID balances openness with embargo and attribution. impress respects that with an informational `embargoUntil` field (no enforcement) and a deliberate "share to Zenodo" flow rather than auto-publishing.

---

## Decisions

### D54. FAIR Attribution Fields Are Typed Schema Fields, Not BibTeX Freeform

Five fields are added to the bibliography, document-reference, and research-artifact schemas — typed, optional, additive (per ADR-0004 D18):

| Field | Type | Format | Validation |
|---|---|---|---|
| `orcid` | optional string | `0000-0000-0000-0000` | Regex on write; no API lookup |
| `affiliation` | optional string | freeform | none initially; ROR suggested |
| `funder` | optional string | freeform | none initially; Crossref Funder ID accepted later |
| `license` | optional string | SPDX id, e.g. `CC-BY-4.0` | small dropdown in UI; freeform persisted |
| `embargoUntil` | optional date | ISO 8601 | none |

Concretely:

- `crates/impress-core/src/schemas/bibliography.rs::bibliography_entry_schema()` (currently `1.0.0`) → bumps to `1.1.0`, gains five `optional_string()` / `optional_date()` field defs. Per ADR-0004 D18, this is purely additive — `1.0.0` consumers see the new columns as null.
- `crates/impress-core/src/schemas/artifact.rs::artifact_fields()` gains the same five fields.
- `apps/imprint/Shared/Persistence/ManagedObjects.swift::CDDocumentReference` gains five `@NSManaged` attributes. Core Data lightweight migration handles the schema bump (the persistent-store description already has `shouldMigrateStoreAutomatically = true` after the recent bookmark-recovery work).
- `apps/imprint/Shared/Models/ImprintDocument.swift::DocumentMetadata` also gains the five fields (manuscripts carry license/funder independent of the papers they cite). `DocumentSchemaVersion` bumps from `v1_3 = 130` to `v1_4 = 140`.

Author names continue to live in their existing BibTeX `author` field. `orcid` / `affiliation` are stored at the **item** level, not the **author** level — modeling per-author ORCID-tagged authorship is deferred until we model authors as items (a future ADR). The pragmatic case ("this paper's primary author has this ORCID") is covered.

`embargoUntil` is **informational only**. UI surfaces it. Export emits it. No code path is gated by it. This matches GISAID's framing (embargo as a courtesy contract among contributors, not a runtime guard) without committing impress to enforce policies that vary per institution.

`ImpressKit/DataModels/*` (the drag-drop DTOs `ImpressPaperRef`, `ImpressDocumentRef`, `ImpressVeuszPlotRef`, `ImpressResearchArtifactRef`) **do not** gain these fields. They stay lightweight. Recipients dereference by `id` to fetch the full FAIR-bearing item.

### D55. `.imprint` Packages Emit an `ro-crate-metadata.json` Overlay

The `.imprint` bundle gains a new top-level file at `ro-crate-metadata.json` conforming to RO-Crate 1.1 (`https://w3id.org/ro/crate/1.1/context`). The package thereby becomes a valid RO-Crate, discoverable by every tool that consumes RO-Crates.

The overlay is a **view** of the document's data, not a source of truth. The canonical state remains:
- `metadata.json` for impress-shaped metadata
- `bibliography.bib` for citations
- `main.typ` / `figures/` for content

The overlay is regenerated on every save. On read, if `ro-crate-metadata.json` is present and parses successfully **and** the FAIR fields in it differ from `metadata.json`, the overlay's values for license / funder / orcid / affiliation / embargoUntil are preferred (treating an external editor's RO-Crate-aware mutation as authoritative). Otherwise the overlay is regenerated from `metadata.json`.

The overlay structure:
- A `@graph` root entity (`./`) of type `Dataset` describing the manuscript with `name`, `description`, `datePublished` (= `modifiedAt`), `license`, `funder`, `author` (array of `Person`, each with `@id` = ORCID URL if set, else a blank-node `_:auth-<index>`).
- Per figure: a `CreativeWork` entry with `@id` = `figures/{id}.{ext}`, `isPartOf` pointing at root.
- Per cited paper (drawn from `bibliography.bib`): a `ScholarlyArticle` stub with `@id` = `https://doi.org/...` and a `cites` relation from root.

Schema-versioning the overlay format is unnecessary — RO-Crate has its own `conformsTo` mechanism. `DocumentSchemaVersion.v1_4` instead signals "this `.imprint` bundle is *expected to contain* an `ro-crate-metadata.json` file." Older bundles without the file remain readable indefinitely.

CRDT state (`document.crdt`) is independent and untouched.

### D56. Typed Cross-Object Links Are the Default; Bare UUIDs Are Read-Compatibility

`crates/impress-core/src/reference.rs::TypedReference` (with the 19-variant `EdgeType` enum) is promoted from "available but unused" to "the canonical link representation." Three migration targets:

1. **`citation-usage` records** (`crates/impress-core/src/schemas/citation_usage.rs`) currently store `section_id` / `document_id` / `paper_id` as bare strings. They are wrapped into a `TypedReference` with `edge_type: Cites` and the existing context flowed into `metadata`.

2. **imprint folder membership** (`CDDocumentReference.folder` relationship) currently has no typed semantics. A new optional `edgeType: String?` attribute (default `"Contains"`) admits `"Contains"` / `"Cites"` / `"Supersedes"` / `"DerivedFrom"`. UI doesn't yet expose this richer set; the storage capacity does.

3. **`Publication.references`** (currently `[UUID]?` flat array on a publication item) migrates to `[TypedReference]`. On read, if the value is a bare-UUID array (legacy format), each element is rehydrated into a `TypedReference { target, edge_type: Cites, metadata: None }`. On write, always `TypedReference`.

A new schema `typed-link@1.0.0` is registered to make standalone link items expressible (when a link itself carries operations — see ADR-0003 D11 — for example "this Supersedes relation was added by user X on date Y because Z"). Links between two items can either be embedded in either endpoint's references field, or stand alone as their own schema items. The standalone form is required when the link carries provenance.

Adopting `TypedReference` is **incremental**. A bare-UUID array is always readable. A typed array is always preferred when written. There is no flag-day migration.

Public Swift API on `RustStoreAdapter` (new):
- `addTypedLink(from: UUID, to: UUID, edgeType: EdgeType, metadata: [String: Any]?) async throws`
- `removeTypedLink(from: UUID, to: UUID, edgeType: EdgeType) async throws`
- `typedLinks(from: UUID, edgeType: EdgeType?) async -> [TypedReference]`

UI exposure: imbib's Info tab grows a "Related papers" sub-section that lets the user assign an `EdgeType` to a chosen target. Most users never touch it; the schema admits it.

### D57. Every Rendered Figure Ships a JSON-LD Provenance Sidecar

For both implore exports and Veusz renders inside `.imprint` bundles, every output file is accompanied by a sibling `{stem}.ro-crate.json` recording:

- Source: dataset name + SHA-256 hash (for implore) or `.vsz` source path (for Veusz).
- Render code: software version (`software_version` already in `crates/implore-core/src/export.rs::ExportMetadata`) + Veusz version queried at render time.
- Parameters: free-form keyed `parameters: BTreeMap<String, Value>` for view-state-equivalents (camera, axes, colormap) and exposed knobs.
- Timestamp.

The sidecar is JSON-LD with `@type: CreativeWork` and `wasDerivedFrom` pointing at the dataset (or the `.vsz` source). It is itself a tiny RO-Crate-compatible fragment, so a `.imprint` bundle's top-level `ro-crate-metadata.json` (D55) can reference each figure-sidecar without restating its contents.

`ExportMetadata` (lines 233–284 of `export.rs`) gains:
- `dataset_hash: Option<String>` — SHA-256 of the input file at render time.
- `parameters: BTreeMap<String, Value>` — free-form keyed parameters.

New function `emit_provenance_sidecar(export_path: &Path, metadata: &ExportMetadata) -> io::Result<()>` writes the sidecar next to the rendered file. Called from every implore export entry point.

In imprint, `VeuszService.export()` (`apps/imprint/macOS/Services/VeuszService.swift` lines 106–144) writes `figures/{plot-id}.ro-crate.json` after the Veusz CLI finishes. A new optional `provenanceRelativePath: String?` on `VeuszPlotRef` tracks the sidecar location so the Typst manuscript can `@id` it from the overlay (D55).

### D58. "Publish This Artifact" Is a `DepositTarget` Protocol, Zenodo First

A new Swift package `packages/ImpressDeposit/` introduces the `DepositTarget` protocol, parallel in shape to `SourcePlugin` (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/SourcePlugin.swift` lines 10–60):

```swift
public protocol DepositTarget: Sendable {
    var id: String { get }
    var displayName: String { get }
    var credentialRequirement: CredentialRequirement { get }
    var rateLimit: RateLimit { get }
    func deposit(
        artifact: DepositArtifact,
        progress: @Sendable (UploadProgress) async -> Void
    ) async throws -> DepositResult
}
```

`DepositResult` carries `doi: String`, `repositoryURL: URL`, `recordID: String`.

The first concrete conformer is `ZenodoDepositTarget`. It implements the three-call workflow against `https://zenodo.org/api/` (with a Settings toggle to switch to `sandbox.zenodo.org` for testing):

1. `POST /api/deposit/depositions` — create a deposition (returns id, bucket URL).
2. `PUT {bucket}/{filename}` — upload the file (Zenodo's bucket API supports `PUT` with streaming, simpler than multipart).
3. `POST /api/deposit/depositions/:id/actions/publish` — finalize, mint DOI.

A new helper `packages/ImpressDeposit/Sources/ImpressDeposit/MultipartUpload.swift` provides a `URLSessionUploadTask`-backed helper with delegate-driven progress for large files. Reuses the existing `MIMEEncoder` from imbib for boundary handling when multipart is needed.

Zenodo credentials live in the existing `CredentialManager` (`apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Credentials/CredentialManager.swift`) — adding `zenodo` (and later `osf`) to its source-credentials list. The existing Settings panel (`apps/imbib/imbib/imbib/Views/Settings/SettingsView.swift::SourcesSettingsTab()` lines 406–505) renders the new rows without restructuring.

DOI write-back on success:

- For papers: `BibTeXEntry.fields["doi"]` (round-trips through `rawBibTeX`).
- For datasets: `DataProvenance.data_dois` in `crates/implore-core/src/dataset.rs` line 347 (the field exists; we now populate it).
- For imprint manuscripts: new field `publishedDOI: String?` on `DocumentMetadata` (added in Phase 1's expansion per D54 plus this DOI-specific extension).
- For artifacts: new field `publishedDOI: String?` on `ResearchArtifact`.

The deposit operation produces an `Operation` item in the provenance stream (ADR-0003 D11), with `intent: OperationIntent::ExternalPublish` and a `metadata.deposit_target` field. This means "when was this paper published to Zenodo, by which user, with what license?" is answerable from the operation log.

OSF support is deferred — the protocol is designed to admit it, and adding it is a localized change that does not require a follow-on ADR unless OSF's API forces a protocol shape change.

---

## Consequences

### Positive

1. **FAIR alignment in the standard sense.** Every primary item now carries the attribution metadata that funders / journals / repositories expect, in typed form. RO-Crate-aware tooling can ingest `.imprint` bundles directly. Figure provenance is machine-readable.
2. **Zero migration drama.** All additions are additive per ADR-0004 D18. Legacy stores read unchanged. New fields default to null.
3. **Typed-link adoption is free.** The infrastructure already exists in `crates/impress-core/src/reference.rs`. D56 is mostly about exercising existing capacity.
4. **Deposit completes the lifecycle.** A researcher can now go from "I imported a paper" to "I published a new manuscript with a DOI" without leaving impress.
5. **Operation log captures FAIR mutations.** Setting an ORCID, signing a license, depositing to Zenodo all become operation items, queryable by `effective_state(item, as_of)` per ADR-0003.

### Negative

1. **More schema surface.** The bibliography / artifact / document schemas grow by five fields each. Migrations of any kind always carry residual risk.
2. **UI inflation.** Three primary detail views grow an "Attribution" section. We must keep it collapsed by default to avoid clutter.
3. **External dependency exposure.** Zenodo deposit is a new outbound HTTP path. Network errors, token expirations, and rate-limits become a UX concern.
4. **RO-Crate overlay maintenance.** Two representations of the same metadata (`metadata.json` and `ro-crate-metadata.json`) must stay consistent. This is mitigated by always regenerating the overlay from `metadata.json` on write, but external editors that mutate the overlay create a reconciliation case.

### Mitigations

- A round-trip test for every `.imprint` schema version: open → save → diff. Catches RO-Crate drift.
- Zenodo deposit operations run in the background with explicit progress; the UI never blocks on them.
- New fields default to nil; existing flows continue to work without any user action.

---

## Open Questions

1. **Per-author ORCID modeling.** Storing `orcid` at item level handles the single-author case. Multi-author papers with per-author ORCIDs need authors-as-items. Deferred.
2. **Embargo enforcement.** Current decision: informational only. If we ever add an "auto-publish" or "auto-share" command, we'll revisit whether `embargoUntil` should gate it.
3. **OSF API specifics.** Building Zenodo first; protocol shape may need a follow-on adjustment.
4. **Schema-as-items (ADR-0004 D19, Phase 4).** Once schemas live in the graph, the FAIR overlay (D55) could itself be a schema-driven serializer rather than hand-rolled JSON-LD.

---

## References

- FAIR Guiding Principles, Wilkinson et al., *Scientific Data* (2016).
- GISAID FAIR Principles: `https://gisaid.org/help/fair-principles/`.
- RO-Crate 1.1 specification: `https://www.researchobject.org/ro-crate/1.1/`.
- CARE Principles for Indigenous Data Governance.
- FAIR Digital Objects (FDO): `https://fairdigitalobjects.eu/`.
- Zenodo REST API: `https://developers.zenodo.org/`.
- ORCID: `https://orcid.org/`.
- SPDX license list: `https://spdx.org/licenses/`.
- ROR (Research Organization Registry): `https://ror.org/`.
- Crossref Funder Registry: `https://www.crossref.org/services/funder-registry/`.
- impress ADR-0001 (Unified Item Architecture).
- impress ADR-0003 (Operations and Provenance).
- impress ADR-0004 (Schema Registry and Type System).
- impress ADR-0011 (impress Journal).
