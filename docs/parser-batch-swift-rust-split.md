# The parser batch: where the Swift/Rust line is drawn

*Stage 7 item 9 of the declarative-chassis campaign, 2026-07-30.*

Five Swift parsers, 2,835 lines, all of them non-UI logic reachable from one or
two call sites and from nothing else. This note records what moved, what stayed,
and — the part that matters — the behavioural differences the golden corpus
surfaced. Every one of them was found by a red test, not by reading code.

The corpus is **437 cases** in `crates/imbib-core/test_fixtures/golden/`
(431 new across 17 files, plus the 6 pre-existing wave-1/2 files), captured from
Swift *before* any body was replaced. It is asserted from Rust
(`tests/stage7_parser_parity.rs`, `stage7_pdf_parity.rs`,
`stage7_abstract_parity.rs`) and from Swift through the real FFI. **There is no
regeneration path**, deliberately.

## The split

| Component | LOC before | Rust | Stays Swift |
|---|---|---|---|
| `MboxParser` + `MIMEDecoder` | 731 | all the parsing: `From ` splitting, header unfolding, RFC 2047 encoded-words, quoted-printable, base64, `multipart/*`, mboxrd unescaping, RFC 2822 dates | `String(contentsOf:)`, the `actor` wrapper, the `MboxMessage`/`MboxAttachment` value types |
| `PublisherHTMLParsers` + `PublisherRule` + `DefaultRules` | 939 | all 16 extraction strategies, the host dispatch, the 16-rule table, `matches(doi:)`, `constructPDFURL(doi:)` | the `URLSession` fetch; `PublisherRegistry`'s `actor` lifetime |
| `AbstractParser` + `MathMLToLaTeX` | 687 | all of it | — (see "the unwired half") |
| `PDFMetadataExtractor` | 483 | `isPlausibleTitle`, `bestTitle`/`bestAuthors`/`bestYear`/`hasIdentifier`, the confidence ladders | `PDFDocument`, `documentAttributes`, the PDFKit text fallback |
| `ArtifactMetadataExtractor` | 243 | the `<meta>` scrapers, the filename-hint + extension half of `inferArtifactType` | `UTType.conforms(to:)`, `CGPDFDocument` info-dict access, Vision OCR |
| `SmartQueryTranslator` | 444 | — | **deleted** (dead code, see below) |

Swift LOC, before → after: `MboxParser` 356→112, `MIMEDecoder` 375→125,
`AbstractParser` 687→113, `PublisherHTMLParsers` 551→83, `DefaultRules` 257→68,
`PDFMetadataExtractor` 483→414, `ArtifactMetadataExtractor` 243→217,
`PublisherRule` 131→135, `PublisherRegistry` 179→192 (the last two grew: they
gained the FFI bridge and the deterministic longest-prefix lookup). Plus 737
lines deleted outright. **2,835 → 1,459 Swift**, against 4,201 lines of new Rust
(2,240 logic + 393 FFI + 424 service + 1,144 module tests) and 1,537 lines of
Rust golden-parity tests.

### Why the fetch stays Swift

Same reason as the SmartSearch port: `URLSession` carries system proxy
configuration, App Transport Security, the sandbox's
`com.apple.security.network.client` entitlement, the shared cookie/cache stores
and the redirect policy. Re-implementing it on `reqwest` would mean
re-implementing platform *policy*. The extraction is the half that decides what
the user gets, and it is 100% Rust.

### Why the PDF object access stays Swift

`PDFDocument.documentAttributes` and `CGPDFDictionaryGetString` read the PDF's
info dictionary. `pdfium-render` **can** do this (`FPDF_GetMetaText`) and nobody
has written the binding; until someone does, the info dict is a platform read.
Note the asymmetry that already existed and is unchanged: PDF *text* extraction
is already Rust (`pdf/extract.rs`, pdfium), with PDFKit only as the fallback for
when `libpdfium` cannot bind.

### Why the publisher parsers did NOT become a DOM parse

The task flagged HTML-dialect risk. It does not apply: the Swift original
imports only `Foundation` and `OSLog` — no `XMLDocument`, no `XMLParser`, no
`NSAttributedString(html:)`, no WebKit. It is twenty `NSRegularExpression`
patterns over HTML text, so **there is no parser to disagree with**. All twenty
use only `[^"']+`, `[^>]+`, `(?:…)`, `.*?` and `\s*` — no lookaround, no
backreferences — so `regex` takes them verbatim with `(?is)` for
`[.caseInsensitive, .dotMatchesLineSeparators]`.

`scraper`/`html5ever` was considered and rejected. It would add a large new
dependency subtree (html5ever + tendril + selectors + cssparser, none currently
in the workspace) in order to *change* the behaviour the 54 golden cases pin. A
DOM parse would find PDFs the regexes miss — that is an improvement, and
therefore its own change with its own corpus, not a port.

### Why this is not `impart-core::mbox`

`crates/impart-core/src/{mbox,mime}.rs` exists and is real. It is **not** a twin:
it is a conversation-log writer for impart's AI counsel threads, built on
`mailparse`, spec-correct by delegation, and wired to nothing (zero callers
outside its own tests). imbib's parser reads **imbib's own export format** plus
whatever third-party mbox a researcher drags in, and it has to reproduce years of
`MIMEDecoder` decisions about malformed input — including the wrong ones.
Pointing imbib's importer at `mailparse` would change what every archive already
on disk imports as, silently, with no test able to tell you. The two stay
separate. (`impart-core`'s own gaps — it escapes `From ` on write but never
unescapes on read, and drops every `X-*` header on read — are noted here because
they were found during this survey, not fixed: impart is not this wave's
boundary.)

For the record, `ImpartRustCore` remains a **placeholder** — 146 lines of
hand-written stub structs and a `threadMessages` that returns one thread per
message. impart's CLAUDE.md claim that MIME and threading "live in Rust" still
describes intent, not shipped code. Wave 5 found this; it is still true.

## Behavioural divergences the golden corpus surfaced

### 1. Quoted-printable decoded every octet as Latin-1 — corrupting imbib's own round trip

The headline finding. `MIMEDecoder.quotedPrintableDecode` builds
`Character(UnicodeScalar(byte))` per `=XX` escape — **one Latin-1 scalar per
byte** — so a UTF-8 sequence becomes mojibake:

```
=E2=80=94      → "â\u{80}\u{94}"   (should be "—")
M=C3=BCller    → "MÃ¼ller"          (should be "Müller")
```

`MIMEEncoder` writes every body as `Content-Transfer-Encoding:
quoted-printable` over UTF-8 bytes. So **an imbib mbox export followed by an
imbib mbox import corrupted every non-ASCII character in every abstract.** The
one quoted-printable test in the suite used `=3D`, which is ASCII, so nothing
caught it.

The same bug in RFC 2047 headers is subtler and reached real titles:
`=?UTF-8?Q?M=C3=BCller?=` → `MÃ¼ller`, and
`=?ISO-8859-2?Q?a=B1b?=` → `a±b` where 0xB1 is `ą` in Latin-2 — Polish and Czech
surnames silently transliterated into punctuation, with no character lost or
gained, which is why it never looked broken. `B`-encoded words honoured the
charset correctly, and imbib's exporter emits `B`, which is the other half of why
this survived.

**Resolution: fixed, structurally rather than by writing a second
implementation.** `quoted_printable_tokens` makes every decision once and yields
a token stream of `Literal(grapheme)` / `Byte(u8)`. Two *renderers* project it:
`render_swift_latin1` reproduces Swift exactly and is what the golden corpus
asserts — so the port is provably faithful — and `render_text` accumulates the
octets and decodes them with the declared charset, and is what ships. One
tokenizer, two projections, no duplicated logic.

### 2. Swift's `Character` is a grapheme cluster, so `=\r\n` is not a soft line break

`"\r\n"` is a **single** `Character` in Swift. So in
`quotedPrintableDecode`, `encoded[nextIndex] == "\r"` is *false* for a CRLF: the
CRLF branch is unreachable, the hex attempt consumes the cluster plus one more
unit and fails, and `=\r\n` survives verbatim. Quoted-printable's own soft line
break is not honoured in its canonical spelling.

A `chars()`-based port silently "fixes" this and diverges. **Resolution:
emulated exactly** — the tokenizer iterates grapheme clusters
(`unicode-segmentation`), and `"a=\r\nb"` is a corpus case. Invisible in
production only because both callers normalise CRLF to LF first; visible to
anyone calling the primitive.

### 3. `DateFormatter` ignores an inconsistent weekday; chrono rejects it

`Date: Thu, 01 Jan 2024 00:00:00 +0000` — 2024-01-01 was a **Monday**. Foundation
parses the `EEE` field and then does not check it. `chrono` returns
`ParseError(Impossible)`, so on the corpus's first run *every* date came back
`None`. Real mbox files are full of wrong weekdays.

**Resolution: strip the day-of-week token and never validate it**
(`strip_weekday`), which is what Foundation does. All three of Swift's
`DateFormatter` shapes then collapse to one format.

### 4. Header lookup was case-sensitive, so lowercase headers imported as blank

Swift subscripted the header dictionary with exact-case keys —
`headers["From"]`, `headers["Content-Type"]`. A third-party mbox written with
`subject:` imported with an empty title and `unknown@imbib.local` as the sender.
RFC 5322 §1.2.2 makes field names case-insensitive.

**Resolution: fixed.** Corpus case `lowercase-header-names`.

### 5. `URL.path` decodes and `URLComponents.path =` re-encodes

Seven of the sixteen publisher parsers read `baseURL.path`, edit it as text, and
assign it back. `URL.path` is percent-**decoded** and drops one trailing slash
(reused from `impress-smart-search/src/swift_url.rs`, written for the SmartSearch
port); assigning to `URLComponents.path` **re-encodes**. Pinned empirically
rather than from the docs, because the docs do not say which set:

| input path | after the round trip |
|---|---|
| `a%20b` | `a%20b` (space → `%20`) |
| `a%25b` | `a%25b` (literal `%` → `%25`) |
| `M%C3%BCller` | `M%C3%BCller` |
| `a+b:c` | `a+b:c` (both survive) |
| `/x/` | `/x` then `+/pdf` → `/x/pdf` |

Query and fragment are preserved. **Resolution: emulated exactly, no
divergence.**

### 6. A whitespace-only PDF author discarded recovered authors

`bestAuthors` gated on `!author.isEmpty` **untrimmed**. An `authorAttribute` of
`"   "` therefore counted as "the PDF told us the authors"; the comma split
produced one empty component, the filter dropped it, and `bestAuthors` returned
`[]` while `heuristicAuthors` held real names. Recovered data discarded in favour
of nothing. **Resolution: fixed** — the gate now asks for visible content.
`best_authors_swift` is retained as the parity witness.

**Not** fixed while there: `bestAuthors` splits on `,` only, so
`"Smith, John; Doe, Jane"` becomes three names. The comma-separated form is
mangled identically, so the real fix is the shared author parser in
`impress-bibtex`, which changes every PDF import and needs its own corpus.

### 7. `regex` has no lookaround — and the trap had a second edge

`normalizeArXivEscaping` rewrites 186 LaTeX command names with
`\\<cmd>(?![a-zA-Z])`. The SmartSearch port already documented what goes wrong if
you fold a lookahead into a consuming class (it eats the delimiter the next match
needs, and the ADS boolean rule silently skipped every second operator).

**Resolution: one pass of `\\([a-zA-Z]+)` plus a set-membership test on the
captured run.** The equivalence is exact: every command name is letters-only, so
for any *proper* prefix of the maximal letter run the next character is
necessarily another letter and Swift's lookahead rejects it — the only prefix
that can match is the whole run. `$\\alphabet$` matches with run `alphabet`,
which is not a command, so the match is rewritten to itself and the closing `$`
is never touched. The corpus case `command-prefix-trap` asserts the segment count
is still 2 *and* that a neighbouring real case still rewrites, so the test cannot
pass by refusing to rewrite anything.

### 8. Four HTML entity decoders, and reuse was attempted and rejected

`decodeHTMLEntities` has 41 named entities plus decimal and hex numeric forms.
Rust already had three partial decoders: `scientific_parser` (6 named, no
numeric, `#[uniffi::export]`ed with a live signature), `url_extract` (11 named +
numeric, Swift-parity documented) and `crossref::clean_html_tags` (5).

`url_extract::decode_html_entities` was tried and **cannot** be reused: it
applies its own named table in the same call, `&amp;` **first**, so `&amp;lt;`
decodes twice to `<`. The golden case `entity-cascading` pins one decode round —
the source escaped a literal `&lt;`, which is the whole point. Reaching the
numeric half alone means splitting a `decode_numeric_entities` out of a different
crate.

**Resolution: a local 41-entity table with `&amp;` LAST**, the only entity whose
expansion can create another. Swift iterated a `Dictionary`, so its order was
*unspecified* and the captured run merely happened to agree; the Rust order is a
deliberate pin with its own test. This is the one place the port left duplication
standing, and the follow-up that removes it is named in the module docs.

## Preserved quirks

Wrong-ish behaviours kept, because changing what an archive imports as is not a
porting decision. Each has a doc comment saying so at the site.

**mbox**
- A preamble before the first `From ` line becomes its **own message**, with
  `from = "unknown@imbib.local"` and no id or date. Anything a mail client wrote
  above the first envelope line imports as a publication.
- No blank line before the body → the headers leak into the body.
- `multipart/*` with no `boundary=` parameter loses the body entirely.
- `extractMessageID` truncates at `@`, so `<abc@imbib.local>` becomes `abc` and
  two archives that reused a local part collide. The value is persisted; changing
  it would orphan every existing dedup match.
- `multipart` decoding is **not recursive** — a nested `multipart/alternative`
  arrives as one part whose content is the inner document verbatim.
- Duplicate headers: last one wins.
- `extractParameter` is unanchored, so `xboundary=` satisfies a request for
  `boundary`.
- A `>From ` envelope line is not recognised as one (the test is
  `hasPrefix("From ")`), so it falls into the header block, where the colon in
  its timestamp makes it parse as a bogus header.

**publishers**
- Host dispatch is `contains`, not a suffix match, in a fixed order — so
  `evil-nature.com.example.org` gets the Nature strategy.
- MDPI appends `/pdf` to *any* path including the bare site root.
- `matches(doi:)` is case-sensitive while `extractArXivID` is not, so
  `10.48550/ARXIV.…` matches no rule at all.
- `constructPDFURL` does not validate the remainder: `10.1038/` yields
  `…/articles/.pdf`.
- The generic parser's four-entity decode (`&amp; &lt; &gt; &quot;` only, no
  numeric forms).

**abstracts**
- `\_` → `_` unconditionally, even in prose, destroying a deliberate escape.
- The `mfrac`/`msqrt` nesting gap (`msup`/`msub` loop to a fixed point, those two
  are single-pass).
- `$5 and $10` reads as inline math.
- `parseSegments` flushes prematurely, so `"before $$ after"` becomes three text
  segments.

**PDF**
- The *document* title must pass `isPlausibleTitle` but the *heuristic* title
  only has to be non-empty, so a two-character heuristic title beats a good
  first-page fragment.
- `bestYear` is heuristic-only; document properties are never consulted.
- `extractMetaContent`: `content=""` → nil but `content="   "` → `Some("")` —
  two answers for two spellings of "no title", and the caller assigns on any
  non-nil, so this decides `<title>` vs `og:title` for real pages.
- The `name:` overload has no reversed-attribute-order pattern, so
  `<meta content="…" name="author">` is not found.

## Duplication retired

| What | Before | After |
|---|---|---|
| Publisher rule table | **3** Swift copies, already disagreeing: `DefaultRules.swift` (16 rules, live), `Publishers/Resources/publisher-rules.json` (12 rules, stale, bundled by `Package.swift` and **never loaded** — `setCustomRulesPath` has zero callers), and `Tools/pdf-resolution-test`'s forked `PublisherInfo` (prefixes spelled without the trailing `/`, so its matches differ) | one Rust `const`, pinned field-by-field by the corpus |
| First-page title heuristic | Swift's `extractTitleFromFirstPage` **and** Rust's `metadata_heuristics::extract_title`, run on the *identical* input string in the same function | Rust only |
| MathML scanner | Swift's `MathMLToLaTeX` and Rust's `mathml_parser` — same regexes, same depth-counting child scanner, four hand-written copies of the collect-then-replace-backwards idiom | one traversal parameterised by `MathTarget::{Unicode, Latex}` |
| Rule lookup determinism | `PublisherRegistry.rule(forDOI:)` iterated a `Dictionary`, so with two matching prefixes the winner was *unspecified* per process launch, and it did not prefer the longer prefix | longest matching prefix, table order as tiebreak |

### The drifted title heuristic was corrupting the common case

Swift's `extractTitleFromFirstPage` and Rust's `metadata_heuristics::extract_title`
ran on the same input; the results went into different fields and `bestTitle`
preferred the Rust one, so Swift's copy was only reachable when Rust returned
nothing. On the 8 corpus first pages they differ on **2**:

- **`simple`** (title line, then a comma-separated byline — the most common real
  PDF shape): Swift returns the title *with the byline glued on*, because its only
  author test is `" and "` plus four capitals, which a comma-separated byline
  sails through. The Rust version runs `looks_like_author_line`, catches the comma
  form, and returns the title alone.
- **`authors-first`** (byline on line 1, title on line 2): Swift answers the
  title; Rust stops at the first author-like line and answers `None`. A
  precision-over-recall trade — past the byline lie affiliations and the abstract
  — and `None` is not a dead end, because `bestTitle` falls through to the
  first-page fragment.

Also fixed while there: the field named `firstPageText` did not hold first-page
text, it held Swift's title guess (contradicting its own doc comment), and
`PDFImportHandler` fed it to an ADS *abstract* query.

## `SmartQueryTranslator` deleted

444 lines of source plus 293 of tests. Wave 5 asserted it was dead; verified
independently before deleting. Its whole reference footprint was 2
self-references, 40 references from its own test file, and 2 documentation
mentions — **zero production consumers**, in any `.swift`, `.rs`, `.pbxproj`,
`Package.swift` or manifest. Its original consumers (`NLSearchService`,
`NLSearchFormView`, `NLSearchOverlayView`) were deleted in `30419c30`; its
function is served by the Rust-backed `FreeTextQueryRewriter.degenerateRewrite`
fallback reached through `SmartSearchService`. It declared no extension, no
conformance and no typealias, so nothing else compiled against it.

The shadowing trap the earlier wave found here is already resolved:
`ADSQueryNormalizer` now has exactly one Swift declaration (in
`packages/ImpressSmartSearch`), and this file's two calls resolved to it.

## The unwired half — a real bug this port does not fix

`AbstractParser` is **unreachable in the shipping app**. Its only caller is
`AbstractRenderer.swift`, whose only references are five `#Preview` blocks and a
`View.abstractText` extension with zero call sites. `containsMath` had exactly one
caller repo-wide: the golden-capture test.

Production abstract rendering is `MathJaxAbstractView`
(`InfoTab.swift:120` on macOS, `IOSInfoTab.swift:203` on iOS), and
`MathJaxView.swift:191` interpolates the raw abstract straight into a WKWebView:

```swift
<div class="content" id="content">\(text)</div>
```

No entity decoding, no `<sub>`/`<sup>`, no MathML conversion, no arXiv
de-escaping. **So a user looking at an arXiv abstract with `\\Omega_m` sees the
raw backslashes, and an ADS abstract's `<mml:math>` renders as markup** — even
though the code that fixes both has been in the tree the whole time.

The port makes that logic reachable (`abstract_parse` over the FFI,
`AbstractParser` as a shim, and a golden corpus where there were zero tests).
Wiring it is one line at `MathJaxView.swift:191`, and it is **deliberately not
done here**: `RichText/MathJaxView.swift` is outside this wave's boundary, and
changing what the detail pane renders is a product decision that deserves its own
before/after, not a side effect of a port wave. It is recorded in
`docs/chassis-capability-matrix.md` as a known gap.

The other remaining Swift duplicate is `MathTextParser` in `RichTextTheme.swift`
— a line-for-line copy of `AbstractParser.parseSegments` with two deliberate
differences (`AbstractParser` trims display-math latex and rejects inline math
containing `\n\n`; `MathTextParser` does neither and rejects any `\n`). It IS
live, via `RichTextView`. Same boundary, same note.

## FFI path

`imbib-core` hosts the UniFFI surface (`src/parsers_ffi.rs`, 22 exports) and PMC
reaches it through `ImbibCore.xcframework`, which every app embedding PMC already
links. **No new xcframework**, no new checksum surface, no app build settings
touched — the same argument as the SmartSearch port.

## MCP surface

`crates/impress-parsers-service` — six tools under `parsers-service_`, generated
from one `#[impress_service]` trait, so each is simultaneously an MCP tool, an
`impress` CLI subcommand and an impel agent tool. Pure functions: no store, no
app, **no network**, so the namespace is absent from `reachability::APP_GATED`
and answers with every app closed.

| Tool | What it exposes |
|---|---|
| `parsers-service_parse-mbox` | an mbox archive → messages with `X-Imbib-*` metadata, decoded bodies and an attachment manifest. Attachment BYTES are withheld (names/types/sizes only) because a library export carries whole PDFs; `max_messages` caps the list and `truncated` says so |
| `parsers-service_decode-mime-header` | RFC 2047 encoded-words, charset-honouring — read a `Subject:` as a human would |
| `parsers-service_decode-quoted-printable` | charset-aware quoted-printable, with the Latin-1 fallback rather than an empty string |
| `parsers-service_resolve-publisher-pdf` | which publisher owns a DOI, whether its PDF URL is predictable, the constructed URL, and a prose recommendation for what to try next |
| `parsers-service_list-publisher-rules` | the whole 16-rule table, so an agent can see *why* a DOI resolves the way it does |
| `parsers-service_extract-landing-page-pdf` | the PDF link out of landing-page markup, naming which strategy ran. **Does not fetch** — that half is Swift |

These automate no chassis-capability-matrix cell; they are not GUI verbs. They
exist because the logic *was* unreachable: it decided whether a paper's PDF could
be downloaded and what an imported archive contained, and an agent had no way to
ask.
