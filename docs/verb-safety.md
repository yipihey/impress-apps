# Verb safety: what each verb may do, as declared and as checked

**Decided by:** ADR-0034 D1 (the descriptor's declared `safety`), plan-auto-gui-and-self-docs.md
table 4 and appendix A4 (the classes and their evidence), D-G4 (this file as a marker table).
**Executed by:** plan-verb-pipeline-and-transport.md P1.
**Enforced by:** `crates/impress-capabilities/tests/descriptor.rs` — the linked inventory's
declared classes against the table below, both ways; a verb with no row, a row with no verb, or a
class that disagrees fails the test and prints the row as it should read.

Every `#[impress_method]` carries a safety class on its descriptor
(`impress_service_core::SafetyClass`), declared once per service as
`impress_service_impl! { safety = … }` and overridden per method with
`#[impress_method(safety = …)]` on the trait. The class is what a policy layer (ADR-0034 D3)
and an MCP client's `annotations` read, so it must be true — and "true" is decided here,
by evidence, not by the declaration. The table is data: edit a row and the test expects
the declaration to follow, never the other way round.

The vocabulary, from the plan's table 4:

- `read_only` — reads the store or computes; changes nothing an undo would need.
- `mutating` — writes rows or files in a way the suite can account for.
- `destructive` — deletes or overwrites with no inverse the service offers.
- `external` — leaves the process: a running app over HTTP, the network, a device, a subprocess,
  an AI provider. The secondary class in *Evidence* (`E/M`, `E/D`, `E/R` in the plan) says what
  the external side does; the descriptor carries only `external`, and the MCP projection reads
  it conservatively (`destructiveHint: true`, `openWorldHint: true`).

Counts today (semantic-search feature on): 196 read-only, 136 mutating,
33 destructive, 104 external — 469 verbs. Without that feature,
`imbib-semantic-service`'s three read-only verbs are unlinked and the totals
are 3 fewer (193/136/33/104 — 466).
*Evidence* is appendix A4's file:line where the plan recorded one (every destructive verb and
every verb whose class is not obvious from its name or doc), else `name/doc`.

## Per-service defaults

The class most of a service's verbs share is the service's `safety =` default; the rest are
per-method overrides. Derived from the table below, recorded here for reading.

| Service | Default | Verbs | Overrides |
|---|---|---:|---:|
| `collection-service` | mutating | 12 | 5 |
| `docs-import-service` | mutating | 10 | 5 |
| `history-service` | read_only | 6 | 2 |
| `imbib-annotations-service` | read_only | 9 | 4 |
| `imbib-app-service` | external | 17 | 0 |
| `imbib-artifacts-service` | read_only | 9 | 4 |
| `imbib-backup-service` | destructive | 6 | 4 |
| `imbib-eink-service` | mutating | 22 | 15 |
| `imbib-library-service` | read_only | 44 | 19 |
| `imbib-manuscripts-service` | external | 7 | 0 |
| `imbib-scix-service` | read_only | 7 | 3 |
| `imbib-search-service` | read_only | 10 | 1 |
| `imbib-semantic-service` | read_only | 3 | 0 |
| `imbib-tags-service` | mutating | 10 | 5 |
| `imbib-text-service` | read_only | 5 | 0 |
| `imbib-undo-service` | mutating | 3 | 1 |
| `impart-service` | external | 10 | 0 |
| `impel-service` | read_only | 6 | 2 |
| `implore-service` | external | 20 | 0 |
| `impress-ai-service` | read_only | 16 | 10 |
| `impress-bridges-service` | external | 18 | 6 |
| `impress-surface-service` | read_only | 15 | 6 |
| `imprint-app-service` | external | 15 | 0 |
| `imprint-manuscript-service` | read_only | 17 | 4 |
| `imprint-project-service` | mutating | 30 | 17 |
| `imprint-selftest-service` | external | 1 | 0 |
| `imprint-text-service` | read_only | 5 | 0 |
| `imprint-throughline-service` | mutating | 9 | 5 |
| `layout-selftest-service` | external | 1 | 0 |
| `layout-service` | mutating | 36 | 11 |
| `manuscript-collab-service` | read_only | 4 | 1 |
| `memory-service` | mutating | 7 | 4 |
| `parsers-service` | read_only | 6 | 0 |
| `settings-service` | read_only | 6 | 2 |
| `smart-search-service` | read_only | 10 | 0 |
| `source-service` | mutating | 9 | 5 |
| `store-query-service` | read_only | 4 | 0 |
| `surface-demo-service` | read_only | 2 | 0 |
| `surface-selftest-service` | external | 1 | 0 |
| `triage-service` | mutating | 5 | 0 |
| `vw-diagnostic-service` | read_only | 15 | 7 |

## Every verb

<!-- verb-safety:begin -->
| Tool | Class | Evidence |
|---|---|---|
| `capabilities-service_catalogue-surface` | read_only | name/doc |
| `capabilities-service_impact` | read_only | name/doc |
| `capabilities-service_list-verbs` | read_only | name/doc |
| `capabilities-service_verb-surface` | read_only | name/doc |
| `collection-service_add-members` | mutating | name/doc |
| `collection-service_create` | mutating | name/doc |
| `collection-service_delete` | destructive | crates/impress-store-service/src/collection_service.rs:577 collection_ops::delete -> crates/impress-core/src/collection_ops.rs:1035 store.delete(id); kernel returns a restore snapshot but the service drops it (collect… |
| `collection-service_member-counts` | read_only | name/doc |
| `collection-service_migrate` | mutating | name/doc |
| `collection-service_migration-status` | read_only | name/doc |
| `collection-service_remove-members` | mutating | name/doc |
| `collection-service_rename` | mutating | name/doc |
| `collection-service_reorder` | mutating | name/doc |
| `collection-service_reparent` | mutating | name/doc |
| `collection-service_rollback` | destructive | crates/impress-store-service/src/collection_service.rs:777 -> crates/impress-core/src/collection_migration.rs:450 raw `UPDATE items SET schema_ref, payload` restoring frozen payloads (post-migration edits discarded) a… |
| `collection-service_tree` | read_only | name/doc |
| `docs-import-service_add-watched-folder` | mutating | name/doc |
| `docs-import-service_finish-watched-scan` | mutating | name/doc |
| `docs-import-service_import-directory` | destructive | crates/impress-store-service/src/docs_import_service.rs:893 fs::read every file, then (non-dry) collection_ops::create (docs_import_service.rs:1008), insert_document store.insert (docs_import_service.rs:1583) or updat… |
| `docs-import-service_import-discovered` | mutating | name/doc |
| `docs-import-service_list-watched-files` | read_only | name/doc |
| `docs-import-service_list-watched-folders` | read_only | name/doc |
| `docs-import-service_prune-empty-manuscripts` | destructive | crates/impress-store-service/src/docs_import_service.rs:1148 `if apply { store.delete(item.id) }` on every manuscript whose trimmed body_content <= max_body_chars; apply is a required bool with no default, so report-o… |
| `docs-import-service_record-produced-rows` | mutating | name/doc |
| `docs-import-service_remove-watched-folder` | destructive | crates/impress-store-service/src/docs_import_service.rs:1296 -> crates/impress-core/src/watched_folder_ops.rs:685-690 store.delete of every watched-file row when delete_file_rows, then store.delete(folder); no undo; d… |
| `docs-import-service_update-watched-folder` | mutating | name/doc |
| `history-service_calls` | read_only | name/doc |
| `history-service_health` | read_only | name/doc |
| `history-service_replay` | mutating | name/doc |
| `history-service_save-macro` | mutating | name/doc |
| `history-service_trace` | read_only | name/doc |
| `history-service_why` | read_only | name/doc |
| `imbib-annotations-service_count-annotations` | read_only | name/doc |
| `imbib-annotations-service_create-annotation` | mutating | name/doc |
| `imbib-annotations-service_create-comment` | mutating | name/doc |
| `imbib-annotations-service_create-comment-on-item` | mutating | name/doc |
| `imbib-annotations-service_list-annotations` | read_only | name/doc |
| `imbib-annotations-service_list-comments` | read_only | name/doc |
| `imbib-annotations-service_list-comments-for-item` | read_only | name/doc |
| `imbib-annotations-service_list-comments-since` | read_only | name/doc |
| `imbib-annotations-service_update-comment` | destructive | crates/imbib-service/src/annotations_service.rs:318 -> crates/imbib-core/src/unified/store_api.rs:3278-3288 store.update (NOT update_with_undo) overwrites the comment's `text` wholesale; prior text is gone and nothing… |
| `imbib-app-service_add-to-library` | external | E/M: name/doc |
| `imbib-app-service_delete-annotation` | external | E/D: crates/imbib-service/src/app_service.rs:349 default refuses; HTTP DELETE /api/annotations/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1476 store.deleteIt… |
| `imbib-app-service_delete-collection` | external | E/D: crates/imbib-service/src/app_service.rs:357 default refuses; HTTP DELETE /api/collections/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:758 store.deleteIte… |
| `imbib-app-service_delete-comment` | external | E/D: crates/imbib-service/src/app_service.rs:353 default refuses; HTTP DELETE /api/comments/{id} -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1235 -> crates/imbib-c… |
| `imbib-app-service_delete-smart-searches` | external | E/D: crates/imbib-service/src/app_service.rs:361 default refuses; HTTP DELETE /api/smart-searches (apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/HTTPAutomationRouter.swift:5001-5013) -> RustSt… |
| `imbib-app-service_download-pdfs` | external | E/M: name/doc |
| `imbib-app-service_get-logs` | external | E/R: name/doc |
| `imbib-app-service_get-notes` | external | E/R: name/doc |
| `imbib-app-service_open-manuscript-papers` | external | E/M: name/doc |
| `imbib-app-service_recent-activity` | external | E/R: name/doc |
| `imbib-app-service_resolve-identifier` | external | E/M: crates/imbib-service/src/app_service.rs:369 default refuses; HTTP POST /api/papers/resolve (apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/HTTPAutomationRouter.swift:2564-2585 handleResolv… |
| `imbib-app-service_search-sources` | external | E/R: name/doc |
| `imbib-app-service_status` | external | E/R: name/doc |
| `imbib-app-service_sync-nudge` | external | E/M: name/doc |
| `imbib-app-service_sync-status` | external | E/R: name/doc |
| `imbib-app-service_tag-artifact` | external | E/M: name/doc |
| `imbib-app-service_update-notes` | external | E/D: crates/imbib-service/src/app_service.rs:345 default refuses; HTTP PUT /api/papers/{citeKey}/notes -> apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Automation/AutomationService.swift:1509 store.updat… |
| `imbib-artifacts-service_count-artifacts` | read_only | name/doc |
| `imbib-artifacts-service_create-artifact` | mutating | name/doc |
| `imbib-artifacts-service_delete-artifact` | destructive | crates/imbib-service/src/artifacts_service.rs:312 -> crates/imbib-core/src/unified/store_api.rs:4213 store.delete, no snapshot, no operation-log entry. HTTP backend routes the same verb to the running app (imbib-servi… |
| `imbib-artifacts-service_get-artifact` | read_only | name/doc |
| `imbib-artifacts-service_get-artifact-relations` | read_only | name/doc |
| `imbib-artifacts-service_link-artifact-to-publication` | mutating | name/doc |
| `imbib-artifacts-service_list-artifacts` | read_only | name/doc |
| `imbib-artifacts-service_search-artifacts` | read_only | name/doc |
| `imbib-artifacts-service_update-artifact` | mutating | name/doc |
| `imbib-backup-service_create-backup` | mutating | name/doc |
| `imbib-backup-service_delete-backup` | destructive | crates/imbib-service/src/backup_service.rs:281 -> crates/imbib-core/src/unified/backup_api.rs:247 backup::delete_backup removes the file and its manifest; undo covers rows, not files. HTTP backend routes the same verb… |
| `imbib-backup-service_inspect-backup` | read_only | name/doc |
| `imbib-backup-service_list-backups` | read_only | name/doc |
| `imbib-backup-service_prune-backups` | destructive | crates/imbib-service/src/backup_service.rs:288 -> crates/imbib-core/src/unified/backup_api.rs:253 deletes every backup beyond the newest `keep` (keep=0 deletes all); files, not undoable. HTTP backend routes the same v… |
| `imbib-backup-service_restore-backup` | external | E/D: crates/imbib-service/src/backup_service.rs:262 default impl REFUSES (returns error, writes nothing); HTTP backend forwards to POST /api/backups/restore which replaces the entire shared store (imprint + impel data too)… |
| `imbib-eink-service_eink-append-notes` | mutating | name/doc |
| `imbib-eink-service_eink-awaiting-source` | read_only | name/doc |
| `imbib-eink-service_eink-complete-ocr` | mutating | name/doc |
| `imbib-eink-service_eink-configure-device` | mutating | name/doc |
| `imbib-eink-service_eink-devices` | read_only | name/doc |
| `imbib-eink-service_eink-folder-checklist` | external | E/R: crates/imbib-service/src/eink_service.rs:802 -> crates/imbib-core/src/eink/apply.rs:1302 calls eink_plan, i.e. a LIVE tablet listing over USB; name reads like a local list. |
| `imbib-eink-service_eink-import` | external | E/M: name/doc |
| `imbib-eink-service_eink-import-document` | external | E/M: name/doc |
| `imbib-eink-service_eink-list-annotations` | read_only | name/doc |
| `imbib-eink-service_eink-list-mirrored` | read_only | name/doc |
| `imbib-eink-service_eink-list-unmatched` | external | E/R: name/doc |
| `imbib-eink-service_eink-mark` | mutating | name/doc |
| `imbib-eink-service_eink-note-source-error` | mutating | crates/imbib-service/src/eink_service.rs:913 -> crates/imbib-core/src/eink/store.rs:679 eink_note_source_attempt writes last_error/attempts on the mirror row; reads like a log message but is a store write. HTTP backen… |
| `imbib-eink-service_eink-pending-ocr` | read_only | name/doc |
| `imbib-eink-service_eink-plan` | external | E/R: name/doc |
| `imbib-eink-service_eink-reachable` | external | E/R: name/doc |
| `imbib-eink-service_eink-remove-device` | destructive | crates/imbib-service/src/eink_service.rs:654 -> crates/imbib-core/src/eink/store.rs:476-491 store.delete on every mirror row for the device and the device row; no snapshot/undo. Tablet untouched. HTTP backend routes t… |
| `imbib-eink-service_eink-resend` | mutating | name/doc |
| `imbib-eink-service_eink-search-annotations` | read_only | name/doc |
| `imbib-eink-service_eink-status` | read_only | name/doc |
| `imbib-eink-service_eink-sync` | external | E/M: name/doc |
| `imbib-eink-service_eink-unmark` | mutating | name/doc |
| `imbib-library-service_add-linked-file` | mutating | name/doc |
| `imbib-library-service_add-to-collection` | mutating | name/doc |
| `imbib-library-service_count-flagged` | read_only | name/doc |
| `imbib-library-service_count-pdfs` | read_only | name/doc |
| `imbib-library-service_count-publications` | read_only | name/doc |
| `imbib-library-service_count-starred` | read_only | name/doc |
| `imbib-library-service_count-unread` | read_only | name/doc |
| `imbib-library-service_create-collection` | mutating | name/doc |
| `imbib-library-service_create-library` | mutating | name/doc |
| `imbib-library-service_create-muted-item` | mutating | name/doc |
| `imbib-library-service_deduplicate-library` | destructive | crates/imbib-service/src/library_service.rs:1075 -> crates/imbib-core/src/unified/store_api.rs:2527-2584 finds dup DOI/arXiv/cite-key rows within library and store.delete()s them outright: no snapshot, no operation-lo… |
| `imbib-library-service_delete-library-undoable` | destructive | crates/imbib-service/src/library_service.rs:769 store.delete_library_undoable -> crates/imbib-core/src/unified/store_api.rs:1811-1849 store.delete(library); child pubs/collections get parent NULL; snapshot is RETURNED… |
| `imbib-library-service_delete-publications-undoable` | destructive | crates/imbib-service/src/library_service.rs:1044 -> crates/imbib-core/src/unified/store_api.rs:1744-1762 store.delete per id; snapshots returned but discarded by service (only .len() used) and never written to the ope… |
| `imbib-library-service_dismiss-paper` | mutating | crates/imbib-service/src/library_service.rs:1079 -> crates/imbib-core/src/unified/store_api.rs:2337-2355 store.insert of an imbib/dismissed-paper identifier TOMBSTONE; it does NOT move any publication to the Dismissed… |
| `imbib-library-service_duplicate-publications` | mutating | name/doc |
| `imbib-library-service_export-all-bibtex` | read_only | name/doc |
| `imbib-library-service_export-bibtex` | read_only | name/doc |
| `imbib-library-service_get-default-library` | read_only | name/doc |
| `imbib-library-service_get-inbox-library` | read_only | name/doc |
| `imbib-library-service_get-publication` | read_only | name/doc |
| `imbib-library-service_get-publication-detail` | read_only | name/doc |
| `imbib-library-service_import-bibtex` | mutating | name/doc |
| `imbib-library-service_import-papers` | mutating | crates/imbib-service/src/library_service.rs:1135 -> crates/imbib-core/src/unified/store_api.rs:1335-1499 batch_import_search_results: parses the BibTeX the CALLER supplies, dedups, insert_batch; NO network fetch in th… |
| `imbib-library-service_is-paper-dismissed` | read_only | name/doc |
| `imbib-library-service_list-collection-members` | read_only | name/doc |
| `imbib-library-service_list-collections` | read_only | name/doc |
| `imbib-library-service_list-dismissed-papers` | read_only | name/doc |
| `imbib-library-service_list-libraries` | read_only | name/doc |
| `imbib-library-service_list-linked-files` | read_only | name/doc |
| `imbib-library-service_list-muted-items` | read_only | name/doc |
| `imbib-library-service_list-publications` | read_only | name/doc |
| `imbib-library-service_move-publications` | mutating | name/doc |
| `imbib-library-service_purge-dismissed-from-collection` | mutating | crates/imbib-service/src/library_service.rs:880 -> crates/imbib-core/src/unified/store_api.rs:967-1044: finds members whose ids match dismissed tombstones and calls remove_from_collection (undo-logged membership remov… |
| `imbib-library-service_query-publications` | read_only | name/doc |
| `imbib-library-service_query-recent` | read_only | name/doc |
| `imbib-library-service_query-starred` | read_only | name/doc |
| `imbib-library-service_query-unread` | read_only | name/doc |
| `imbib-library-service_remove-from-collection` | mutating | name/doc |
| `imbib-library-service_search-publications` | read_only | name/doc |
| `imbib-library-service_set-flag` | mutating | name/doc |
| `imbib-library-service_set-library-default` | mutating | name/doc |
| `imbib-library-service_set-read` | mutating | name/doc |
| `imbib-library-service_set-starred` | mutating | name/doc |
| `imbib-library-service_sidebar-view` | read_only | name/doc |
| `imbib-manuscripts-service_compile-manuscript` | external | E/M: name/doc |
| `imbib-manuscripts-service_create-manuscript` | external | E/M: crates/imbib-service/src/manuscripts_service.rs:238 default refuses; HTTP POST /api/manuscripts creates a row (crates/imbib-service-http/src/lib.rs:1507). Doc does not say it needs the app. |
| `imbib-manuscripts-service_create-manuscript-from-template` | external | E/M: crates/imbib-service/src/manuscripts_service.rs:272 default refuses; HTTP creates a scaffolded row (crates/imbib-service-http/src/lib.rs:1560). Needs-app not stated. |
| `imbib-manuscripts-service_get-manuscript` | external | E/R: crates/imbib-service/src/manuscripts_service.rs:234 default refuses; HTTP GET /api/manuscripts/{id} (crates/imbib-service-http/src/lib.rs:1498). Needs-app not stated in doc. |
| `imbib-manuscripts-service_list-manuscripts` | external | E/R: crates/imbib-service/src/manuscripts_service.rs:230 default REFUSES even this read (rows are in the shared store but the service will not read them); HTTP backend GET /api/manuscripts (crates/imbib-service-http/src/li… |
| `imbib-manuscripts-service_list-templates` | external | E/R: crates/imbib-service/src/manuscripts_service.rs:268 default refuses; HTTP GET templates (crates/imbib-service-http/src/lib.rs:1554). Needs-app not stated. |
| `imbib-manuscripts-service_write-manuscript-body` | external | E/D: crates/imbib-service/src/manuscripts_service.rs:246 default refuses; HTTP (crates/imbib-service-http/src/lib.rs:1520) replaces the ENTIRE body (compare-and-set on content_hash; Automerge keeps history but the verb ove… |
| `imbib-scix-service_add-to-scix-library` | mutating | crates/imbib-service/src/scix_service.rs:160 -> crates/imbib-core/src/unified/store_api.rs:3056 local membership edge only on the store path; HTTP path may sync to ADS via the app's SciXLibraryService. Fallback descri… |
| `imbib-scix-service_count-scix-library-publications` | read_only | crates/imbib-service/src/scix_service.rs:217 -> crates/imbib-core/src/unified/store_api.rs:2852 local count. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-serv… |
| `imbib-scix-service_create-scix-library` | mutating | crates/imbib-service/src/scix_service.rs:138 -> crates/imbib-core/src/unified/store_api.rs:2993 inserts a LOCAL mirror row (remote_id supplied by caller); does not create anything on ADS. Fallback description. HTTP ba… |
| `imbib-scix-service_get-scix-library` | read_only | crates/imbib-service/src/scix_service.rs:130 -> crates/imbib-core/src/unified/store_api.rs:3039 local get. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-servic… |
| `imbib-scix-service_list-scix-libraries` | read_only | crates/imbib-service/src/scix_service.rs:121 -> crates/imbib-core/src/unified/store_api.rs:3015 query local imbib/scix-library rows; no ADS/SciX network call. Name suggests remote; fallback description. HTTP backend r… |
| `imbib-scix-service_query-scix-library-publications` | read_only | crates/imbib-service/src/scix_service.rs:194 -> crates/imbib-core/src/unified/store_api.rs:3115 local query. Fallback description; name suggests remote. HTTP backend routes the same verb to the running app (imbib-serv… |
| `imbib-scix-service_remove-from-scix-library` | mutating | crates/imbib-service/src/scix_service.rs:177 -> crates/imbib-core/src/unified/store_api.rs:3079 local membership edge removal (no publication deleted); HTTP path DELETE /api/scix-libraries/{id}/papers may push to ADS.… |
| `imbib-search-service_create-smart-search` | mutating | name/doc |
| `imbib-search-service_find-by-arxiv` | read_only | name/doc |
| `imbib-search-service_find-by-bibcode` | read_only | name/doc |
| `imbib-search-service_find-by-cite-key` | read_only | name/doc |
| `imbib-search-service_find-by-doi` | read_only | name/doc |
| `imbib-search-service_find-by-identifiers-batch` | read_only | name/doc |
| `imbib-search-service_full-text-search` | read_only | name/doc |
| `imbib-search-service_get-smart-search` | read_only | name/doc |
| `imbib-search-service_list-smart-searches` | read_only | name/doc |
| `imbib-search-service_resolve-cite-key` | read_only | name/doc |
| `imbib-semantic-service_get-paper-chunks` | read_only | name/doc |
| `imbib-semantic-service_list-indexed-papers` | read_only | name/doc |
| `imbib-semantic-service_search-papers` | read_only | name/doc |
| `imbib-tags-service_add-tag` | mutating | name/doc |
| `imbib-tags-service_count-by-tag` | read_only | name/doc |
| `imbib-tags-service_create-tag` | mutating | name/doc |
| `imbib-tags-service_delete-tag-undoable` | destructive | crates/imbib-service/src/tags_service.rs:203 -> crates/imbib-core/src/unified/store_api.rs:1885-1917 delete_tag: store.delete of the definition + RemoveTag on every tagged publication; snapshot returned and DROPPED by… |
| `imbib-tags-service_list-tags` | read_only | name/doc |
| `imbib-tags-service_list-tags-with-counts` | read_only | name/doc |
| `imbib-tags-service_query-by-tag` | read_only | name/doc |
| `imbib-tags-service_remove-tag` | mutating | name/doc |
| `imbib-tags-service_rename-tag` | mutating | name/doc |
| `imbib-tags-service_update-tag` | mutating | name/doc |
| `imbib-text-service_decode-latex` | read_only | name/doc |
| `imbib-text-service_expand-journal-macro` | read_only | name/doc |
| `imbib-text-service_generate-cite-key` | read_only | name/doc |
| `imbib-text-service_normalize-tag-path` | read_only | name/doc |
| `imbib-text-service_normalize-tag-segment` | read_only | name/doc |
| `imbib-undo-service_recent-undo-groups` | read_only | name/doc |
| `imbib-undo-service_undo-batch` | mutating | name/doc |
| `imbib-undo-service_undo-operation` | mutating | name/doc |
| `impart-service_add-message` | external | E/M: name/doc |
| `impart-service_branch-conversation` | external | E/M: name/doc |
| `impart-service_create-conversation` | external | E/M: name/doc |
| `impart-service_get-conversation` | external | name/doc |
| `impart-service_get-logs` | external | name/doc |
| `impart-service_list-conversations` | external | name/doc |
| `impart-service_record-artifact` | external | E/M: name/doc |
| `impart-service_record-decision` | external | E/M: name/doc |
| `impart-service_status` | external | name/doc |
| `impart-service_update-conversation` | external | E/M: name/doc |
| `impel-service_cancel-task` | destructive | crates/impel-service/src/lib.rs:660 TaskStoreApi::transition(Cancelled) (impel-core/src/task_store.rs:233 apply_operation on the shared SQLite store) then :674-699 walks dependents and cancels each pending one; cancel… |
| `impel-service_job-cancel` | destructive | crates/impel-service/src/lib.rs job_cancel → impress_core::job::request_cancel sets cancel_requested; the running executor stops the step (ADR-0034 D6) |
| `impel-service_job-events` | read_only | name/doc; reads task-event@1.0.0 rows |
| `impel-service_job-result` | read_only | name/doc |
| `impel-service_job-status` | read_only | name/doc |
| `impel-service_job-wait` | read_only | name/doc; long-poll over task-event@1.0.0, writes nothing |
| `impel-service_list-failed-tasks` | read_only | name/doc |
| `impel-service_list-pending-reviews` | read_only | name/doc |
| `impel-service_resolve-review` | mutating | name/doc |
| `impel-service_retention-status` | read_only | name/doc |
| `impel-service_scheduler-status` | read_only | name/doc |
| `implore-service_create-figure` | external | E/M: name/doc |
| `implore-service_export-figure` | external | E/M: name/doc |
| `implore-service_get-dataset` | external | name/doc |
| `implore-service_get-figure` | external | name/doc |
| `implore-service_get-logs` | external | name/doc |
| `implore-service_list-datasets` | external | name/doc |
| `implore-service_list-figures` | external | name/doc |
| `implore-service_plot-histogram` | external | crates/implore-service-http/src/lib.rs:335 POST /api/plot/histogram, but apps/implore/.../ImploreHTTPRouter.swift:143 only routes it under GET (routePOST:185 answers 404), so the verb returns None even with implore up… |
| `implore-service_plot-series` | external | crates/implore-service-http/src/lib.rs:324 POST /api/plot/svg, but ImploreHTTPRouter.swift:140 serves it as GET only (POST -> 404 at :185), so the verb always yields None; default lib.rs:488 refuses; app handler route… |
| `implore-service_rg-batch` | external | crates/implore-service-http/src/lib.rs:397 POST /api/rg/batch -> ImploreHTTPRouter.swift:876 computes one slice+PNG per position in memory (does not change viewer state, writes nothing); default lib.rs:521 refuse_json |
| `implore-service_rg-cascade-plot` | external | crates/implore-service-http/src/lib.rs:407 GET /api/rg/cascade_plot -> ImploreHTTPRouter.swift:990 viewer.dataset.plotCascadeStats() in memory, returns SVG, no writes; default lib.rs:527 refuse_json |
| `implore-service_rg-colormaps` | external | name/doc |
| `implore-service_rg-control` | external | name/doc |
| `implore-service_rg-load` | external | name/doc |
| `implore-service_rg-slice-png` | external | crates/implore-service-http/src/lib.rs:361 POST /api/rg/slice/png, but ImploreHTTPRouter.swift:126 serves it GET-only (POST -> 404) so the verb returns {error}; the GET handler :683 returns raw PNG bytes unless format… |
| `implore-service_rg-slice-raw` | external | crates/implore-service-http/src/lib.rs:383 POST /api/rg/slice/raw, but ImploreHTTPRouter.swift:129 routes it GET-only (POST -> 404) so the verb returns {error}; handler :769 reads slice values in memory; default lib.r… |
| `implore-service_rg-slice-save` | external | E/D: crates/implore-service-http/src/lib.rs:370 POST /api/rg/slice/save -> ImploreHTTPRouter.swift:751 pngData.write(to: path) overwrites any existing file at the caller-given path with no check; default lib.rs:512 refuse_… |
| `implore-service_rg-state` | external | name/doc |
| `implore-service_rg-statistics` | external | crates/implore-service-http/src/lib.rs:391 POST /api/rg/statistics, but ImploreHTTPRouter.swift:132 routes it GET-only (POST -> 404 at :185) so the verb returns {error}; handler :820 is pure in-memory stats; default l… |
| `implore-service_status` | external | name/doc |
| `impress-ai-service_ai-health` | external | crates/impress-ai-service/src/lib.rs:660 reqwest GET http://127.0.0.1:8787/api/health with 3 s timeout against the impress-ai daemon; returns daemon_reachable:false rather than an error when it is down; no store acces… |
| `impress-ai-service_ai-preferences` | read_only | name/doc |
| `impress-ai-service_create-conversation` | mutating | name/doc |
| `impress-ai-service_get-conversation` | read_only | name/doc |
| `impress-ai-service_list-conversations` | read_only | name/doc |
| `impress-ai-service_list-models` | external | crates/impress-ai-service/src/lib.rs:330 registry.models() -> crates/impress-ai/src/registry.rs:447: with no provider ensure_local_health() probes local hosts, then registry.rs:485 client.models().await hits the provi… |
| `impress-ai-service_list-providers` | external | crates/impress-ai-service/src/lib.rs:351 preferences().load() (file read) then lib.rs:356 registry.provider_states_probed() -> crates/impress-ai/src/registry.rs:599 ensure_local_health() probes each stale Rust-hosted… |
| `impress-ai-service_mint-pairing-link` | external | E/M: name/doc |
| `impress-ai-service_provider-health` | external | name/doc |
| `impress-ai-service_queue-message` | mutating | name/doc |
| `impress-ai-service_run-provenance` | read_only | name/doc |
| `impress-ai-service_select-model` | mutating | name/doc |
| `impress-ai-service_set-enabled-tools` | mutating | name/doc |
| `impress-ai-service_set-provider-endpoint` | mutating | name/doc |
| `impress-ai-service_task-provenance` | read_only | name/doc |
| `impress-ai-service_task-status` | read_only | name/doc |
| `impress-bridges-service_add-papers-from-conversation` | external | E/M: name/doc |
| `impress-bridges-service_cite-in-section` | mutating | name/doc |
| `impress-bridges-service_cite-multiple` | external | E/M: name/doc |
| `impress-bridges-service_cite-paper` | external | E/M: name/doc |
| `impress-bridges-service_conversation-decisions` | external | crates/impress-bridges-service/src/lib.rs:603 impart_service::service_instance().get_conversation over the BackendSlot (default impart-service/src/lib.rs:193 refuses -> []), returns just the summary field (lib.rs:606)… |
| `impress-bridges-service_conversation-to-outline` | external | crates/impress-bridges-service/src/lib.rs:616 impart_service::service_instance().get_conversation (default crates/impart-service/src/lib.rs:193 refuses -> None without impart; HTTP backend to running impart) then fixe… |
| `impress-bridges-service_embed-figure` | external | E/M: name/doc |
| `impress-bridges-service_embed-figure-reference` | external | E/M: name/doc |
| `impress-bridges-service_export-conversation-citations` | external | crates/impress-bridges-service/src/lib.rs:575 extract_papers_from_conversation -> impart_service::service_instance().get_conversation (default crates/impart-service/src/lib.rs:193 refuses -> empty string without impar… |
| `impress-bridges-service_extract-papers-from-conversation` | external | crates/impress-bridges-service/src/lib.rs:534 impart_service::service_instance().get_conversation — default crates/impart-service/src/lib.rs:193 refuses (returns []), HTTP backend crates/impart-service-http/src/lib.rs… |
| `impress-bridges-service_extract-papers-from-text` | read_only | name/doc |
| `impress-bridges-service_get-citation-suggestions` | external | crates/impress-bridges-service/src/lib.rs:418 imprint app_service_instance().get_content (default app_service.rs:240 refuses -> returns [] without imprint) then lib.rs:430 imbib search_service_instance().full_text_sea… |
| `impress-bridges-service_get-item` | read_only | name/doc |
| `impress-bridges-service_get-related` | read_only | name/doc |
| `impress-bridges-service_list-available-figures` | external | crates/impress-bridges-service/src/lib.rs:444 implore_service::service_instance().list_figures(None); default crates/implore-service/src/lib.rs:457 refuses and returns [] with implore closed, HTTP backend crates/implo… |
| `impress-bridges-service_resolve-artifact` | read_only | name/doc |
| `impress-bridges-service_search-all` | read_only | name/doc |
| `impress-bridges-service_sync-figure` | external | E/D: crates/impress-bridges-service/src/lib.rs:507 implore_service::service_instance().export_figure — default crates/implore-service/src/lib.rs:484 refuses (ok:false), HTTP backend crates/implore-service-http/src/lib.rs:3… |
| `impress-scenario-service_scenario-create` | mutating | name/doc |
| `impress-scenario-service_scenario-get` | read_only | name/doc |
| `impress-scenario-service_scenario-list` | read_only | name/doc |
| `impress-scenario-service_scenario-run` | external | a scenario's steps may call any verb, including a mutating or destructive one, and a Tier B run leaves the process over loopback HTTP |
| `impress-scenario-service_scenario-validate` | read_only | name/doc |
| `impress-surface-service_surface-create` | mutating | name/doc |
| `impress-surface-service_surface-delete` | destructive | crates/impress-surface-service/src/service.rs:744-772 surfaces_for_write().delete -> store.rs:378-394 store.delete() of every state row, every event row and the surface row (hard deletes, no operation/undo), then regi… |
| `impress-surface-service_surface-dispatch` | mutating | name/doc |
| `impress-surface-service_surface-events` | read_only | name/doc |
| `impress-surface-service_surface-examples` | read_only | name/doc |
| `impress-surface-service_surface-get` | read_only | name/doc |
| `impress-surface-service_surface-list` | read_only | name/doc |
| `impress-surface-service_surface-render` | read_only | crates/impress-surface-service/src/service.rs:851-886 registry.with -> runtime.bind_params + runtime.render; runtime.rs:999-1075 render only fills an in-memory source cache, never persist_state; runtime.rs:1631-1676 S… |
| `impress-surface-service_surface-schema` | read_only | name/doc |
| `impress-surface-service_surface-show` | mutating | name/doc |
| `impress-surface-service_surface-state-get` | read_only | name/doc |
| `impress-surface-service_surface-state-set` | mutating | name/doc |
| `impress-surface-service_surface-update` | mutating | name/doc |
| `impress-surface-service_surface-validate` | read_only | name/doc |
| `impress-surface-service_surface-wait` | read_only | name/doc |
| `impress-workflow-service_workflow-create` | mutating | name/doc |
| `impress-workflow-service_workflow-disable` | mutating | name/doc |
| `impress-workflow-service_workflow-dry-run` | read_only | name/doc |
| `impress-workflow-service_workflow-enable` | mutating | name/doc |
| `impress-workflow-service_workflow-get` | read_only | name/doc |
| `impress-workflow-service_workflow-list` | read_only | name/doc |
| `impress-workflow-service_workflow-validate` | read_only | name/doc |
| `imprint-app-service_create-comment` | external | E/M: name/doc |
| `imprint-app-service_create-document` | external | E/M: name/doc |
| `imprint-app-service_delete-comment` | external | E/D: crates/imprint-service/src/app_service.rs:301 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_delete-text` | external | E/D: crates/imprint-service/src/app_service.rs:250 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_get-bibliography` | external | name/doc |
| `imprint-app-service_get-content` | external | name/doc |
| `imprint-app-service_get-logs` | external | name/doc |
| `imprint-app-service_get-pdf` | external | E/M: name/doc |
| `imprint-app-service_insert-text` | external | E/M: name/doc |
| `imprint-app-service_list-comments` | external | name/doc |
| `imprint-app-service_replace` | external | E/D: crates/imprint-service/src/app_service.rs:255 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-app-service_status` | external | name/doc |
| `imprint-app-service_update-comment` | external | E/M: name/doc |
| `imprint-app-service_update-document` | external | E/M: name/doc |
| `imprint-app-service_update-metadata` | external | E/D: crates/imprint-service/src/app_service.rs:236 DEFAULT REFUSES (eprintln + empty/false; no store path); HTTP backend /Users/tabel/Projects/impress-apps/.claude/worktrees/agent-a9747ebb |
| `imprint-manuscript-service_compile-latex` | read_only | crates/imprint-service/src/manuscript_service.rs:463 spawn_blocking -> crates/imprint-service/src/handlers |
| `imprint-manuscript-service_compile-typst` | mutating | name/doc |
| `imprint-manuscript-service_delete-section` | destructive | crates/imprint-service/src/manuscript_service.rs:372 -> crates/imprint-service/src/handlers.rs:418 -> /Use |
| `imprint-manuscript-service_document-citations` | read_only | crates/imprint-service/src/manuscript_service.rs:399 -> crates/imprint-service/src/handlers.rs:433 -> /Use |
| `imprint-manuscript-service_document-outline` | read_only | crates/imprint-service/src/manuscript_service.rs:389 -> crates/imprint-service/src/handlers.rs:427 -> /Use |
| `imprint-manuscript-service_export-document` | read_only | name/doc |
| `imprint-manuscript-service_get-document` | read_only | name/doc |
| `imprint-manuscript-service_get-section` | read_only | name/doc |
| `imprint-manuscript-service_list-documents` | read_only | name/doc |
| `imprint-manuscript-service_list-sections` | read_only | name/doc |
| `imprint-manuscript-service_presentation-outline` | read_only | name/doc |
| `imprint-manuscript-service_put-section` | mutating | crates/imprint-service/src/manuscript_service.rs:351 -> crates/imprint-service/src/handlers.rs:400 handler |
| `imprint-manuscript-service_reorder-presentation-slide` | read_only | crates/imprint-service/src/manuscript_service.rs:428 -> crates/imprint-service/src/manuscript_service.rs:2 |
| `imprint-manuscript-service_replace-in-section` | destructive | crates/imprint-service/src/manuscript_service.rs:505 -> crates/imprint-service/src/handlers.rs:458 get_sec |
| `imprint-manuscript-service_search` | read_only | name/doc |
| `imprint-manuscript-service_search-in-text` | read_only | crates/imprint-service/src/manuscript_service.rs:409 -> crates/imprint-service/src/handlers.rs:437 -> /Use |
| `imprint-manuscript-service_set-presentation-slide-beat` | read_only | crates/imprint-service/src/manuscript_service.rs:437 -> crates/imprint-service/src/manuscript_service.rs:2 |
| `imprint-project-service_project-build` | external | E/M: name/doc |
| `imprint-project-service_project-build-output` | read_only | name/doc |
| `imprint-project-service_project-builds` | read_only | name/doc |
| `imprint-project-service_project-checkin` | mutating | name/doc |
| `imprint-project-service_project-checkout` | destructive | crates/imprint-service/src/project_service.rs:3213 imprint_core::project::materialize into the caller's directory (materialize.rs:145-208 write_atomic overwrites any existing file at a project path, removes files list… |
| `imprint-project-service_project-citations` | read_only | name/doc |
| `imprint-project-service_project-collect` | mutating | name/doc |
| `imprint-project-service_project-compile` | read_only | name/doc |
| `imprint-project-service_project-delete-file` | destructive | crates/imprint-service/src/project_service.rs:1267 mp::delete_file -> manuscript_project.rs:549-560 store.delete(row.id); no undo ring, blob bytes stay in the CAS; refuses external_source. |
| `imprint-project-service_project-export` | destructive | crates/imprint-service/src/project_service.rs:2464 imprint_core::project::export (materialize.rs:257-289): create_dir_all then write_atomic for every file plus manifest.json — unconditional overwrite of same-named fil… |
| `imprint-project-service_project-figure-preview` | external | crates/imprint-service/src/project_service.rs:1665 render_figure_impl(record=false) -> build.rs:727-790 render_figure: for veusz/shell runners it materialises the whole tree into <cache>/impress/imprint/project-previe… |
| `imprint-project-service_project-file` | read_only | name/doc |
| `imprint-project-service_project-graph` | read_only | name/doc |
| `imprint-project-service_project-import-directory` | mutating | name/doc |
| `imprint-project-service_project-materialize` | mutating | name/doc |
| `imprint-project-service_project-move-file` | mutating | name/doc |
| `imprint-project-service_project-new-figure` | mutating | name/doc |
| `imprint-project-service_project-outline` | read_only | name/doc |
| `imprint-project-service_project-put-file` | destructive | crates/imprint-service/src/project_service.rs:1242 mp::put_file -> manuscript_project.rs:370-470: an existing row's content/blob_ref/content_hash are replaced via store.update with no revision of the prior content (on… |
| `imprint-project-service_project-reading-list` | read_only | name/doc |
| `imprint-project-service_project-render-figure` | external | E/M: name/doc |
| `imprint-project-service_project-set-bibliography` | mutating | name/doc |
| `imprint-project-service_project-set-entry` | mutating | name/doc |
| `imprint-project-service_project-set-figure-build` | mutating | name/doc |
| `imprint-project-service_project-set-targets` | mutating | name/doc |
| `imprint-project-service_project-snapshot` | mutating | name/doc |
| `imprint-project-service_project-status` | read_only | name/doc |
| `imprint-project-service_project-sync-reading-collection` | mutating | name/doc |
| `imprint-project-service_project-tree` | read_only | name/doc |
| `imprint-project-service_project-uncollect` | mutating | name/doc |
| `imprint-selftest-service_run-selftest` | external | E/M: crates/imprint-selftest/src/service.rs:38 -> lib.rs:71-87; tier A (tier_a.rs:31,97) runs against tempfile workspaces / SqliteItemStore::open_in_memory only and compiles LaTeX via Tectonic and Typst in-process (tier_a.… |
| `imprint-text-service_compose-citation` | read_only | name/doc |
| `imprint-text-service_compose-heading` | read_only | name/doc |
| `imprint-text-service_extract-cite-key-usages` | read_only | name/doc |
| `imprint-text-service_extract-cite-keys` | read_only | name/doc |
| `imprint-text-service_format-latex` | read_only | name/doc |
| `imprint-throughline-service_create-throughline` | mutating | name/doc |
| `imprint-throughline-service_delete-throughline` | destructive | crates/imprint-service/src/throughline_service.rs:219 -> crates/imprint-service/src/throughline.rs:555 del |
| `imprint-throughline-service_get-anchor-states` | read_only | name/doc |
| `imprint-throughline-service_get-coverage` | read_only | name/doc |
| `imprint-throughline-service_get-throughline` | read_only | name/doc |
| `imprint-throughline-service_mark-supporting` | mutating | name/doc |
| `imprint-throughline-service_remove-anchor` | mutating | name/doc |
| `imprint-throughline-service_set-anchor` | mutating | name/doc |
| `imprint-throughline-service_update-throughline-source` | destructive | crates/imprint-service/src/throughline_service.rs:209 -> crates/imprint-service/src/throughline.rs:714 upd |
| `layout-selftest-service_run-selftest` | external | E/M: selftest.rs:48-62: tier 'a' (and any unrecognised tier) runs tier_a.rs:92-94 over a private SqliteItemStore::open_in_memory (no user-store rows); tier 'b' and the default 'all'/'' run tier_b.rs:389-458 which drives th… |
| `layout-service_apply-layout` | destructive | service.rs:1968-2061 verb_for_write -> apply_tree service.rs:1432-1453 session.replace (session.rs:376-378 drops both undo rings) + session.save overwrites the live arrangement row (store.rs:258); an ordinal/name that… |
| `layout-service_apply-preset` | destructive | service.rs:2347-2369 -> presets.ensure_shipped (seeds rows) -> apply_preset_row service.rs:1462-1495 -> apply_tree service.rs:1432-1453 session.replace (session.rs:376-378 resets both undo rings) then session.save ove… |
| `layout-service_bind-param` | mutating | name/doc |
| `layout-service_close` | mutating | service.rs:1570-1583 apply_verb(Verb::Close) removes a pane/subtree from the live tree -> store.rs:258 patch (Ephemeral); undo.rs:138 ARRANGEMENT ring so the close IS undoable (undo stack=arrangement) — the patch reve… |
| `layout-service_commit` | destructive | service.rs:1885-1928 as_kind 'layout'/'' delegates to save_layout (store.rs:401 save_named overwrite + commit_boundary), 'preset' delegates to save_preset (presets.rs:1316 overwrite + commit_boundary + DerivedFrom edg… |
| `layout-service_delete-layout` | destructive | service.rs:2063-2079 -> delete_named_as service.rs:1241-1274 (refuses presets, ensure_shipped seeds first) -> store.rs:459-467 store.delete(row.id) hard delete of the named layout row, operations cascade, tombstone ca… |
| `layout-service_detach` | mutating | name/doc |
| `layout-service_focus` | mutating | name/doc |
| `layout-service_focus-direction` | mutating | name/doc |
| `layout-service_get-channel` | read_only | name/doc |
| `layout-service_get-layout` | mutating | the store spy (crates/impress-capabilities/tests/effects.rs) observed a write to impress/ui/layout@1.0.0: a device with no live row gets the default layout written on first read; idempotent thereafter |
| `layout-service_get-pane` | read_only | name/doc |
| `layout-service_list-layouts` | mutating | the store spy observed a write to impress/ui/preset@1.0.0: the first call seeds the shipped presets (ensure_shipped_presets); idempotent thereafter |
| `layout-service_list-presets` | read_only | name/doc |
| `layout-service_maximize` | mutating | name/doc |
| `layout-service_move-tile` | mutating | name/doc |
| `layout-service_redo` | mutating | name/doc |
| `layout-service_reset-preset` | destructive | service.rs:2445-2477 layout_store_for_write (refuses store-unavailable on fallback store) -> presets.rs:1373-1395 reset -> presets.rs:1316-1368 save patches layout/queries/roles/purpose/version of the user-edited pres… |
| `layout-service_resize` | mutating | name/doc |
| `layout-service_resolve-reference` | read_only | name/doc |
| `layout-service_restore` | mutating | name/doc |
| `layout-service_save-layout` | destructive | service.rs:1930-1966 verb_for_write -> store.rs:401-443 save_named inserts a new row or PATCHES the existing same-named row's layout/purpose (Ephemerality::Commit, durable) — an existing name is overwritten with no un… |
| `layout-service_save-preset` | destructive | service.rs:2371-2443 with_session_for_write -> presets.rs:1316-1368 save inserts a new preset row or PATCHES an existing one (including a shipped preset) with the live tree, Durable; then session.commit_boundary() (se… |
| `layout-service_select` | mutating | name/doc |
| `layout-service_set-channel` | mutating | name/doc |
| `layout-service_set-collapsed` | mutating | name/doc |
| `layout-service_set-container-kind` | mutating | name/doc |
| `layout-service_set-default-channel` | mutating | name/doc |
| `layout-service_set-pane` | mutating | name/doc |
| `layout-service_set-query` | mutating | name/doc |
| `layout-service_set-role` | mutating | name/doc |
| `layout-service_set-view-kind` | mutating | name/doc |
| `layout-service_set-window-geometry` | mutating | name/doc |
| `layout-service_split` | mutating | name/doc |
| `layout-service_swap` | mutating | name/doc |
| `layout-service_undo` | mutating | name/doc |
| `manuscript-collab-service_commit-manuscript-body` | mutating | name/doc |
| `manuscript-collab-service_manuscript-change-history` | read_only | name/doc |
| `manuscript-collab-service_manuscript-heads` | read_only | name/doc |
| `manuscript-collab-service_manuscript-text-at` | read_only | name/doc |
| `memory-service_confirm-claim` | mutating | name/doc |
| `memory-service_forget` | destructive | crates/impress-memory-service/src/lib.rs:1349-1406 store.apply_operation SetPayload(NO_RECALL_FIELD=true, Durable/Editorial) — a soft hide, the row and edges stay; but no verb un-forgets it (only a direct store edit),… |
| `memory-service_memory-brief` | read_only | name/doc |
| `memory-service_memory-status` | read_only | name/doc |
| `memory-service_recall` | read_only | name/doc |
| `memory-service_remember` | mutating | name/doc |
| `memory-service_supersede-claim` | mutating | name/doc |
| `parsers-service_decode-mime-header` | read_only | name/doc |
| `parsers-service_decode-quoted-printable` | read_only | name/doc |
| `parsers-service_extract-landing-page-pdf` | read_only | name/doc |
| `parsers-service_list-publisher-rules` | read_only | name/doc |
| `parsers-service_parse-mbox` | read_only | name/doc |
| `parsers-service_resolve-publisher-pdf` | read_only | name/doc |
| `settings-service_get` | read_only | name/doc |
| `settings-service_list` | read_only | name/doc |
| `settings-service_reset` | mutating | `settings_service.rs` — forgets a stored value in a scope file; the default stands and the file is rewritten atomically |
| `settings-service_schema` | read_only | name/doc |
| `settings-service_set` | mutating | `settings_service.rs` — writes one key into `<workspace>/settings/<scope>.json` (or the synced row) under a flock |
| `settings-service_surface` | read_only | name/doc |
| `smart-search-service_build-ads-query` | read_only | name/doc |
| `smart-search-service_classify-search-input` | read_only | name/doc |
| `smart-search-service_clean-ads-query` | read_only | name/doc |
| `smart-search-service_extract-page-identifiers` | read_only | name/doc |
| `smart-search-service_free-text-extraction-prompt` | read_only | name/doc |
| `smart-search-service_normalize-ads-query` | read_only | name/doc |
| `smart-search-service_reference-parse-prompt` | read_only | name/doc |
| `smart-search-service_rewrite-free-text-query` | read_only | name/doc |
| `smart-search-service_split-reference-blocks` | read_only | name/doc |
| `smart-search-service_validate-parsed-reference` | read_only | name/doc |
| `source-service_get-citation` | read_only | name/doc |
| `source-service_get-content-chunk` | read_only | name/doc |
| `source-service_get-figure-image` | external | crates/impress-store-service/src/source_service.rs:1428 render_page -> crates/impress-store-service/src/source_assets.rs:242 spawns `osascript -l JavaScript` (PDFKit) as a subprocess and writes PNGs into the render ca… |
| `source-service_get-page-image` | external | crates/impress-store-service/src/source_service.rs:70 render_page -> crates/impress-store-service/src/source_assets.rs:242 Command::new("osascript") PDFKit render subprocess on cache miss, PNG written to render-cache… |
| `source-service_put-citation` | mutating | name/doc |
| `source-service_put-content-chunk` | mutating | name/doc |
| `source-service_put-extraction-run` | mutating | name/doc |
| `source-service_put-figure-region` | mutating | name/doc |
| `source-service_search-content-chunks` | read_only | name/doc |
| `store-query-service_get-item` | read_only | name/doc |
| `store-query-service_list-items` | read_only | name/doc |
| `store-query-service_related-items` | read_only | name/doc |
| `store-query-service_search-all` | read_only | name/doc |
| `surface-demo-service_histogram` | read_only | name/doc |
| `surface-demo-service_series` | read_only | name/doc |
| `surface-selftest-service_run-selftest` | external | E/M: crates/impress-surface-service/src/selftest.rs:48-56 tier a -> tier_a.rs:48 World::open() uses SqliteItemStore::open_in_memory() (private store, nothing durable); tier b/all -> tier_b.rs:108-118 reqwest client to IMPR… |
| `triage-service_add-tag` | mutating | name/doc |
| `triage-service_remove-tag` | mutating | name/doc |
| `triage-service_set-flag` | mutating | name/doc |
| `triage-service_set-starred` | mutating | name/doc |
| `triage-service_set-status` | mutating | name/doc |
| `vw-diagnostic-service_close-session` | mutating | name/doc |
| `vw-diagnostic-service_create-session` | mutating | name/doc |
| `vw-diagnostic-service_evaluate-session` | read_only | name/doc |
| `vw-diagnostic-service_get-capabilities` | read_only | name/doc |
| `vw-diagnostic-service_get-photo` | read_only | name/doc |
| `vw-diagnostic-service_get-session` | read_only | name/doc |
| `vw-diagnostic-service_ingest-photo` | external | E/M: crates/vw-impress-adapter/src/photo.rs:52-83 ingest(): takes a ChatGptFile {download_url,file_id} not bytes, validates https non-private URL (photo.rs:404) and downloads it with reqwest (photo.rs:263, 45 s timeout), t… |
| `vw-diagnostic-service_list-applicable-procedures` | read_only | name/doc |
| `vw-diagnostic-service_list-sessions` | read_only | name/doc |
| `vw-diagnostic-service_recommend-next-test` | read_only | name/doc |
| `vw-diagnostic-service_record-measurement` | mutating | name/doc |
| `vw-diagnostic-service_record-observation` | mutating | name/doc |
| `vw-diagnostic-service_record-procedure-step` | mutating | name/doc |
| `vw-diagnostic-service_search-photos` | read_only | name/doc |
| `vw-diagnostic-service_start-procedure` | mutating | name/doc |
<!-- verb-safety:end -->
