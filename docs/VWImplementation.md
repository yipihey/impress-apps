# VW Expert-System Implementation

**Implemented:** 2026-08-05  
**Product state:** runnable MCP-first vertical slice with a searchable,
provenance-pinned source corpus; no OCR-derived mechanical claims have been
published as executable knowledge

## What is present

| Layer | Crate/module | Responsibility |
|---|---|---|
| Reusable source kernel | impress-core::source | Normalized regions, positioned text observations, source locators, citations, extraction runs, chunks, hash validation |
| Reusable source service | impress-store-service::source_service | Immutable, idempotent citation/extraction/chunk persistence and bounded full-text retrieval |
| Native OCR adapter | ImpressOCR | Resumable PDF page rendering, Apple Vision text/document recognition, confidence and geometry capture, portable SQLite index |
| Domain | vw-domain | Configuration applicability, evidence, procedures, sessions, pack validation, deterministic inference |
| Persistence adapter | vw-impress-adapter | VW schemas, item/edge mapping, queryable child evidence, command receipts, pack activation |
| Semantic contract | vw-service | Generated typed diagnostic operations |
| Reusable focused MCP host | impress-mcp-host | Inventory-backed stdio MCP, resources, product allowlists |
| Product binary | vw-mcp | VW-only service assembly and safety resources |
| Connected mobile web | impress-ai-http + impel-taskd | Existing authenticated responsive chat, phone pairing, durable conversations, local oMLX execution, and a read-only VW tool policy |

The existing suite-wide impress-mcp also force-links the VW adapter and groups
its long-tail methods into the vw domain.

## Run

From the repository root:

    cargo run -p vw-mcp -- \
      --store-path .local/vw-knowledge.sqlite

Load a reviewed pack:

    cargo run -p vw-mcp -- \
      --store-path /absolute/path/to/vw-impress.sqlite \
      --knowledge-pack knowledge/vw/your-reviewed-pack.json

Add --curation only for an administrative client that must write immutable
source citations, extraction runs, and content chunks. The normal diagnostic
profile exposes citation reads but not provenance writes.

## Semantic tools

- vw-diagnostic-service_get-capabilities
- vw-diagnostic-service_create-session
- vw-diagnostic-service_get-session
- vw-diagnostic-service_list-sessions
- vw-diagnostic-service_record-observation
- vw-diagnostic-service_record-measurement
- vw-diagnostic-service_evaluate-session
- vw-diagnostic-service_recommend-next-test
- vw-diagnostic-service_list-applicable-procedures
- vw-diagnostic-service_start-procedure
- vw-diagnostic-service_record-procedure-step
- vw-diagnostic-service_close-session
- source-service_get-citation
- source-service_get-content-chunk
- source-service_search-content-chunks

Every mutation takes a caller-generated UUID command_id. Session mutations
also take expected_revision. A repeated command returns its original session
snapshot; a stale revision returns structured expected/actual values.

## Example create-session arguments

The generated MCP tool takes one request object:

    {
      "request": {
        "command_id": "90c7cf6c-2821-41f6-a50b-202a8cf72c02",
        "vehicle_name": "1978 Type 2",
        "vin": null,
        "configuration": {
          "id": "3793c8f2-fb54-4ad6-8d88-d011bcce52e2",
          "model_family": "Type 2",
          "model_year": 1978,
          "market": "california",
          "emissions_spec": "California",
          "engine_code": "GE",
          "fuel_system": "L-Jetronic",
          "transmission": "manual",
          "installed_options": [],
          "installed_components": [],
          "deviations": [],
          "verification": "partially_verified"
        },
        "concern": "Engine does not start",
        "odometer": null,
        "notes": null
      }
    }

## Knowledge admission

A pack is rejected unless:

- its IDs are unique and its manifest hashes are well formed;
- published hypotheses, procedures, and rules carry citation IDs;
- every published procedure step is cited;
- published rule targets are themselves published;
- every citation UUID resolves to a valid source-citation@1.0.0 item;
- citation bytes, quote hashes, locators, and extraction lineage validate;
- an existing pack ID/version has identical immutable content.

The bootstrap pack in [knowledge/vw/bootstrap-pack.json](../knowledge/vw/bootstrap-pack.json)
contains zero mechanical claims. Synthetic rules exist only in tests.

## Searchable source corpus

The local, git-ignored `.local/vw-knowledge.sqlite` currently contains:

| Source | Searchable pages | Source item |
|---|---:|---|
| Volkswagen Official Service Manual: Station Wagon/Bus 1968-1979 | 485 | `fa503a5f-1b7a-5855-af11-480ef231883e` |
| Bosch Classic L-Jetronic Gasoline Injection System | 1 | `ba0f6a19-1692-596e-95e8-4331e30ed537` |
| Volkswagen AFC Training and Troubleshooting Manual | 45 | `4fbf4067-b1f5-53f0-b07a-cf34f5a1b228` |

Each nonblank page is represented by a full-text-indexed `content-chunk`, an
immutable `source-citation`, and an `extraction-run` pinned to the source PDF
SHA-256 and exact extraction profile. Search returns a bounded excerpt,
citation UUID, PDF page index/label, section hints, and extraction lineage. Use
`source-service_get-content-chunk` to load one selected page's complete OCR
text and positioned line observations, and `source-service_get-citation` to
resolve its immutable source locator.

The reproducible source catalog is
[knowledge/vw/sources.json](../knowledge/vw/sources.json). The PDFs and database
remain local and are excluded from git for copyright and size reasons.

### OCR status

`packages/ImpressOCR` now provides the Mac-native path. It renders PDF pages
with PDFKit, recognizes them on-device with Apple Vision, checkpoints one JSON
result per page, and builds a portable SQLite/FTS index. The default
line-oriented mode retains confidence and normalized geometry; the optional
document mode can additionally report paragraph, table, and list counts.

The canonical local database was rebuilt from Apple Vision text revision 3:

| Source | Pages processed | Blank | Mean line confidence | Retained line regions |
|---|---:|---:|---:|---:|
| Official service manual | 492 | 7 | 97.46 | 37,185 |
| Bosch L-Jetronic training aid | 1 | 0 | 100.00 | 36 |
| VW AFC troubleshooting manual | 46 | 1 | 94.25 | 1,941 |

The previous Tesseract database is retained locally as
`.local/vw-knowledge-tesseract.sqlite` for comparison and fallback. Ocean-OCR
remains a possible non-Apple adapter, but its published runtime requires CUDA
and a much larger model download; it is no longer needed for the native Mac
ingestion path. Extraction records name the engine actually used, so changing
OCR providers never changes the domain model or MCP contract.

## Deliberate limits

- The corpus is admitted as `extracted_unreviewed`; OCR output is searchable
  evidence, not trusted mechanical knowledge or an instruction to perform work.
- OCR section hints contain occasional recognition noise. Human review must
  create bounded quotes and applicability-scoped records before publication.
- The native OCR package is a library plus CLI. Scheduling it through the
  durable Impress task worker and adding non-Apple adapters remain follow-on
  work.
- The service process serializes mutations and the domain checks revisions;
  cross-process compare-and-swap remains a store-kernel improvement.
- Knowledge packs are activated explicitly at server startup. Stored sessions
  stay pinned and report a mismatch if a different pack is active.
- The connected `/vw` phone interface is implemented by reusing Impress AI.
  Service-worker caching and offline browser synchronization remain deferred.

## Verification

The focused test suites cover source validation, pack validation, applicability,
three-valued inference, stable trace hashes, stale revisions, hazard gates,
queryable child evidence, command replay, schema-manifest parity, MCP profile
allowlisting, resources, and a real stdio server call.
