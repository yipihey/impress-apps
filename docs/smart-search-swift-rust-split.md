# Smart search: where the Swift/Rust line is drawn

*Stage 7 item 8 of the declarative-chassis campaign, 2026-07-30.*

`packages/ImpressSmartSearch` (2,408 lines) was the largest Rust-first
violation in the tree: the logic behind imbib's Cmd+S overlay — the thing that
turns whatever a researcher pastes into a search plan — lived entirely in Swift,
reachable from one call site and from nothing else. It is now
`crates/impress-smart-search`, with a `#[impress_service]` trait that makes it
ten MCP tools, ten `impress` CLI subcommands and ten impel agent tools.

Three of the five components did **not** move wholesale, and this note records
where each line falls and why. A component whose behavior genuinely rides on a
platform framework is worse off forced into Rust; a component whose *quality*
rides on regexes and filters is worse off left in Swift. The split follows that
distinction, not component boundaries.

## The split

| Component | Rust | Stays Swift |
|---|---|---|
| `IntentClassifier` (441 L) | **all of it** | — |
| `ADSQueryNormalizer` (492 L) | **all of it** | — |
| `FreeTextQueryRewriter` (609 L) | prompt, `build_query` + its hallucination filters, `clean_query`, cloud-JSON decode, the whole no-model fallback | the `FoundationModels` session; the caller-supplied cloud runner call |
| `ReferenceParser` (270 L) | prompt, cloud-JSON decode, `validate` | the `FoundationModels` session; the cloud runner call |
| `URLContentExtractor` (281 L) | `<title>`, identifier patterns, arXiv archive whitelist, HTML entities, `%25XX` unwind | the `URLSession` fetch: status handling, byte cap, UTF-8/Latin-1 decode ladder |

### Why the model call stays Swift

`FoundationModels`' `@Generable` macro generates a constrained-decoding schema
from a Swift type at compile time, and `LanguageModelSession` runs Apple's
on-device model. There is no Rust equivalent and no FFI shape that would help:
the value of `@Generable` *is* that the model cannot emit a malformed struct.

What matters is that this leaves almost nothing behind. The Swift side now hands
the model's struct straight to Rust and gets a query back. Every judgement call
— that `JWST` is a telescope and not an author, that four "authors" with no
topic words means the model mis-classified, that `abs:(1970)` over-constrains to
zero hits, that a surname absent from the input was hallucinated — is Rust, and
tested.

The prompts moved too, which is less obvious but more useful: a prompt is the
contract with the model, so a silent edit to it is a silent behavior change.
They are byte-pinned by the golden corpus and readable via
`smart-search-service_free-text-extraction-prompt`.

### Why the fetch stays Swift

`URLSession` carries system proxy configuration, App Transport Security, the
sandbox's `com.apple.security.network.client` entitlement, the shared
cookie/cache stores and the redirect policy. Re-implementing that on `reqwest`
would mean re-implementing platform *policy* — and would need an async FFI
boundary to do it. The fetch is ~40 lines of Swift that will not drift.

The extraction is the half that decides what the user gets, and it is 100% in
Rust. Concretely: the arXiv legacy-archive whitelist that keeps `gnd/4226307`
(a German National Library id) from being imported as a paper, and the DOI
pattern that stops at `&` so `&amp;` and `&format=xml` trailers don't end up
inside a DOI.

## Behavioral divergences the golden corpus surfaced

The corpus (2,628 cases, `crates/impress-smart-search/test_fixtures/golden/`)
was captured from Swift *before* the bodies were replaced. Every one of the
following was found by a red test, not by reading code — which is the argument
for capturing first.

### 1. `URL.path` is percent-decoded; `url::Url::path()` is not

Foundation's `URL.path` returns the **decoded** path while `absoluteString`
stays encoded:

```
input       https://en.wikipedia.org/wiki/Original_proof_of_G%C3%B6del%2527s_theorem
absoluteString  …G%C3%B6del%2527s_theorem     (unchanged)
path            /wiki/Original_proof_of_Gödel%27s_theorem   (one decoding round)
```

Every path-matching rule in the classifier — the DOI scan, the ADS `search/`
tail split, the arXiv and bibcode segment checks — therefore runs on decoded
text. `path` also drops one trailing slash (`/search/` → `/search`) and is `""`
rather than `"/"` when the input carried no path at all. `crates/impress-smart-search/src/swift_url.rs`
reproduces all three. **Resolution: emulated exactly, no divergence.**

### 2. WHATWG strips tabs and newlines from URLs; Foundation rejects them

`Url::parse("https://a.com\nhttps://b.com")` silently yields one URL with host
`a.comhttps`. Foundation returns nil. **Resolution: reject control characters
before parsing.**

### 3. U+200B is whitespace to Foundation and not to Rust

`CharacterSet.whitespaces` still contains U+200B ZERO WIDTH SPACE, which was
reclassified `Zs`→`Cf` in Unicode 4.0 and so is not `White_Space`;
`char::is_whitespace` excludes it. Worse, the Swift code uses **three**
different whitespace notions that disagree:

| | contains U+200B | contains `\n`, U+2028/9, U+0085 |
|---|---|---|
| `trimmingCharacters(in: .whitespacesAndNewlines)` | yes | yes |
| `trimmingCharacters(in: .whitespaces)` | yes | no |
| `Character.isWhitespace` | **no** | yes |
| Rust `str::trim()` | **no** | yes |

This is not academic: pasting from a web page or a PDF routinely carries
zero-width spaces, and `classify("\u{200B}")` must reach the same "empty input"
branch it reached in Swift. `crates/impress-smart-search/src/foundation.rs`
provides all three predicates and each call site uses the one Swift used.
Verified empirically across U+0009…U+FEFF; U+200B is the only disagreement.
**Resolution: emulated exactly, no divergence.**

### 4. `String.capitalized` treats apostrophes as intra-word, hyphens as breaks

`"van-der-waals"` → `"Van-Der-Waals"` but `"o'brien"` → `"O'brien"`. Reached via
the `by <Author>` rule in the fallback rewriter. **Resolution: emulated
exactly** (the corpus case that proved it was added specifically to settle the
question).

### 5. NSRegularExpression's `$` does not match before a trailing newline here

The `regex` crate's `\z` and ICU's `$` are documented to differ (ICU `$` also
matches before a final line terminator), so `validate` was first written with
`\n?\z`. The corpus disproved it: Swift rejects `"10.1234/x\n"` as a DOI.
**Resolution: `\z`, matching observed Swift behavior rather than the
documentation.** Load-bearing, since a model emitting a trailing newline in a
DOI is exactly what `validate` guards against.

### 6. `JSONDecoder` accepts integral floats for `Int`; `serde_json` does not

`{"year": 2002.0}` decodes to `2002` in Swift and errors in serde; `2002.7`
errors in both. Models do emit `2002.0`. **Resolution: a custom deserializer
(`de_lenient_i64`) that reproduces both halves.**

### 7. The `regex` crate has no lookaround — and the obvious workaround is wrong

This is the trap the task flagged, and it had **already been sprung**. An
unwired Rust port of `ADSQueryNormalizer` existed in
`imbib-core/src/search/ads_normalizer.rs`, and its boolean-operator rule folded
Swift's `(?<!["\w])\b(and|or|not)\b(?!["\w])` into *consuming* character
classes: `(?:^|[^"\w])(and|or|not)(?:$|[^"\w])`. That eats the delimiter, so in
`"and or not"` the space after `and` is consumed and `or` can no longer find a
preceding non-word character. It normalized to `"AND or NOT"` — silently
skipping every second operator. Nothing noticed, because the only caller was a
property test that checked totality rather than results.

**Resolution: match with zero-width `\b` only and check the neighbouring
characters by hand.** The same file's Rule 0 already did it that way; Rule 4 had
drifted.

While there: Swift iterates `matches.reversed()` in five of the six rules, so
its `corrections` list comes out last-match-first. The Rust twin reported them
forward. Fixed to match.

### 8. `JSONSerialization` silently strips U+FEFF when reading

The one place a divergence could not be closed — and it is in a *test reader*,
not in the port. Foundation's JSON reader writes a mid-string BOM faithfully
(`EF BB BF`) but strips the scalar on read, **even from the escaped `﻿`
form** (verified both directions with a standalone probe). So the corpus case
`"\u{FEFF}10.1086/164143"` — which Swift classifies as `.freeText`, because the
BOM defeats the whole-string DOI match — arrives in the Swift parity suite as a
bare DOI.

**Resolution: the case stays in the corpus** (BOM-prefixed paste is real) and
`golden_parity.rs` asserts it, because `serde_json` preserves the scalar. The
Swift suite exempts it by the exact `(input, expectedKind)` pair, with the hit
count pinned at 1 so the exemption cannot widen; the corpus also holds a plain
`10.1086/164143` expecting `.identifier`, so a genuine regression on that input
still fails.

## Preserved quirks

Two behaviors are wrong-ish and were kept, because changing search behavior is
not a porting decision:

- **`"Title: A Study of Things"` classifies as `.fielded`.** `\btitle:` is
  case-insensitive and unanchored, so prose with a colon after a field-like word
  goes to ADS verbatim. Narrowing this belongs in its own change.
- **`abs:"dark and matter"` becomes `abs:"dark AND matter"`.** The Swift comment
  claims the rule skips operators inside quotes; the regex only excludes a quote
  *immediately* adjacent, and the characters next to `and` here are spaces.

One nondeterminism was fixed rather than preserved: Swift decoded HTML entities
by iterating a `Dictionary`, so its replacement order was unspecified — which
matters for input where decoding one entity *creates* another (`&amp;lt;`). Rust
uses a fixed order. No corpus case observes the difference, so this is a strict
improvement rather than a divergence.

## What the deduplication was worth

Before: **three** implementations of the ADS normalizer — this package's, a
byte-identical copy in `PublicationManagerCore` (which is the one PMC's
`SmartQueryTranslator` actually resolved to, same-module winning over the
import), and the drifted Rust twin. After: one, in Rust, with 125 golden cases
and the 45 pre-existing PMC assertions retargeted at it through the real FFI.

`PublicationManagerCore/Sources/.../Search/SmartQueryTranslator.swift` was dead
code — no non-test consumer, superseded by the rewriter's fallback path. It was
left in place as out of scope here and **deleted in Stage 7 item 9** (444 L, plus
293 L of tests), after the no-consumer claim was verified independently. See
[docs/parser-batch-swift-rust-split.md](parser-batch-swift-rust-split.md).

## FFI path

`imbib-core` hosts the UniFFI surface (`src/smart_search_ffi.rs`, 13 exports)
and PMC reaches it through `ImbibCore.xcframework`, which every app embedding
PMC already links. **No new xcframework**, no new checksum surface, no app build
settings touched. `packages/ImpressSmartSearch` depends on
`apps/imbib/ImbibRustCore` to see it — a `packages/` → `apps/*/…RustCore` edge
with existing precedent in `packages/ImpressPublicationUI`.

The alternative, adding the exports to `impress-store-ffi` (whose wrapper
`packages/ImpressRustCore` is a sibling), was rejected: that crate is the shared
*item store*, all five apps depend on it for generic item ops, and putting
search logic there makes its name a lie.
