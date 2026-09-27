# P5b HTTP endpoints retained for distinct behavior

P5b moves service verbs to each app's native UniFFI inventory. A sibling's
`POST /api/verb/<descriptor-name>` returns the verb's raw JSON result, with
snake_case fields; a refusal is a non-2xx `{ok:false,code,message}` response.
The older routes often return `{status:"ok", ...}` envelopes and sometimes
provide data that no current verb returns. Removing those routes would change
cross-app behavior, so they remain until a separately approved capability can
replace them. `GET /api/status`, `GET /api/logs`, and app-only routes also remain.

| App | Retained route and caller | Difference from existing verbs |
| --- | --- | --- |
| imbib | `GET /api/search`, `GET /api/papers/{citeKey}` in `ImbibBridge` | `search-publications` returns `PublicationSummary`; it lacks the HTTP paper's abstract, bibcode, PMID, and BibTeX. A cite-key detail needs more than one verb and field conversion. |
| imbib | `GET /api/search/external` in `ImbibBridge` | `search-sources` returns `ExternalPaper`, but the HTTP candidate also has an importable `identifier`; some results have no DOI, arXiv ID, or bibcode from which to recover it. |
| imbib | `POST /api/papers/add`, `POST /api/papers/resolve` in `ImbibBridge` | `import-papers` accepts BibTeX-backed `PaperImport`, not arbitrary identifiers plus target collection/PDF preference or per-paper failures. `resolve-identifier` accepts a string, not the bridge's structured citation and ranked candidates. |
| imbib | `GET /api/libraries`, `GET /api/collections` in `ImbibBridge` | `list-libraries` omits collection count and sharing; `list-collections` requires a library ID while the HTTP route lists across libraries with names. |
| imbib | `GET /api/export?keys=...&format=ris` | The canonical `export-bibtex` verb cannot produce RIS. The old route now accepts only explicit `format=ris`; BibTeX uses the verb. |
| imprint | `GET /api/documents` and `POST /api/documents/{id}/insert-citation` in `ImprintBridge` | `list-documents` omits word count and last modification; no verb inserts a citation into the live editor at the caret or returns the route's conflict when that editor is absent. |
| implore | `GET /api/figures`, `GET /api/figures/{id}`, `GET /api/figures/{id}/export` in `ImploreBridge` and impel's `CounselToolRegistry` | `FigureRecord` lacks the route's type, dataset name, modified time and view-state fields. `export-figure` returns a file path, while `ImploreBridge.exportFigure` returns image bytes. Counsel's raw result expects the old full envelope. |
| impart | `GET /api/research/conversations` in `ImpartBridge` and impel's `CounselToolRegistry` | `ConversationRecord` omits participants, tags, parent conversation, and `lastActivityAt` from the HTTP list; Counsel also consumes the old count/total/query envelope. `GET /api/messages` is a separate app-only mail capability. |
| imprint | `GET /api/documents/{id}` in impart's `ArtifactResolver` | `get-document` returns id/title/format, but the resolver's `DocumentArtifactData` requires lastModified and can carry version/preview text. Retaining the route is necessary until that read is represented. |

The exact equivalent bridge operations now use verbs: imbib BibTeX export and
library creation, and imprint document content composed from `get-document`
plus `get-content`. The imbib BibTeX export and library creation route arms were
removed after hosted parity; the three old undo and seven local SciX routing
arms also moved to verbs. No Swift caller uses those SciX URLs; the seven
existing SciX descriptors cover local record CRUD, membership, and counts.
The shared `SiblingBridge` reads the per-launch token for POST and decodes the
raw result. Keep private Swift handlers invoked by native callbacks even when
the corresponding HTTP `if` arm is removed.

Other candidate library and tag routes remain pending a route-by-route contract
proof. The library and collection list routes expose sharing and cross-library
fields that current verb results omit, while the tag-tree route returns a
formatted hierarchy rather than flat tag records. Manuscript, e-ink,
revisions, and shared status/log routes remain independent capabilities.
