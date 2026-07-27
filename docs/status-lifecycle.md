# Status Lifecycle — Cross-Schema Convention

`status` is a free-form payload string on store items (no Rust validation —
impart/journal schemas must not break). Two values are RESERVED with
chassis-wide semantics; everything else is schema-owned.

| Value | Semantics | UI grammar |
|---|---|---|
| `dismissed` | Swept out of the working set. Hidden from EVERY scope except the Dismissed section. Never destructive. | `d` key / trailing swipe = dismiss; in Dismissed: restore-first (→ the kind's restore status, e.g. `draft`), delete-second. |
| `archived` | Deliberate end-state for finished work. Listed under Archive; restorable. | Archive appears in swipe/context menus for kinds whose descriptor sets `archiveStatus`. |

Schema-owned examples: manuscript `draft | internal-review | submitted |
in-revision | published` (`JournalManuscriptStatus`), impel task states
(kernel-transitioned only — `TaskStoreApi.transition` is the sole legal
mutation path).

Exceptions:
- **Publications do NOT use status-dismissal.** imbib's dismissal is a
  library move (Dismissed library) guarded by the "dismissed papers must
  never re-enter the inbox" invariant (Rust `filter_dismissed`). Descriptor:
  `DismissalSemantics.libraryMove`. Harmonizing this onto the status string
  is a Stage-2 candidate and must preserve that invariant.

Enforcement: Tier-A selftest capability `store.status_lifecycle` (dismiss →
absent from other scopes; restore → returns; archived → only in archive
scope) + `RecordKindParityTests` (a descriptor's declared `statuses` track
the kind's Swift enum / schema usage).
