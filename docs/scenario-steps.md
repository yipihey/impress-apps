# Scenario steps

Scenarios retain `wire_version: 1` and the `impress/scenario@1.0.0` record kind.
The interpreter uses the same `Caller` for Tier A scratch stores and Tier B
isolated native hosts. Call, event, gesture and wait steps keep their wire shapes.

## Gesture results and fresh log waits

A gesture can capture fields from its result with a JSON-path map, just like a
call step. Refused gestures fail before captures are stored:

```json
{
  "gesture": {"verb": "split", "target": {"role": "detail"}},
  "capture": {"new_tile": "$.focused"}
}
```

Call capture paths may include earlier captured values when a JSON object key
is dynamic. For example, after capturing a tile ID from `$.focused`, a later
`get-layout` call can capture `$.layout.tiles.{{state.tile}}.pane.session`.
The resolved path is still the same literal dotted JSON path walk; it has no
selectors or expressions. Capture references must come from an earlier step,
and captured values are not interpreted recursively after insertion.

A call may also capture one value from its arguments **after** scenario
templates and `{{uuid}}` have been resolved. This lets a later assertion compare
the observed state with the exact value sent, without re-generating it:

```json
{
  "call": "layout-service_select",
  "args": {"ids": ["{{uuid}}"]},
  "capture": {"selected_id": {"argument": "$.ids.0"}}
}
```

Argument capture paths are fixed JSON paths into the resolved arguments. A
missing path fails before dispatch; captured JSON retains its type and is not
templated again.

Call captures also have two closed JSON operations for values that cannot be
addressed by a fixed path. `select_one` scans an object or array at `from`
(at most 10,000 candidates), checks a fixed relative `path` using `equals` or
`array_contains`, and refuses zero or multiple matches. It captures
`{key, value}`; object keys stay strings, array keys are indices. An explicit
`object_key_as: "u64"` additionally parses a decimal object key into
`numeric_key`, failing unless the key is a canonical unsigned decimal (for
example, `9`; `09`, `+9`, and overflow are refused). A missing predicate
path on a candidate is a non-match. The `from` path and predicate values may
use earlier captures; the relative candidate path stays fixed.

```json
{
  "capture": {
    "parent": {"select_one": {
      "from": "$.layout.tiles",
      "path": "$.container.linear.children",
      "predicate": {"array_contains": "{{state.tile}}"},
      "object_key_as": "u64"
    }}
  }
}
```

`fill_array` repeats one literal JSON `value` for the length of an earlier
captured array. It accepts only a whole capture reference in `length_of`,
requires the referenced value to be an array, and caps the result at 10,000
items and 1 MiB of compact JSON output. `value` remains literal, including
strings that look like capture templates. Neither operation evaluates
expressions, traverses arbitrary code, nor re-templates captured JSON. The
`layout.version_moves` scenario uses these operations to find the split's
linear parent and construct its equal shares.

The layout catalogue's closed collection-row gesture is
`{"outline_collection":"{{uuid}}"}`. Its caller derives the app-specific
query and exact verbs from the live tree using the same outline decision
functions as a native row click. The result exposes the query, list tile, and
optional detail metadata for later assertions; the scenario does not copy a
query or verb sequence by hand.

`wait.log_cursor` captures the current server timestamp for a later log wait.
Capture it immediately before the mutation whose log line you need to observe:

```json
{"wait": {"log_cursor": {"capture": "before"}}}
```

`wait.log` requires `category`, `contains` and a `timeout_ms` from 1 through
60,000. Optional `also_contains` needles must also occur in that same message;
all message matches are case-insensitive. Optional `after` accepts a captured
ISO-8601 cursor, so entries at or before it cannot satisfy the wait:

```json
{
  "wait": {
    "log": {
      "category": "layout",
      "contains": "pane {{state.new_tile}} console:",
      "also_contains": ["search 'layout'", "levels info,warning,error"],
      "after": "{{state.before}}",
      "timeout_ms": 3000
    }
  }
}
```

An optional `when_present` on a wait step guards that wait with a prior
capture-state JSON path. Missing and `null` values skip the wait before its
body is resolved; a malformed path or a path rooted at a capture that has not
yet been set fails validation. This is a closed presence guard, not a general
conditional or branch:

```json
{
  "wait": {"log": {"category":"layout", "contains":"pane {{state.detail.tile}}"}},
  "when_present": "$.detail"
}
```

## Comparing captured results and checking cleanup

An expectation can compare a later response with captured JSON. For example,
capture `{"before": "$.surfaces"}` from `surface-list`, attempt an invalid
create, then check `{"path": "surfaces", "equals": "{{state.before}}"}`.
The whole-string reference preserves the array/object type. Captured content is
not interpreted again, so surface templates inside that content remain literal.
References must name an earlier capture; use the literal escape below when the
expectation itself contains a surface template.

`within` accepts a fixed JSON number or a whole capture reference resolving to
a JSON number. The tolerance remains an ordinary numeric value; nonnumeric
captured targets fail the expectation.

Every teardown step is attempted even after an earlier failure. A failed
teardown call or assertion fails the scenario; use `best_effort` explicitly
when that operation may fail. A teardown refusal needs an `expect` assertion
just as an ordinary call does.

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
`equals`, `not_equals`, `contains`, `gt`, `gte`, `lte`, `within`, `len`,
`present` and `absent`. `gt` requires JSON numbers and compares integer values
without floating-point rounding; `not_equals` requires the path to exist and
compares JSON values. Literal JSON values and whole `{{state.capture}}`
references are accepted. No expression language or executable code is
accepted. An empty predicate list selects the first row of the requested kind.

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
