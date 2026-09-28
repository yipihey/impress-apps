# Scenario steps

Scenarios retain `wire_version: 1` and the `impress/scenario@1.0.0` record kind.
The interpreter uses the same `Caller` for Tier A scratch stores and Tier B
isolated native hosts. Existing call, event, gesture and wait steps are unchanged.

## Selecting a stored record

A `store` step finds the first matching item in most-recently-modified order.
It uses the existing `list-items` and `get-item` verbs, through the caller and
its normal authorization. It does not access a second database directly.

```json
{
  "store": {
    "schema_ref": "manuscript",
    "where": [{"path": "$.payload.title", "equals": "Example draft"}],
    "max_rows": 100
  },
  "capture": {"document_id": "$.item.id"}
}
```

The candidate has an `item` envelope and a decoded `payload` object. All
predicates must match. Predicates use the existing closed field checks:
`equals`, `contains`, `gte`, `lte`, `within`, `len`, `present` and `absent`.
No expression language or executable code is accepted. An empty predicate list
selects the first row of the requested kind.

`max_rows` defaults to 100 and must be between 1 and 10,000. Paging is bounded;
this is a live scan, not a snapshot across concurrent edits. No match, an
exhausted bound, a truncated payload, a failed read or a missing capture path
fails the scenario with a named reason. It never treats incomplete data as a
successful match. Later steps use `{{state.document_id}}`.

## Optional operations

Use `best_effort` for an operation whose operational failure is acceptable:

```json
{
  "best_effort": {
    "call": "layout-service_delete-layout",
    "args": {"name": "temporary scenario layout"},
    "as": "person"
  }
}
```

Only `call`, `args` and `as` are accepted inside `best_effort`. There is no
assertion or capture. Transport failures and refusal envelopes are included in
the final report's detail, and later steps still run their assertions. Invalid
scenario structure or an unresolved argument template still fails before the
optional operation runs. The `as` label follows the same identity rules as a
normal call; it does not override a native HTTP request's authenticated caller.

## Nested surface templates

Write `{{!state.label}}` in a scenario argument to pass the literal
`{{state.label}}` to a surface. The same escape works inside a serialized JSON
string. `{{!uuid}}` passes a literal `{{uuid}}`; an unescaped `{{uuid}}` still
creates a fresh UUID. Unescaped `{{state.name}}` still resolves a scenario
capture, including a typed value when it occupies the whole string.

Session recording escapes literal templates before replay and preserves its
own generated ID captures. A literal argument that cannot round-trip is named
in the recording's omitted-call report, rather than changed silently.

The checked-in `crates/impress-scenario-service/scenarios/interpreter.gaps.json`
combines these features against a seeded scratch store. Its catalogue test runs
headlessly; native Tier B execution must use an owned host, port and store.
