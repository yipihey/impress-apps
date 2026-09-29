# Verb effects: what each verb touches, as declared and as observed

**Decided by:** ADR-0036 D1 (effects declared on the one descriptor, verified by a store spy,
never derived from code), plan-self-reflective-layer.md § Effects and appendix A (the static
walk that seeded the declarations), D-G4 (this file as a marker table).
**Executed by:** plan-self-reflective-layer.md E1 (declarations, this table, the spy's Tier A run).
**Enforced by:** `crates/impress-capabilities/tests/effects.rs` — the linked inventory's declared
effects against the table below, both ways; every `Kind::Ref` against `schema-refs.json`; the
declaration against the safety class; and, for every headless verb with an example and for the
three Tier A catalogues, the store spy's observed kinds against the declared ones. A verb with no
row, a row with no verb, a row that disagrees with the declaration, or an exception whose reason is
not the one the test computed fails the test and prints the row as it should read.
`scripts/check-verb-coverage.sh` checks the source-only half without a build.
The P7 self-test golden in that test compares the complete linked verb inventory
with the evidence map: each verb must have a successful example, an exact
capability-ID mapping to a passing, non-skipped Tier A check that calls it, or an
exact reviewed exception reason below. A catalogue's service-wide store-spy
union is checked separately; passing one capability does not credit the other
verbs in its service. The golden also rejects stale evidence and enforces the
existing exception ceiling. An exception records a gap; it does not count as a
tested feature.

Every `#[impress_method]` carries an effect set on its descriptor
(`impress_service_core::Effects { reads, writes, reach }`), declared once per service as
`impress_service_impl! { effects = { reads: […], writes: […], reach: […] } }` and replaced per
method with `#[impress_method(effects(reads = […], writes = […], reach = […]))]` on the trait. A
kind is a canonical ref from `schema-refs.json` (a misspelt one is a compile error — the macro
embeds the manifest at build time), `target(arg)` / `children(arg)` when the effect is the kind an
argument names, `prefix("…")` for a family of kinds, or `any("reason")` when the verb cannot say
less. Reach is where the verb leaves the process: `fs`, `network`, `subprocess`, `device`,
`provider` (an AI host) or `app("…")` (a running app over its automation port). An argument marked
`#[impress_private]` in `methods = […]` carries `"x-private": true` in the input schema, and the
call log (L1) never stores it by value.

The table is data: edit a row and the test expects the declaration to follow, never the other
way round. The *Verified* column is written by the test, not by hand: `example ×n` means `n`
examples ran under the spy and touched nothing undeclared; `catalogue:<name>` means the exact
verb is mapped to a passing, non-skipped capability in that Tier A catalogue. The catalogue's
aggregate store-spy observation must also stay within its services' declared effects. Some
headless checks verify an explicit refusal contract rather than a positive native operation:
`imprint-manuscript-service_export-document`, for example, refuses valid-document export
without the native imprint host; the separate hosted transport proof covers actual export bytes.
`—` means the verb is on the exception table below with the reason the test computed. The
exception table is expected to shrink as G3 writes examples; the test fails when it grows past
the count last accepted (`EXCEPTION_CEILING`).

Two read-only verbs leave the process by P1's evidence (`imprint-manuscript-service_compile-latex`
spawns the LaTeX toolchain, `parsers-service_resolve-publisher-pdf` fetches one page) and are
allow-listed in the test rather than reclassed; every other verb with a reach beyond `fs` is
`external`, and every `external` verb names such a reach.

Counts today: 477 verbs declared; 84 verified by example, 93 by a Tier A
catalogue, 300 on the exception table.

## Every verb

<!-- verb-effects:begin -->
| Verb | Reads | Writes | Reach | Verified |
|---|---|---|---|---|
| `capabilities-service_catalogue-surface` | any("the linked inventory's own effect declarations and the stored impress/ui/surface rows") | — | — | — |
| `capabilities-service_impact` | any("the linked inventory's own effect declarations and the stored impress/ui/surface rows") | — | — | example ×2 |
| `capabilities-service_list-verbs` | any("the linked inventory's own effect declarations and the stored impress/ui/surface rows") | — | — | — |
| `capabilities-service_verb-surface` | any("the linked inventory's own effect declarations and the stored impress/ui/surface rows") | — | — | — |
| `collection-service_add-members` | "collection", "imbib/collection", "manuscript-collection", "figure-collection", target(item_ids) | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_create` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×1 |
| `collection-service_delete` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_member-counts` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | — | example ×2 |
| `collection-service_migrate` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection" | — | — |
| `collection-service_migration-status` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | — | — |
| `collection-service_remove-members` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_rename` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_reorder` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_reparent` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | example ×2 |
| `collection-service_rollback` | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | "collection", "imbib/collection", "manuscript-collection", "figure-collection" | — | — |
| `collection-service_tree` | "collection", "imbib/collection", "manuscript-collection", "figure-collection", any("envelope membership counts can query children of any record kind") | — | — | example ×2 |
| `docs-import-service_add-watched-folder` | "watched-folder@1.0.0" | "watched-folder@1.0.0" | fs | — |
| `docs-import-service_finish-watched-scan` | "watched-folder@1.0.0", "watched-file@1.0.0" | "watched-folder@1.0.0", "watched-file@1.0.0" | — | example ×1 |
| `docs-import-service_import-directory` | "manuscript", "manuscript-file@1.0.0", "watched-file@1.0.0" | "manuscript", "manuscript-file@1.0.0" | fs | — |
| `docs-import-service_import-discovered` | "watched-folder@1.0.0", "watched-file@1.0.0", "manuscript" | "watched-file@1.0.0", "manuscript", "manuscript-file@1.0.0" | fs | — |
| `docs-import-service_list-watched-files` | "watched-file@1.0.0", "manuscript-file@1.0.0" | — | — | example ×1 |
| `docs-import-service_list-watched-folders` | "watched-folder@1.0.0" | — | — | example ×2 |
| `docs-import-service_prune-empty-manuscripts` | "manuscript", "manuscript-collection" | "manuscript" | — | example ×1 |
| `docs-import-service_record-produced-rows` | "watched-file@1.0.0", target(produced_ids) | "watched-file@1.0.0" | — | example ×1 |
| `docs-import-service_remove-watched-folder` | "watched-folder@1.0.0", "watched-file@1.0.0" | "watched-folder@1.0.0", "watched-file@1.0.0" | — | example ×1 |
| `docs-import-service_update-watched-folder` | "watched-folder@1.0.0" | "watched-folder@1.0.0" | — | example ×1 |
| `history-service_calls` | any("history reads any kind's operations and every call row") | — | — | — |
| `history-service_health` | any("history reads any kind's operations and every call row") | — | — | — |
| `history-service_propose-workflows` | "core/verb-call@1.0.0" | "impress/workflow@1.0.0" | — | — |
| `history-service_replay` | "core/verb-call@1.0.0" | any("re-invokes an arbitrary recorded verb, whose own writes are its own") | — | — |
| `history-service_save-macro` | "core/verb-call@1.0.0" | "impress/workflow@1.0.0" | — | — |
| `history-service_trace` | any("history reads any kind's operations and every call row") | — | — | — |
| `history-service_why` | any("history reads any kind's operations and every call row") | — | — | — |
| `imbib-annotations-service_count-annotations` | "imbib/annotation" | — | — | example ×1 |
| `imbib-annotations-service_create-annotation` | "imbib/linked-file" | "imbib/annotation" | — | example ×1 |
| `imbib-annotations-service_create-comment` | "imbib/bibliography-entry" | "imbib/comment" | — | example ×1 |
| `imbib-annotations-service_create-comment-on-item` | target(item_id) | "imbib/comment" | — | example ×1 |
| `imbib-annotations-service_list-annotations` | "imbib/annotation" | — | — | example ×1 |
| `imbib-annotations-service_list-comments` | "imbib/comment", "imbib/bibliography-entry" | — | — | example ×1 |
| `imbib-annotations-service_list-comments-for-item` | "imbib/comment", target(item_id) | — | — | example ×1 |
| `imbib-annotations-service_list-comments-since` | "imbib/comment" | — | — | example ×1 |
| `imbib-annotations-service_update-comment` | "imbib/comment" | "imbib/comment" | — | example ×1 |
| `imbib-app-service_add-to-library` | — | — | app("imbib") | — |
| `imbib-app-service_delete-annotation` | — | — | app("imbib") | — |
| `imbib-app-service_delete-collection` | — | — | app("imbib") | — |
| `imbib-app-service_delete-comment` | — | — | app("imbib") | — |
| `imbib-app-service_delete-smart-searches` | — | — | app("imbib") | — |
| `imbib-app-service_download-pdfs` | — | — | app("imbib") | — |
| `imbib-app-service_get-logs` | — | — | app("imbib") | — |
| `imbib-app-service_get-notes` | — | — | app("imbib") | — |
| `imbib-app-service_open-manuscript-papers` | — | — | app("imbib") | — |
| `imbib-app-service_recent-activity` | — | — | app("imbib") | — |
| `imbib-app-service_resolve-identifier` | — | — | app("imbib") | — |
| `imbib-app-service_search-sources` | — | — | app("imbib") | — |
| `imbib-app-service_status` | — | — | app("imbib") | — |
| `imbib-app-service_sync-nudge` | — | — | app("imbib") | — |
| `imbib-app-service_sync-status` | — | — | app("imbib") | — |
| `imbib-app-service_tag-artifact` | — | — | app("imbib") | — |
| `imbib-app-service_update-notes` | — | — | app("imbib") | — |
| `imbib-artifacts-service_count-artifacts` | prefix("impress/artifact/") | — | — | example ×1 |
| `imbib-artifacts-service_create-artifact` | "imbib/tag-definition" | prefix("impress/artifact/"), "imbib/tag-definition" | — | example ×1 |
| `imbib-artifacts-service_delete-artifact` | target(id) | target(id) | — | example ×1 |
| `imbib-artifacts-service_get-artifact` | prefix("impress/artifact/"), "imbib/tag-definition" | — | — | example ×1 |
| `imbib-artifacts-service_get-artifact-relations` | target(id), any("resolves the target of each artifact relation, of any kind") | — | — | example ×1 |
| `imbib-artifacts-service_link-artifact-to-publication` | target(artifact_id), "imbib/bibliography-entry" | target(artifact_id) | — | example ×1 |
| `imbib-artifacts-service_list-artifacts` | prefix("impress/artifact/"), "imbib/tag-definition" | — | — | example ×1 |
| `imbib-artifacts-service_search-artifacts` | any("searches every indexed kind before filtering artifact schemas"), "imbib/tag-definition" | — | — | example ×1 |
| `imbib-artifacts-service_update-artifact` | target(id) | target(id) | — | example ×1 |
| `imbib-backup-service_create-backup` | — | — | fs | example ×1 |
| `imbib-backup-service_delete-backup` | — | — | fs | example ×1 |
| `imbib-backup-service_inspect-backup` | — | — | fs | example ×1 |
| `imbib-backup-service_list-backups` | — | — | fs | example ×1 |
| `imbib-backup-service_prune-backups` | — | — | fs | example ×1 |
| `imbib-backup-service_restore-backup` | — | — | app("imbib"), fs | — |
| `imbib-eink-service_eink-append-notes` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/annotation", "imbib/eink-mirror", "imbib/eink-device" | "imbib/bibliography-entry", "imbib/linked-file", "imbib/annotation" | — | example ×1 |
| `imbib-eink-service_eink-awaiting-source` | "imbib/bibliography-entry", "imbib/eink-mirror", "imbib/eink-device" | — | — | example ×1 |
| `imbib-eink-service_eink-complete-ocr` | "imbib/annotation" | "imbib/annotation" | — | example ×1 |
| `imbib-eink-service_eink-configure-device` | "imbib/eink-device" | "imbib/eink-device" | — | example ×1 |
| `imbib-eink-service_eink-devices` | "imbib/eink-device" | — | — | example ×1 |
| `imbib-eink-service_eink-folder-checklist` | "imbib/eink-device", "imbib/eink-mirror" | — | device | — |
| `imbib-eink-service_eink-import` | "imbib/eink-device", "imbib/eink-mirror", "imbib/bibliography-entry", "imbib/linked-file" | "imbib/annotation", "imbib/linked-file", "imbib/eink-mirror" | device, fs | — |
| `imbib-eink-service_eink-import-document` | "imbib/eink-device", "imbib/eink-mirror", "imbib/library", "imbib/bibliography-entry" | "imbib/bibliography-entry", "imbib/linked-file", "imbib/eink-mirror", "impress/artifact/note" | device, fs | — |
| `imbib-eink-service_eink-list-annotations` | "imbib/annotation", "imbib/linked-file" | — | — | example ×1 |
| `imbib-eink-service_eink-list-mirrored` | "imbib/eink-mirror", "imbib/eink-device" | — | — | example ×1 |
| `imbib-eink-service_eink-list-unmatched` | "imbib/eink-device", "imbib/eink-mirror" | — | device | — |
| `imbib-eink-service_eink-mark` | "imbib/bibliography-entry", "imbib/eink-device", "imbib/eink-mirror", "imbib/linked-file" | "imbib/eink-mirror" | — | example ×1 |
| `imbib-eink-service_eink-note-source-error` | "imbib/eink-device", "imbib/eink-mirror" | "imbib/eink-mirror" | — | example ×1 |
| `imbib-eink-service_eink-pending-ocr` | "imbib/bibliography-entry", "imbib/annotation", "imbib/linked-file" | — | — | example ×1 |
| `imbib-eink-service_eink-plan` | "imbib/eink-device", "imbib/eink-mirror", "imbib/bibliography-entry", "imbib/linked-file" | — | device | — |
| `imbib-eink-service_eink-reachable` | "imbib/eink-device" | — | device | — |
| `imbib-eink-service_eink-remove-device` | "imbib/eink-device", "imbib/eink-mirror" | "imbib/eink-device", "imbib/eink-mirror" | — | example ×1 |
| `imbib-eink-service_eink-resend` | "imbib/eink-mirror" | "imbib/eink-mirror" | — | example ×1 |
| `imbib-eink-service_eink-search-annotations` | "imbib/annotation" | — | — | example ×1 |
| `imbib-eink-service_eink-status` | "imbib/bibliography-entry", "imbib/eink-device", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-eink-service_eink-sync` | "imbib/eink-device", "imbib/eink-mirror", "imbib/bibliography-entry", "imbib/linked-file" | "imbib/eink-mirror", "imbib/annotation", "imbib/linked-file" | device, fs | — |
| `imbib-eink-service_eink-unmark` | "imbib/eink-device", "imbib/eink-mirror" | "imbib/eink-mirror" | — | example ×1 |
| `imbib-library-service_add-linked-file` | "imbib/bibliography-entry" | "imbib/linked-file" | — | example ×1 |
| `imbib-library-service_add-to-collection` | "imbib/collection", "imbib/bibliography-entry" | "imbib/collection" | — | example ×1 |
| `imbib-library-service_count-flagged` | "imbib/bibliography-entry" | — | — | example ×2 |
| `imbib-library-service_count-pdfs` | "imbib/linked-file" | — | — | example ×1 |
| `imbib-library-service_count-publications` | "imbib/bibliography-entry" | — | — | example ×2 |
| `imbib-library-service_count-starred` | "imbib/bibliography-entry" | — | — | example ×2 |
| `imbib-library-service_count-unread` | "imbib/bibliography-entry" | — | — | example ×2 |
| `imbib-library-service_create-collection` | "imbib/library" | "imbib/collection" | — | example ×1 |
| `imbib-library-service_create-library` | "imbib/library", "imbib/collection" | "imbib/library" | — | example ×1 |
| `imbib-library-service_create-muted-item` | "imbib/muted-item" | "imbib/muted-item" | — | example ×1 |
| `imbib-library-service_deduplicate-library` | "imbib/bibliography-entry", "imbib/library" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_delete-library-undoable` | "imbib/library", "imbib/bibliography-entry", "imbib/collection" | "imbib/library", "imbib/bibliography-entry", "imbib/collection" | — | example ×1 |
| `imbib-library-service_delete-publications-undoable` | "imbib/bibliography-entry", any("undo snapshots query all children of each publication, regardless of kind") | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_dismiss-paper` | "imbib/dismissed-paper" | "imbib/dismissed-paper" | — | example ×1 |
| `imbib-library-service_duplicate-publications` | "imbib/bibliography-entry", "imbib/linked-file" | "imbib/bibliography-entry", "imbib/linked-file" | fs | — |
| `imbib-library-service_export-all-bibtex` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/library" | — | — | example ×1 |
| `imbib-library-service_export-bibtex` | "imbib/eink-device", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition" | — | — | example ×1 |
| `imbib-library-service_export-ris` | "imbib/eink-device", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition" | — | — | example ×1 |
| `imbib-library-service_get-default-library` | "imbib/library", "imbib/bibliography-entry", "imbib/collection" | — | — | example ×2 |
| `imbib-library-service_get-inbox-library` | "imbib/library", "imbib/bibliography-entry", "imbib/collection" | — | — | example ×2 |
| `imbib-library-service_get-publication` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-library-service_get-publication-detail` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/collection" | — | — | example ×1 |
| `imbib-library-service_import-bibtex` | "imbib/bibliography-entry", "imbib/library" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_import-bibtex-into-collection` | "imbib/bibliography-entry", "imbib/library", "imbib/collection" | "imbib/bibliography-entry", "imbib/collection" | — | example ×1 |
| `imbib-library-service_import-papers` | "imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_is-paper-dismissed` | "imbib/dismissed-paper" | — | — | example ×2 |
| `imbib-library-service_list-collection-members` | "imbib/collection", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-library-service_list-collections` | "imbib/collection", "imbib/library" | — | — | example ×1 |
| `imbib-library-service_list-dismissed-papers` | "imbib/dismissed-paper" | — | — | example ×1 |
| `imbib-library-service_list-libraries` | "imbib/library", "imbib/bibliography-entry", "imbib/collection" | — | — | example ×2 |
| `imbib-library-service_list-linked-files` | "imbib/linked-file" | — | — | example ×1 |
| `imbib-library-service_list-muted-items` | "imbib/muted-item" | — | — | example ×2 |
| `imbib-library-service_list-publications` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×2 |
| `imbib-library-service_move-publications` | "imbib/bibliography-entry", "imbib/library" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_purge-dismissed-from-collection` | "imbib/collection", "imbib/bibliography-entry", "imbib/dismissed-paper" | "imbib/collection" | — | example ×1 |
| `imbib-library-service_query-publications` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-library-service_query-recent` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×2 |
| `imbib-library-service_query-starred` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×2 |
| `imbib-library-service_query-unread` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×2 |
| `imbib-library-service_remove-from-collection` | "imbib/collection" | "imbib/collection" | — | example ×1 |
| `imbib-library-service_retention-cleanup` | "imbib/bibliography-entry", "imbib/smart-search", "imbib/library", "imbib/dismissed-paper" | "imbib/bibliography-entry", "imbib/smart-search", "imbib/dismissed-paper" | — | example ×2 |
| `imbib-library-service_search-publications` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection" | — | — | example ×3 |
| `imbib-library-service_set-flag` | "imbib/bibliography-entry" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_set-library-default` | "imbib/library" | "imbib/library" | — | example ×1 |
| `imbib-library-service_set-read` | "imbib/bibliography-entry" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_set-starred` | "imbib/bibliography-entry" | "imbib/bibliography-entry" | — | example ×1 |
| `imbib-library-service_sidebar-view` | "imbib/library", "imbib/bibliography-entry", "imbib/smart-search", "imbib/collection", prefix("impress/artifact/") | — | — | example ×2 |
| `imbib-manuscripts-service_compile-manuscript` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_create-manuscript` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_create-manuscript-from-template` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_get-manuscript` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_list-manuscripts` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_list-templates` | — | — | app("imbib") | — |
| `imbib-manuscripts-service_write-manuscript-body` | — | — | app("imbib") | — |
| `imbib-scix-service_add-to-scix-library` | "imbib/scix-library", "imbib/bibliography-entry" | "imbib/scix-library" | — | example ×1 |
| `imbib-scix-service_count-scix-library-publications` | "imbib/bibliography-entry", "imbib/scix-library" | — | — | example ×1 |
| `imbib-scix-service_create-scix-library` | "imbib/scix-library" | "imbib/scix-library" | — | example ×1 |
| `imbib-scix-service_get-scix-library` | "imbib/scix-library" | — | — | example ×1 |
| `imbib-scix-service_list-scix-libraries` | "imbib/scix-library" | — | — | example ×1 |
| `imbib-scix-service_query-scix-library-publications` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/scix-library" | — | — | example ×1 |
| `imbib-scix-service_remove-from-scix-library` | "imbib/scix-library" | "imbib/scix-library" | — | example ×1 |
| `imbib-search-service_create-smart-search` | "imbib/library" | "imbib/smart-search" | — | example ×1 |
| `imbib-search-service_find-by-arxiv` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_find-by-bibcode` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_find-by-cite-key` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_find-by-doi` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_find-by-identifiers-batch` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_full-text-search` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-search-service_get-smart-search` | "imbib/smart-search" | — | — | example ×1 |
| `imbib-search-service_list-smart-searches` | "imbib/smart-search" | — | — | example ×1 |
| `imbib-search-service_resolve-cite-key` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library" | — | — | example ×1 |
| `imbib-semantic-service_get-paper-chunks` | any("reads the imbib embeddings sidecar") | — | — | — |
| `imbib-semantic-service_list-indexed-papers` | any("reads the imbib embeddings sidecar and, for metadata, the shared impress store") | — | — | — |
| `imbib-semantic-service_search-papers` | any("reads the imbib embeddings sidecar and, for metadata, the shared impress store") | — | — | — |
| `imbib-tags-service_add-tag` | "imbib/bibliography-entry" | "imbib/bibliography-entry" | — | — |
| `imbib-tags-service_count-by-tag` | "imbib/bibliography-entry" | — | — | example ×1 |
| `imbib-tags-service_create-tag` | "imbib/tag-definition" | "imbib/tag-definition" | — | example ×1 |
| `imbib-tags-service_delete-tag-undoable` | "imbib/tag-definition", "imbib/bibliography-entry" | "imbib/tag-definition", "imbib/bibliography-entry" | — | example ×1 |
| `imbib-tags-service_list-tags` | "imbib/tag-definition" | — | — | example ×1 |
| `imbib-tags-service_list-tags-with-counts` | "imbib/tag-definition", "imbib/bibliography-entry" | — | — | — |
| `imbib-tags-service_query-by-tag` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | — | example ×1 |
| `imbib-tags-service_remove-tag` | "imbib/bibliography-entry" | "imbib/bibliography-entry" | — | — |
| `imbib-tags-service_rename-tag` | "imbib/tag-definition", "imbib/bibliography-entry" | "imbib/tag-definition", "imbib/bibliography-entry" | — | example ×1 |
| `imbib-tags-service_update-tag` | "imbib/tag-definition" | "imbib/tag-definition" | — | example ×1 |
| `imbib-text-service_decode-latex` | — | — | — | example ×1 |
| `imbib-text-service_expand-journal-macro` | — | — | — | example ×1 |
| `imbib-text-service_generate-cite-key` | — | — | — | example ×1 |
| `imbib-text-service_normalize-tag-path` | — | — | — | example ×1 |
| `imbib-text-service_normalize-tag-segment` | — | — | — | example ×1 |
| `imbib-undo-service_recent-undo-groups` | "core/operation" | — | — | — |
| `imbib-undo-service_undo-batch` | "core/operation" | any("restores whatever kind the operations targeted") | — | example ×1 |
| `imbib-undo-service_undo-operation` | "core/operation" | any("restores whatever kind the operations targeted") | — | example ×1 |
| `impart-service_add-message` | — | — | app("impart") | — |
| `impart-service_branch-conversation` | — | — | app("impart") | — |
| `impart-service_create-conversation` | — | — | app("impart") | — |
| `impart-service_get-conversation` | — | — | app("impart") | — |
| `impart-service_get-logs` | — | — | app("impart") | — |
| `impart-service_list-conversations` | — | — | app("impart") | — |
| `impart-service_record-artifact` | — | — | app("impart") | — |
| `impart-service_record-decision` | — | — | app("impart") | — |
| `impart-service_status` | — | — | app("impart") | — |
| `impart-service_update-conversation` | — | — | app("impart") | — |
| `impel-service_cancel-task` | "task@1.0.0" | "task@1.0.0" | — | example ×1 |
| `impel-service_job-cancel` | "task@1.0.0" | "task@1.0.0" | — | example ×1 |
| `impel-service_job-events` | "task@1.0.0", "task-event@1.0.0" | — | — | example ×1 |
| `impel-service_job-result` | "task@1.0.0", "task-event@1.0.0" | — | — | example ×1 |
| `impel-service_job-status` | "task@1.0.0", "task-event@1.0.0" | — | — | example ×1 |
| `impel-service_job-wait` | "task@1.0.0", "task-event@1.0.0" | — | — | example ×1 |
| `impel-service_list-failed-tasks` | "task@1.0.0" | — | — | example ×1 |
| `impel-service_list-pending-reviews` | "review-request@1.0.0" | — | — | example ×1 |
| `impel-service_resolve-review` | "review-request@1.0.0", "task@1.0.0" | "review-request@1.0.0", "task@1.0.0" | — | example ×1 |
| `impel-service_retention-status` | "task@1.0.0", "review-request@1.0.0", "core/operation" | — | — | — |
| `impel-service_scheduler-status` | "task@1.0.0", "review-request@1.0.0" | — | — | example ×1 |
| `implore-service_create-figure` | — | "figure" | app("implore") | — |
| `implore-service_delete-figure` | target(figure_id) | "figure" | app("implore") | — |
| `implore-service_export-figure` | — | — | app("implore") | — |
| `implore-service_export-figure-data` | — | — | app("implore") | — |
| `implore-service_get-dataset` | — | — | app("implore") | — |
| `implore-service_get-figure` | — | — | app("implore") | — |
| `implore-service_get-logs` | — | — | app("implore") | — |
| `implore-service_list-datasets` | — | — | app("implore") | — |
| `implore-service_list-figures` | — | — | app("implore") | — |
| `implore-service_plot-histogram` | — | — | app("implore") | — |
| `implore-service_plot-series` | — | — | app("implore") | — |
| `implore-service_rg-batch` | — | — | app("implore") | — |
| `implore-service_rg-cascade-plot` | — | — | app("implore") | — |
| `implore-service_rg-colormaps` | — | — | app("implore") | — |
| `implore-service_rg-control` | — | — | app("implore") | — |
| `implore-service_rg-load` | — | — | app("implore") | — |
| `implore-service_rg-slice-png` | — | — | app("implore") | — |
| `implore-service_rg-slice-raw` | — | — | app("implore") | — |
| `implore-service_rg-slice-save` | — | — | app("implore") | — |
| `implore-service_rg-state` | — | — | app("implore") | — |
| `implore-service_rg-statistics` | — | — | app("implore") | — |
| `implore-service_status` | — | — | app("implore") | — |
| `implore-service_update-figure` | target(figure_id) | "figure" | app("implore") | — |
| `impress-ai-service_ai-health` | — | — | network | — |
| `impress-ai-service_ai-preferences` | — | — | fs | example ×1 |
| `impress-ai-service_create-conversation` | "conversation@1.0.0" | "conversation@1.0.0" | — | example ×1 |
| `impress-ai-service_get-conversation` | "conversation@1.0.0", "chat-message", "task@1.0.0" | — | — | example ×1 |
| `impress-ai-service_list-conversations` | "conversation@1.0.0" | — | — | example ×1 |
| `impress-ai-service_list-models` | — | — | provider | — |
| `impress-ai-service_list-providers` | — | — | provider, fs | — |
| `impress-ai-service_mint-pairing-link` | — | — | network | — |
| `impress-ai-service_provider-health` | — | — | provider | — |
| `impress-ai-service_queue-message` | "conversation@1.0.0", "chat-message" | "conversation@1.0.0", "chat-message", "task@1.0.0" | — | example ×1 |
| `impress-ai-service_run-provenance` | "agent-run@1.0.0", "task@1.0.0", "tool-invocation@1.0.0", any("run lineage loads produced outputs of any record kind") | — | — | example ×1 |
| `impress-ai-service_select-model` | — | — | fs | example ×1 |
| `impress-ai-service_set-enabled-tools` | "conversation@1.0.0" | "conversation@1.0.0" | — | example ×1 |
| `impress-ai-service_set-provider-endpoint` | — | — | fs | example ×1 |
| `impress-ai-service_task-provenance` | "task@1.0.0", "agent-run@1.0.0", "tool-invocation@1.0.0", any("run lineage loads produced outputs of any record kind") | — | — | example ×1 |
| `impress-ai-service_task-status` | "task@1.0.0", "agent-run@1.0.0", "chat-message" | — | — | example ×1 |
| `impress-bridges-service_add-papers-from-conversation` | "conversation@1.0.0", "chat-message", "imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper" | "imbib/bibliography-entry" | app("impart"), network | — |
| `impress-bridges-service_cite-in-section` | "imbib/bibliography-entry", "imbib/tag-definition", "manuscript", "manuscript-section" | "manuscript-section", "citation-usage" | — | example ×1 |
| `impress-bridges-service_cite-multiple` | "imbib/bibliography-entry", "imbib/library", "imbib/tag-definition" | — | app("imprint") | — |
| `impress-bridges-service_cite-paper` | "imbib/bibliography-entry", "imbib/library" | — | app("imprint") | — |
| `impress-bridges-service_conversation-decisions` | — | — | app("impart") | — |
| `impress-bridges-service_conversation-to-outline` | — | — | app("impart"), provider | — |
| `impress-bridges-service_embed-figure` | target(figure_id) | — | app("implore"), app("imprint"), fs | — |
| `impress-bridges-service_embed-figure-reference` | target(figure_id) | — | app("imprint") | — |
| `impress-bridges-service_export-conversation-citations` | "imbib/bibliography-entry", "imbib/library", "imbib/linked-file", "imbib/tag-definition" | — | app("impart"), fs | — |
| `impress-bridges-service_extract-papers-from-conversation` | — | — | app("impart"), network | — |
| `impress-bridges-service_extract-papers-from-text` | — | — | — | example ×1 |
| `impress-bridges-service_get-citation-suggestions` | "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror" | — | app("imprint") | — |
| `impress-bridges-service_get-item` | target(item_id) | — | — | example ×1 |
| `impress-bridges-service_get-related` | target(item_id), any("walks references across kinds") | — | — | example ×1 |
| `impress-bridges-service_list-available-figures` | — | — | app("implore") | — |
| `impress-bridges-service_resolve-artifact` | any("resolves a URI to whichever kind it names") | — | — | example ×1 |
| `impress-bridges-service_search-all` | any("searches every kind") | — | — | example ×1 |
| `impress-bridges-service_sync-figure` | target(figure_id) | — | app("implore"), fs | — |
| `impress-scenario-service_scenario-create` | "impress/scenario@1.0.0" | "impress/scenario@1.0.0" | — | example ×1 |
| `impress-scenario-service_scenario-get` | "impress/scenario@1.0.0" | — | — | example ×1 |
| `impress-scenario-service_scenario-list` | "impress/scenario@1.0.0" | — | — | example ×1 |
| `impress-scenario-service_scenario-record` | "core/verb-call@1.0.0", "impress/scenario@1.0.0" | "impress/scenario@1.0.0" | — | example ×1 |
| `impress-scenario-service_scenario-run` | "impress/scenario@1.0.0" | any("a scenario's steps may call any verb, including a mutating one") | network | — |
| `impress-scenario-service_scenario-validate` | — | — | — | example ×1 |
| `impress-surface-service_surface-create` | "impress/ui/surface@1.0.0" | "impress/ui/surface@1.0.0" | — | example ×1 |
| `impress-surface-service_surface-delete` | "impress/ui/surface-event@1.0.0", "impress/ui/surface-state@1.0.0", "impress/ui/surface@1.0.0" | "impress/ui/surface@1.0.0", "impress/ui/surface-state@1.0.0", "impress/ui/surface-event@1.0.0" | — | example ×1 |
| `impress-surface-service_surface-dispatch` | "impress/ui/surface@1.0.0", "impress/ui/surface-state@1.0.0", any("evaluates the surface's verb sources") | "impress/ui/surface-state@1.0.0", "impress/ui/surface-event@1.0.0", any("runs the surface's actions") | — | example ×1 |
| `impress-surface-service_surface-events` | "impress/ui/surface@1.0.0", "impress/ui/surface-event@1.0.0" | — | — | example ×1 |
| `impress-surface-service_surface-examples` | — | — | — | example ×1 |
| `impress-surface-service_surface-get` | "impress/ui/surface@1.0.0" | — | — | example ×1 |
| `impress-surface-service_surface-list` | "impress/ui/surface@1.0.0" | — | — | example ×1 |
| `impress-surface-service_surface-render` | "impress/ui/surface@1.0.0", "impress/ui/surface-state@1.0.0", any("evaluates the surface's verb sources") | — | — | example ×1 |
| `impress-surface-service_surface-schema` | — | — | — | example ×1 |
| `impress-surface-service_surface-show` | "impress/ui/surface-state@1.0.0", "impress/ui/surface@1.0.0", "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `impress-surface-service_surface-state-get` | "impress/ui/surface@1.0.0", "impress/ui/surface-state@1.0.0" | — | — | example ×1 |
| `impress-surface-service_surface-state-set` | "impress/ui/surface@1.0.0", "impress/ui/surface-state@1.0.0" | "impress/ui/surface-state@1.0.0" | — | example ×1 |
| `impress-surface-service_surface-update` | "impress/ui/surface@1.0.0" | "impress/ui/surface@1.0.0" | — | example ×1 |
| `impress-surface-service_surface-validate` | — | — | — | example ×1 |
| `impress-surface-service_surface-wait` | "impress/ui/surface@1.0.0", "impress/ui/surface-event@1.0.0" | — | — | example ×1 |
| `impress-workflow-service_workflow-create` | "impress/workflow@1.0.0" | "impress/workflow@1.0.0" | — | example ×1 |
| `impress-workflow-service_workflow-disable` | "impress/workflow@1.0.0" | "impress/workflow@1.0.0" | — | example ×1 |
| `impress-workflow-service_workflow-dry-run` | "impress/workflow@1.0.0" | — | — | example ×1 |
| `impress-workflow-service_workflow-enable` | "impress/workflow@1.0.0" | "impress/workflow@1.0.0" | — | example ×1 |
| `impress-workflow-service_workflow-get` | "impress/workflow@1.0.0" | — | — | example ×1 |
| `impress-workflow-service_workflow-list` | "impress/workflow@1.0.0" | — | — | example ×1 |
| `impress-workflow-service_workflow-validate` | — | — | — | example ×1 |
| `imprint-app-service_create-comment` | — | — | app("imprint") | — |
| `imprint-app-service_create-document` | — | — | app("imprint") | — |
| `imprint-app-service_delete-comment` | — | — | app("imprint") | — |
| `imprint-app-service_delete-text` | — | — | app("imprint") | — |
| `imprint-app-service_get-bibliography` | — | — | app("imprint") | — |
| `imprint-app-service_get-content` | — | — | app("imprint") | — |
| `imprint-app-service_get-logs` | — | — | app("imprint") | — |
| `imprint-app-service_get-pdf` | — | — | app("imprint") | — |
| `imprint-app-service_insert-text` | — | — | app("imprint") | — |
| `imprint-app-service_list-comments` | — | — | app("imprint") | — |
| `imprint-app-service_replace` | — | — | app("imprint") | — |
| `imprint-app-service_status` | — | — | app("imprint") | — |
| `imprint-app-service_update-comment` | — | — | app("imprint") | — |
| `imprint-app-service_update-document` | — | — | app("imprint") | — |
| `imprint-app-service_update-metadata` | — | — | app("imprint") | — |
| `imprint-manuscript-service_compile-latex` | — | — | subprocess | — |
| `imprint-manuscript-service_compile-typst` | "manuscript", "manuscript-file@1.0.0" | — | fs | catalogue:imprint |
| `imprint-manuscript-service_delete-section` | "manuscript", "manuscript-section" | "manuscript-section", "manuscript" | — | example ×1 |
| `imprint-manuscript-service_document-citations` | — | — | — | example ×2 |
| `imprint-manuscript-service_document-outline` | — | — | — | example ×2 |
| `imprint-manuscript-service_export-document` | "manuscript", "manuscript-section" | — | — | catalogue:imprint |
| `imprint-manuscript-service_get-document` | "manuscript", "manuscript-section" | — | — | example ×1 |
| `imprint-manuscript-service_get-section` | "manuscript", "manuscript-section" | — | — | example ×1 |
| `imprint-manuscript-service_list-documents` | "manuscript" | — | — | example ×2 |
| `imprint-manuscript-service_list-sections` | "manuscript", "manuscript-section" | — | — | example ×1 |
| `imprint-manuscript-service_presentation-outline` | — | — | — | example ×1 |
| `imprint-manuscript-service_put-section` | "manuscript", "manuscript-section" | "manuscript-section", "manuscript" | — | example ×1 |
| `imprint-manuscript-service_reorder-presentation-slide` | — | — | — | example ×1 |
| `imprint-manuscript-service_replace-in-section` | "manuscript", "manuscript-section" | "manuscript-section" | — | example ×1 |
| `imprint-manuscript-service_search` | "manuscript", "manuscript-section" | — | — | catalogue:imprint |
| `imprint-manuscript-service_search-in-text` | — | — | — | example ×2 |
| `imprint-manuscript-service_set-presentation-slide-beat` | — | — | — | example ×1 |
| `imprint-project-service_project-build` | "manuscript", "manuscript-file@1.0.0", "figure", "task@1.0.0", "task-event@1.0.0" | "manuscript-build@1.0.0", "manuscript-file@1.0.0", "task@1.0.0", "task-event@1.0.0" | subprocess, fs | — |
| `imprint-project-service_project-build-output` | "manuscript-build@1.0.0" | — | fs | example ×1 |
| `imprint-project-service_project-builds` | "manuscript-build@1.0.0" | — | — | example ×1 |
| `imprint-project-service_project-checkin` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "manuscript-change@1.0.0", "manuscript" | fs | example ×1 |
| `imprint-project-service_project-checkout` | "manuscript", "manuscript-file@1.0.0" | "manuscript" | fs | example ×1 |
| `imprint-project-service_project-citations` | "manuscript", "manuscript-file@1.0.0", "imbib/bibliography-entry" | — | — | example ×1 |
| `imprint-project-service_project-collect` | "manuscript", "manuscript-file@1.0.0", "imbib/bibliography-entry", "imbib/library", "imbib/collection" | "imbib/collection" | — | example ×1 |
| `imprint-project-service_project-compile` | "manuscript", "manuscript-file@1.0.0", "imbib/bibliography-entry", "imbib/library" | — | fs | example ×1 |
| `imprint-project-service_project-delete-file` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "manuscript" | — | example ×1 |
| `imprint-project-service_project-export` | "manuscript", "manuscript-file@1.0.0" | — | fs | example ×1 |
| `imprint-project-service_project-figure-preview` | "manuscript", "manuscript-file@1.0.0", "figure" | — | subprocess, fs | — |
| `imprint-project-service_project-file` | "manuscript", "manuscript-file@1.0.0" | — | — | example ×1 |
| `imprint-project-service_project-graph` | "manuscript", "manuscript-file@1.0.0", "plot-spec" | — | — | example ×1 |
| `imprint-project-service_project-import-directory` | "manuscript", "manuscript-file@1.0.0" | "manuscript", "manuscript-file@1.0.0", "manuscript-change@1.0.0", "figure" | fs | example ×1 |
| `imprint-project-service_project-materialize` | "manuscript", "manuscript-file@1.0.0" | — | fs | example ×1 |
| `imprint-project-service_project-move-file` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "manuscript" | — | example ×1 |
| `imprint-project-service_project-new-figure` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "figure", "manuscript" | — | example ×1 |
| `imprint-project-service_project-outline` | "manuscript", "manuscript-file@1.0.0" | — | — | example ×1 |
| `imprint-project-service_project-put-file` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "manuscript" | — | example ×1 |
| `imprint-project-service_project-reading-list` | "manuscript", "manuscript-file@1.0.0", "imbib/bibliography-entry", "imbib/collection", "imbib/linked-file" | — | — | example ×1 |
| `imprint-project-service_project-render-figure` | "manuscript", "manuscript-file@1.0.0", "figure" | "manuscript-file@1.0.0" | subprocess, fs | — |
| `imprint-project-service_project-set-bibliography` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0", "manuscript" | — | example ×1 |
| `imprint-project-service_project-set-entry` | "manuscript" | "manuscript" | — | example ×1 |
| `imprint-project-service_project-set-figure-build` | "manuscript", "manuscript-file@1.0.0" | "manuscript-file@1.0.0" | — | example ×1 |
| `imprint-project-service_project-set-targets` | "manuscript", "manuscript-file@1.0.0" | "manuscript" | — | example ×1 |
| `imprint-project-service_project-snapshot` | "manuscript", "manuscript-file@1.0.0", "manuscript-revision" | "manuscript-revision", "manuscript" | — | example ×1 |
| `imprint-project-service_project-status` | "manuscript", "manuscript-file@1.0.0" | — | fs | example ×1 |
| `imprint-project-service_project-sync-reading-collection` | "manuscript", "manuscript-file@1.0.0", "imbib/bibliography-entry", "imbib/library", "imbib/collection" | "imbib/collection" | — | example ×1 |
| `imprint-project-service_project-tree` | "manuscript", "manuscript-file@1.0.0", "plot-spec" | — | — | example ×1 |
| `imprint-project-service_project-uncollect` | "manuscript", "imbib/collection" | "imbib/collection" | — | example ×1 |
| `imprint-selftest-service_run-selftest` | any("runs the catalogue's capabilities") | any("runs the catalogue's capabilities") | app("imprint"), fs, subprocess | — |
| `imprint-text-service_compose-citation` | — | — | — | example ×1 |
| `imprint-text-service_compose-heading` | — | — | — | example ×1 |
| `imprint-text-service_extract-cite-key-usages` | — | — | — | example ×1 |
| `imprint-text-service_extract-cite-keys` | — | — | — | example ×1 |
| `imprint-text-service_format-latex` | — | — | — | example ×1 |
| `imprint-throughline-service_create-throughline` | "manuscript", "throughline" | "throughline" | — | example ×1 |
| `imprint-throughline-service_delete-throughline` | "throughline" | "throughline" | — | example ×1 |
| `imprint-throughline-service_get-anchor-states` | "throughline", "manuscript-section", "manuscript" | — | — | example ×1 |
| `imprint-throughline-service_get-coverage` | "throughline", "manuscript-section", "manuscript" | — | — | example ×1 |
| `imprint-throughline-service_get-throughline` | "throughline" | — | — | example ×1 |
| `imprint-throughline-service_mark-supporting` | "throughline" | "throughline" | — | example ×1 |
| `imprint-throughline-service_remove-anchor` | "throughline" | "throughline" | — | example ×1 |
| `imprint-throughline-service_set-anchor` | "throughline", "manuscript-section" | "throughline" | — | example ×1 |
| `imprint-throughline-service_update-throughline-source` | "throughline" | "throughline" | — | example ×1 |
| `layout-selftest-service_run-selftest` | any("runs the catalogue's capabilities") | any("runs the catalogue's capabilities") | app("impress") | — |
| `layout-service_apply-layout` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_apply-preset` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_bind-param` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_close` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_commit` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0", "impress/ui/surface@1.0.0" | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | — | example ×1 |
| `layout-service_delete-layout` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_detach` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_focus` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_focus-direction` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_get-channel` | "impress/ui/layout@1.0.0" | — | — | catalogue:layout |
| `layout-service_get-layout` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×2 |
| `layout-service_get-pane` | "impress/ui/layout@1.0.0", any("compiles the pane's query over the kind it names") | — | — | catalogue:layout |
| `layout-service_list-layouts` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/preset@1.0.0" | — | example ×2 |
| `layout-service_list-presets` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | — | — | example ×2 |
| `layout-service_maximize` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_move-tile` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_redo` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_reset-preset` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | — | example ×1 |
| `layout-service_resize` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_resolve-reference` | "impress/ui/layout@1.0.0" | — | — | catalogue:layout |
| `layout-service_restore` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_save-layout` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_save-preset` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/preset@1.0.0", "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_select` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-channel` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-collapsed` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-container-kind` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-default-channel` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-pane` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-query` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-role` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-view-kind` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_set-window-geometry` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_split` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_swap` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `layout-service_undo` | "impress/ui/layout@1.0.0", "impress/ui/preset@1.0.0" | "impress/ui/layout@1.0.0" | — | example ×1 |
| `manuscript-collab-service_commit-manuscript-body` | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | — | example ×1 |
| `manuscript-collab-service_manuscript-change-history` | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | — | example ×1 |
| `manuscript-collab-service_manuscript-heads` | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | — | example ×1 |
| `manuscript-collab-service_manuscript-text-at` | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | "manuscript", "manuscript-change@1.0.0", "manuscript-file@1.0.0" | — | example ×1 |
| `memory-service_confirm-claim` | "memory/claim@1.0.0" | "memory/claim@1.0.0" | — | example ×1 |
| `memory-service_forget` | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | — | example ×1 |
| `memory-service_memory-brief` | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | — | — | example ×1 |
| `memory-service_memory-status` | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | — | — | — |
| `memory-service_recall` | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | — | — | example ×1 |
| `memory-service_remember` | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | "memory/claim@1.0.0", "memory/episode@1.0.0", "memory/instruction@1.0.0" | — | example ×1 |
| `memory-service_supersede-claim` | "memory/claim@1.0.0" | "memory/claim@1.0.0" | — | example ×1 |
| `parsers-service_decode-mime-header` | — | — | — | example ×1 |
| `parsers-service_decode-quoted-printable` | — | — | — | example ×1 |
| `parsers-service_extract-landing-page-pdf` | — | — | — | example ×1 |
| `parsers-service_list-publisher-rules` | — | — | — | example ×1 |
| `parsers-service_parse-mbox` | — | — | — | example ×1 |
| `parsers-service_resolve-publisher-pdf` | — | — | network | — |
| `perf-service_export-chrome-trace` | — | — | — | example ×1 |
| `perf-service_export-folded-stacks` | — | — | — | example ×1 |
| `perf-service_summary` | — | — | — | example ×2 |
| `perf-service_trace` | — | — | — | example ×1 |
| `provider-service_list` | — | — | — | example ×1 |
| `provider-service_set-trusted` | "provider@1.0.0" | "provider@1.0.0" | — | catalogue:provider |
| `settings-service_get` | "impress/settings@1.0.0" | — | fs | — |
| `settings-service_list` | "impress/settings@1.0.0" | — | fs | — |
| `settings-service_reset` | — | "impress/settings@1.0.0" | fs | — |
| `settings-service_schema` | — | — | — | example ×1 |
| `settings-service_set` | — | "impress/settings@1.0.0" | fs | — |
| `settings-service_surface` | "impress/settings@1.0.0" | — | fs | — |
| `smart-search-service_build-ads-query` | — | — | — | example ×1 |
| `smart-search-service_classify-search-input` | — | — | — | example ×1 |
| `smart-search-service_clean-ads-query` | — | — | — | example ×1 |
| `smart-search-service_extract-page-identifiers` | — | — | — | example ×1 |
| `smart-search-service_free-text-extraction-prompt` | — | — | — | example ×1 |
| `smart-search-service_normalize-ads-query` | — | — | — | example ×1 |
| `smart-search-service_reference-parse-prompt` | — | — | — | example ×1 |
| `smart-search-service_rewrite-free-text-query` | — | — | — | example ×1 |
| `smart-search-service_split-reference-blocks` | — | — | — | example ×1 |
| `smart-search-service_validate-parsed-reference` | — | — | — | example ×1 |
| `source-service_get-citation` | "source-citation@1.0.0", "figure-region@1.0.0", "impress/artifact/general" | — | — | example ×1 |
| `source-service_get-content-chunk` | "content-chunk@1.0.0", "figure-region@1.0.0", "impress/artifact/general" | — | — | example ×1 |
| `source-service_get-figure-image` | target(source_item_id), "figure-region@1.0.0", "source-citation@1.0.0", "imbib/linked-file" | — | subprocess, fs | — |
| `source-service_get-page-image` | target(source_item_id), "imbib/linked-file" | — | subprocess, fs | — |
| `source-service_put-citation` | "source-citation@1.0.0", "impress/artifact/general" | "source-citation@1.0.0" | — | example ×1 |
| `source-service_put-content-chunk` | "content-chunk@1.0.0", "extraction-run@1.0.0", "impress/artifact/general", "source-citation@1.0.0" | "content-chunk@1.0.0" | — | example ×1 |
| `source-service_put-extraction-run` | "extraction-run@1.0.0", "impress/artifact/general" | "extraction-run@1.0.0" | — | example ×1 |
| `source-service_put-figure-region` | "figure-region@1.0.0", "extraction-run@1.0.0", "impress/artifact/general" | "figure-region@1.0.0" | — | example ×1 |
| `source-service_search-content-chunks` | any("full-text search inspects all indexed kinds before filtering to source chunks") | — | — | example ×1 |
| `store-query-service_get-item` | target(id) | — | — | — |
| `store-query-service_list-items` | any("the schema_ref argument names the kind") | — | — | example ×1 |
| `store-query-service_related-items` | target(id), any("walks references across kinds") | — | — | — |
| `store-query-service_search-all` | any("searches every kind") | — | — | — |
| `surface-demo-service_histogram` | — | — | — | example ×1 |
| `surface-demo-service_series` | — | — | — | example ×1 |
| `surface-selftest-service_run-selftest` | any("runs the catalogue's capabilities") | any("runs the catalogue's capabilities") | app("impress") | — |
| `triage-service_add-tag` | target(id) | target(id) | — | — |
| `triage-service_remove-tag` | target(id) | target(id) | — | — |
| `triage-service_set-flag` | target(id) | target(id) | — | — |
| `triage-service_set-starred` | target(id) | target(id) | — | — |
| `triage-service_set-status` | target(id) | target(id) | — | — |
| `vw-diagnostic-service_close-session` | "vw/diagnostic-session@1.0.0" | "vw/diagnostic-session@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
| `vw-diagnostic-service_create-session` | "vw/vehicle@1.0.0", "vw/configuration@1.0.0", "vw/diagnostic-session@1.0.0" | "vw/diagnostic-session@1.0.0", "vw/vehicle@1.0.0", "vw/configuration@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
| `vw-diagnostic-service_evaluate-session` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0", "vw/measurement@1.0.0", "vw/observation@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_get-capabilities` | — | — | — | example ×1 |
| `vw-diagnostic-service_get-photo` | "vw/photo-evidence@1.0.0", "content-blob@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_get-session` | "vw/diagnostic-session@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_ingest-photo` | "vw/diagnostic-session@1.0.0" | "vw/photo-evidence@1.0.0", "content-blob@1.0.0" | network, fs | — |
| `vw-diagnostic-service_list-applicable-procedures` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_list-sessions` | "vw/diagnostic-session@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_recommend-next-test` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0", "vw/measurement@1.0.0", "vw/observation@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_record-measurement` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0" | "vw/diagnostic-session@1.0.0", "vw/measurement@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
| `vw-diagnostic-service_record-observation` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0" | "vw/diagnostic-session@1.0.0", "vw/observation@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
| `vw-diagnostic-service_record-procedure-step` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0" | "vw/procedure-run@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
| `vw-diagnostic-service_search-photos` | "vw/photo-evidence@1.0.0" | — | — | example ×1 |
| `vw-diagnostic-service_start-procedure` | "vw/diagnostic-session@1.0.0", "vw/procedure-run@1.0.0" | "vw/procedure-run@1.0.0", "vw/command-receipt@1.0.0" | — | example ×1 |
<!-- verb-effects:end -->

## Exceptions: not verified by the spy, and why

The reason is the test's, not the author's: `needs a running app` (reach `app("…")`, verified at
run time by the call log once L1 lands), `leaves the process (…)` (an external reach the default
implementation cannot take headless), or `no example` (G3 writes them; the row leaves this table
when one lands).

<!-- verb-effects-exceptions:begin -->
| Verb | Reason |
|---|---|
| `capabilities-service_catalogue-surface` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `capabilities-service_list-verbs` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `capabilities-service_verb-surface` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `collection-service_migrate` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `collection-service_migration-status` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `collection-service_rollback` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `docs-import-service_add-watched-folder` | no example ran |
| `docs-import-service_import-directory` | no example ran |
| `docs-import-service_import-discovered` | no example ran |
| `history-service_calls` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_health` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_propose-workflows` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_replay` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_save-macro` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_trace` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `history-service_why` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-app-service_add-to-library` | needs a running app |
| `imbib-app-service_delete-annotation` | needs a running app |
| `imbib-app-service_delete-collection` | needs a running app |
| `imbib-app-service_delete-comment` | needs a running app |
| `imbib-app-service_delete-smart-searches` | needs a running app |
| `imbib-app-service_download-pdfs` | needs a running app |
| `imbib-app-service_get-logs` | needs a running app |
| `imbib-app-service_get-notes` | needs a running app |
| `imbib-app-service_open-manuscript-papers` | needs a running app |
| `imbib-app-service_recent-activity` | needs a running app |
| `imbib-app-service_resolve-identifier` | needs a running app |
| `imbib-app-service_search-sources` | needs a running app |
| `imbib-app-service_status` | needs a running app |
| `imbib-app-service_sync-nudge` | needs a running app |
| `imbib-app-service_sync-status` | needs a running app |
| `imbib-app-service_tag-artifact` | needs a running app |
| `imbib-app-service_update-notes` | needs a running app |
| `imbib-backup-service_restore-backup` | needs a running app |
| `imbib-eink-service_eink-folder-checklist` | leaves the process (device) |
| `imbib-eink-service_eink-import` | leaves the process (device, fs) |
| `imbib-eink-service_eink-import-document` | leaves the process (device, fs) |
| `imbib-eink-service_eink-list-unmatched` | leaves the process (device) |
| `imbib-eink-service_eink-plan` | leaves the process (device) |
| `imbib-eink-service_eink-reachable` | leaves the process (device) |
| `imbib-eink-service_eink-sync` | leaves the process (device, fs) |
| `imbib-library-service_duplicate-publications` | no example ran |
| `imbib-manuscripts-service_compile-manuscript` | needs a running app |
| `imbib-manuscripts-service_create-manuscript` | needs a running app |
| `imbib-manuscripts-service_create-manuscript-from-template` | needs a running app |
| `imbib-manuscripts-service_get-manuscript` | needs a running app |
| `imbib-manuscripts-service_list-manuscripts` | needs a running app |
| `imbib-manuscripts-service_list-templates` | needs a running app |
| `imbib-manuscripts-service_write-manuscript-body` | needs a running app |
| `imbib-semantic-service_get-paper-chunks` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-semantic-service_list-indexed-papers` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-semantic-service_search-papers` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-tags-service_add-tag` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-tags-service_list-tags-with-counts` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-tags-service_remove-tag` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `imbib-undo-service_recent-undo-groups` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `impart-service_add-message` | needs a running app |
| `impart-service_branch-conversation` | needs a running app |
| `impart-service_create-conversation` | needs a running app |
| `impart-service_get-conversation` | needs a running app |
| `impart-service_get-logs` | needs a running app |
| `impart-service_list-conversations` | needs a running app |
| `impart-service_record-artifact` | needs a running app |
| `impart-service_record-decision` | needs a running app |
| `impart-service_status` | needs a running app |
| `impart-service_update-conversation` | needs a running app |
| `impel-service_retention-status` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `implore-service_create-figure` | needs a running app |
| `implore-service_delete-figure` | needs a running app |
| `implore-service_export-figure` | needs a running app |
| `implore-service_export-figure-data` | needs a running app |
| `implore-service_get-dataset` | needs a running app |
| `implore-service_get-figure` | needs a running app |
| `implore-service_get-logs` | needs a running app |
| `implore-service_list-datasets` | needs a running app |
| `implore-service_list-figures` | needs a running app |
| `implore-service_plot-histogram` | needs a running app |
| `implore-service_plot-series` | needs a running app |
| `implore-service_rg-batch` | needs a running app |
| `implore-service_rg-cascade-plot` | needs a running app |
| `implore-service_rg-colormaps` | needs a running app |
| `implore-service_rg-control` | needs a running app |
| `implore-service_rg-load` | needs a running app |
| `implore-service_rg-slice-png` | needs a running app |
| `implore-service_rg-slice-raw` | needs a running app |
| `implore-service_rg-slice-save` | needs a running app |
| `implore-service_rg-state` | needs a running app |
| `implore-service_rg-statistics` | needs a running app |
| `implore-service_status` | needs a running app |
| `implore-service_update-figure` | needs a running app |
| `impress-ai-service_ai-health` | leaves the process (network) |
| `impress-ai-service_list-models` | leaves the process (provider) |
| `impress-ai-service_list-providers` | leaves the process (provider, fs) |
| `impress-ai-service_mint-pairing-link` | leaves the process (network) |
| `impress-ai-service_provider-health` | leaves the process (provider) |
| `impress-bridges-service_add-papers-from-conversation` | needs a running app |
| `impress-bridges-service_cite-multiple` | needs a running app |
| `impress-bridges-service_cite-paper` | needs a running app |
| `impress-bridges-service_conversation-decisions` | needs a running app |
| `impress-bridges-service_conversation-to-outline` | needs a running app |
| `impress-bridges-service_embed-figure` | needs a running app |
| `impress-bridges-service_embed-figure-reference` | needs a running app |
| `impress-bridges-service_export-conversation-citations` | needs a running app |
| `impress-bridges-service_extract-papers-from-conversation` | needs a running app |
| `impress-bridges-service_get-citation-suggestions` | needs a running app |
| `impress-bridges-service_list-available-figures` | needs a running app |
| `impress-bridges-service_sync-figure` | needs a running app |
| `impress-scenario-service_scenario-run` | leaves the process (network) |
| `imprint-app-service_create-comment` | needs a running app |
| `imprint-app-service_create-document` | needs a running app |
| `imprint-app-service_delete-comment` | needs a running app |
| `imprint-app-service_delete-text` | needs a running app |
| `imprint-app-service_get-bibliography` | needs a running app |
| `imprint-app-service_get-content` | needs a running app |
| `imprint-app-service_get-logs` | needs a running app |
| `imprint-app-service_get-pdf` | needs a running app |
| `imprint-app-service_insert-text` | needs a running app |
| `imprint-app-service_list-comments` | needs a running app |
| `imprint-app-service_replace` | needs a running app |
| `imprint-app-service_status` | needs a running app |
| `imprint-app-service_update-comment` | needs a running app |
| `imprint-app-service_update-document` | needs a running app |
| `imprint-app-service_update-metadata` | needs a running app |
| `imprint-manuscript-service_compile-latex` | leaves the process (subprocess) |
| `imprint-project-service_project-build` | leaves the process (subprocess, fs) |
| `imprint-project-service_project-figure-preview` | leaves the process (subprocess, fs) |
| `imprint-project-service_project-render-figure` | leaves the process (subprocess, fs) |
| `imprint-selftest-service_run-selftest` | needs a running app |
| `layout-selftest-service_run-selftest` | needs a running app |
| `memory-service_memory-status` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `parsers-service_resolve-publisher-pdf` | leaves the process (network) |
| `settings-service_get` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `settings-service_list` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `settings-service_reset` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `settings-service_set` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `settings-service_surface` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `source-service_get-figure-image` | leaves the process (subprocess, fs) |
| `source-service_get-page-image` | leaves the process (subprocess, fs) |
| `store-query-service_get-item` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `store-query-service_related-items` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `store-query-service_search-all` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `surface-selftest-service_run-selftest` | needs a running app |
| `triage-service_add-tag` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `triage-service_remove-tag` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `triage-service_set-flag` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `triage-service_set-starred` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `triage-service_set-status` | exercised, unobserved (example ran, spy saw no declared read or write) |
| `vw-diagnostic-service_ingest-photo` | leaves the process (network, fs) |
<!-- verb-effects-exceptions:end -->
