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
| imprint | `POST /api/documents/{id}/insert-citation` in `ImprintBridge` | No verb inserts a citation into the live editor at the caret or returns the route's conflict when that editor is absent. |
| imprint | `POST /api/documents/{id}/update`, `/replace`, `/insert`, `/delete`, and `PUT /api/documents/{id}/metadata` | These legacy handlers acknowledge queued editor operations and return an `operationId`. `/update` also accepts full source, and `/replace` supports replacing only the first match. Native verbs commit and read back immediately, so the route responses and some arguments are not equivalent. Keep them pending the caller and contract decision. |
| implore | `GET /api/rg/slice/png`, `/api/rg/cascade_plot`, `/api/plot/svg`, and `/api/plot/histogram` | These routes accept viewer query/body options or return raw image/SVG data. A string result does not preserve binary HTTP response behavior. |
| impart | `POST /api/research/conversations`, `/{id}/messages`, `/{id}/branch`, `/{id}/artifacts`, `/{id}/decisions`; `PATCH /api/research/conversations/{id}`, `/{id}/archive` | These legacy routes queue UI operations and return queue acknowledgements. The native verbs perform writes before returning. The HTTP routes also accept fields absent from the verb signatures: participants, sender ID/causation ID, branch message ID, artifact URI/type/display name, tags, and archive. No verb represents archive. |

The exact equivalent bridge operations now use verbs: imbib BibTeX export and
library creation, imprint document content composed from `get-document` plus
`get-content`, implore figure list/detail/export/create/update/delete, and
impart conversation list/detail. The implore figure domain route registrations
and impart conversation read registrations were removed after their bridge and
Counsel consumers moved to generated verbs. The raw implore RG/plot viewer
routes and all impart queued conversation writes remain. The imbib BibTeX
export and library creation route arms were removed after hosted parity; the
three old undo and seven local SciX routing arms also moved to verbs. No Swift
caller uses those SciX URLs; the seven existing SciX descriptors cover local
record CRUD, membership, and counts.
Imprint's `POST /api/documents/create` arm was also removed: it returned a
new UUID without persisting a manuscript, while the native `create-document`
verb commits one to the shared store. No production Swift caller used that URL.
Imprint also retired `GET /api/documents`, `GET /api/documents/{id}`, and the
comment list/create/update/delete/accept/reject registrations after moving
their production reads and writes to generated verbs. The hosted fixture keeps
the seeded behavior on those verbs and asserts the retired HTTP paths return
404. Their private handlers remain for the native verb callbacks. The manual
`apps/imprint/test-imprint-api.sh` harness now uses generated document
create/list/detail contracts and retains checks for distinct platform routes.
It requires explicit isolated-host opt-in and the loopback bearer; the target
must use a PID-owned scratch workspace. It has no comment-route requests;
comment lifecycle and retired-path checks remain in the hosted proof.
The shared `SiblingBridge` reads the per-launch token for POST and decodes the
raw result. Keep private Swift handlers invoked by native callbacks even when
the corresponding HTTP `if` arm is removed.

Imbib's migrated publication, citation, library/collection, flat-tag, RIS,
library add-papers, and formatted tag-tree routes are retired after their
generated contracts were established. `imbib-tags-service_tag-tree` is the
formatted hierarchy. Other unlisted library and tag routes (including sharing,
activity, assignments, and tag mutation) retain their independent behavior.
The inventory above lists only routes still retained for distinct contracts;
historical route-to-verb evidence remains in the dated pipeline log. Manuscript,
e-ink, revisions, and shared status/log routes remain independent capabilities.

Implore retired ten legacy registrations whose existing native callback calls
the same private handlers with the same arguments: `GET /api/datasets`,
`GET /api/datasets/{id}`, `GET /api/rg/state`, `GET /api/rg/colormaps`,
`POST /api/rg/load`, `POST /api/rg/slice/save`, `GET /api/rg/slice/raw`,
`GET /api/rg/statistics`, `POST /api/rg/control`, and `POST /api/rg/batch`. The dataset handlers still
report session data as before (currently an empty list or not found); the
registration removal does not change their native behavior. No repository
Swift caller uses these ten URLs. Impart retired no research registrations:
its remaining HTTP contracts differ from the current verbs as listed above.

Before the contract parity work, Imbib retired ten unused library/collection/tag registrations: GET library
`default` and `inbox`, POST library `set-default` and `deduplicate`, collection
`purge-dismissed`, and tag creation, PUT tag rename/color, and DELETE tag or
collection. Collection creation still accepts an absent library and a predicate;
membership routes accept arbitrary paper identifiers and return per-item
outcomes. Library deletion accepts file-deletion and batch options. Tag list
prefix/limit and formatted tree results are not the flat verb records.

Imprint retired `GET /api/manuscripts/{id}/sections`, whose stored-section list
is covered by the canonical verb. Other section routes operate on live derived
editor sections or accept item IDs without the verb's document/key pair. The
live outline/citation/search routes also carry document and position/search
semantics beyond the pure-source verbs. Compile routes returning PDF bytes,
and bundle or live-document compilation, remain distinct from a returned path.
