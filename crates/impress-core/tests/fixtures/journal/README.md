# Journal pipeline fixtures

Fixture set for Phase 0 of the impress journal pipeline (per `docs/plan-journal-pipeline.md` §7).

These fixtures exercise the four new schemas added in Phase 0:
- `manuscript@1.0.0` (`crates/impress-core/src/schemas/manuscript.rs`)
- `manuscript-revision@1.0.0` (`crates/impress-core/src/schemas/manuscript_revision.rs`)
- `manuscript-submission@1.0.0` (`crates/impress-core/src/schemas/manuscript_submission.rs`)
- `review@1.0.0` and `revision-note@1.0.0` (`crates/impress-core/src/schemas/knowledge_objects.rs`)

The JSON shape mirrors the on-the-wire format used by the submission HTTP API
(`POST /api/journal/submissions`) for submission fixtures, and the in-store
`Item.payload` shape for everything else. Tests should construct `Item`
records by populating the envelope fields plus `payload` from these JSONs.

| File | Purpose |
|---|---|
| `manuscript-empty.json` | Bare manuscript item, no revisions; status=draft |
| `manuscript-with-2-revisions.json` | Manuscript + revision-v1 + revision-submitted, with PDF blob hashes |
| `submission-new-manuscript.json` | A submission for a new manuscript |
| `submission-new-revision.json` | A submission targeting an existing manuscript |
| `submission-fragment.json` | A submission with high similarity to an existing manuscript |
| `review-counsel-approve-with-changes.json` | A review knowledge object authored by Counsel |
| `revision-note-artificer-propose.json` | A revision-note with diff |
| `transcript-jsonl-sample.jsonl` | Two .tex blocks in a synthetic Claude session for backfill CLI |

The blob SHA-256 strings used here are placeholders — they're 64-char hex
strings that match BlobStore's address format but do not correspond to real
blob content. Phase 1+ tests that exercise the round-trip with real bytes
will produce the actual hashes at runtime.
