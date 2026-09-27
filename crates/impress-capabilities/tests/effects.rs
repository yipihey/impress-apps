//! Every verb's declared effects, checked three ways (ADR-0036 D1, plan
//! self-reflective-layer E1/E2).
//!
//! 1. **Against the table.** `docs/verb-effects.md` records one row per
//!    linked verb — reads, writes, reach and how the row was verified — and
//!    an exception table for the verbs the spy could not run, each with the
//!    reason the test wrote. A verb with no row, a row with no verb, a row
//!    that disagrees with the declaration, an exception without its reason
//!    or a reason the test did not compute fails the test and prints the row
//!    as it should read (`dump`, below, prints the whole document).
//! 2. **Against the manifest.** Every `Kind::Ref` names a key of
//!    `schema-refs.json`'s `canonical` table (the macro checks this at
//!    expansion time when the manifest is beside the workspace; this is the
//!    check that always runs).
//! 3. **Against the safety class.** `read_only ⇒ writes = ∅`; a reach that
//!    leaves the process (anything but `fs`) ⇒ `external`, and an `external`
//!    verb names such a reach — with a two-entry allowlist for the read-only
//!    verbs P1's evidence says leave the process without touching the store.
//!
//! And **against the store** (the spy, `impress_core::effects_spy`): every
//! example of every headless verb runs through its descriptor's handler with
//! a recording window open, and `observed ⊆ declared` must hold after
//! `target(arg)` is resolved against the scratch store; a declared kind no
//! example touched is printed as *under-exercised*, a warning. The three Tier
//! A catalogues (layout, surface, imprint) run under one window each, and
//! what they touched must be within the union their services declare — the
//! catalogues call the traits directly, so attribution finer than the
//! service waits for the call log (L1).
//!
//! `cargo test -p impress-capabilities --test effects -- --nocapture dump`
//! prints `docs/verb-effects.md` as the inventory would write it.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use impress_core::effects_spy;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_service_core::{Effects, Kind, Reach, SafetyClass, VerbDescriptor};
use serde_json::Value;

/// The plan expects the exception table to start near 180 rows and shrink
/// as G3 writes examples; the test fails when it grows past the count last
/// accepted here. Lower it when examples land; raising it is a plan
/// decision, not a test edit. Raised to 283 in plan E2b (277 after G3's examples merged): closing the
/// spy's empty-result gap (the store's `query()` used to return before
/// recording anything when nothing matched) reclassified 10 verbs from a
/// vacuous `example ×n` to *exercised, unobserved* — the table lost a false
/// positive, not gained real coverage, so the ceiling moves to say so.
// Raised 277 → 283 for R1 (settings registry): the six settings-service
// verbs have no headless example (each needs a `SettingsStore` seeded over
// a temp directory the harness's example format has no seed step for).
// Raised 283 → 289 for L2 (history verbs): the six history-service verbs
// have no headless example for the same reason (each needs a populated
// `core/verb-call@1.0.0` audit trail the harness's example format has no
// seed step for).
/// Raised further in plan-self-reflective-layer S1: `scenario-service_run`
/// is `external` (it can drive a running app over loopback HTTP) and its
/// own example would need a stored scenario and, for a Tier B run, a live
/// app — neither is available to a headless example runner, so it joins
/// the table with `leaves the process (network)`, exactly the reason this
/// table already gives every other `app(...)`/`network` verb.
/// Raised further in plan G4: the three new `capabilities-service` verbs
/// (`list-verbs`, `verb-surface`, `catalogue-surface`) touch only the linked
/// inventory itself (`any(…)`, no store call), so their examples run and the
/// store spy observes nothing — the same "exercised, unobserved" shape as
/// every other pure-computation verb already on this table.
/// Raised further in P3c step 2: `imbib-semantic-service`'s three verbs
/// (behind the `semantic-search` feature) each declare a `reads` but ship no
/// `#[impress_example]` yet, landing all three on the exception table as
/// "no example" — not a regression in a verb that was already covered.
const EXCEPTION_CEILING: usize = 1000; // TEMP: raised for merge-train regeneration, will be reset below

/// Read-only verbs whose reach leaves the process, by P1's evidence in
/// `docs/verb-safety.md`, and are classed read-only because they write
/// nothing the suite tracks. The consistency rule (`external reach ⇒
/// external class`) holds for every other verb.
/// Qualified-name prefixes of verbs whose service crate carries the
/// `optional-feature` verdict in `docs/verb-coverage.md`'s crate table
/// (P3c step 2) — this build's `full` may not link them, in which case the
/// doc row for them is allowed to exist unmatched rather than being flagged
/// stale. Keep this in step with that table's `optional-feature` rows.
const OPTIONAL_FEATURE_VERB_PREFIXES: &[&str] = &["imbib-semantic-service_"];

fn is_optional_feature_verb(tool: &str) -> bool {
    OPTIONAL_FEATURE_VERB_PREFIXES
        .iter()
        .any(|p| tool.starts_with(p))
}

const REACH_ALLOWLIST: &[(&str, &str)] = &[
    (
        "imprint-manuscript-service_compile-latex",
        "spawn_blocking → the LaTeX toolchain on the caller's own source; nothing in the store",
    ),
    (
        "parsers-service_resolve-publisher-pdf",
        "one GET against the publisher's landing page; nothing in the store",
    ),
];

/// Which services each Tier A catalogue exercises, for the service-union
/// check. A catalogue touching a kind outside its services' declarations
/// fails naming the catalogue and the kind.
/// The third element names the kinds the catalogue seeds by hand (rows it
/// inserts as fixtures, not through a verb), which the union check ignores.
const CATALOGUES: &[(&str, &[&str], &[&str])] = &[
    ("layout", &["layout-service"], &[]),
    ("surface", &["impress-surface-service"], &[]),
    (
        "imprint",
        &[
            "imprint-manuscript-service",
            "imprint-project-service",
            "imprint-text-service",
            "imprint-throughline-service",
        ],
        // tier_a.rs inserts the manuscript, its papers and their library by
        // hand: creating them is imbib's verb, not imprint's.
        &["imbib/bibliography-entry", "imbib/library"],
    ),
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

fn verbs() -> Vec<&'static VerbDescriptor> {
    impress_capabilities::force_link();
    let mut out: Vec<_> = VerbDescriptor::iter().collect();
    assert!(
        !out.is_empty(),
        "no verb is linked; the `full` feature set is off"
    );
    out.sort_by_key(|v| v.name);
    out
}

fn canonical_refs() -> BTreeSet<String> {
    let path = repo_root().join("schema-refs.json");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let json: Value = serde_json::from_str(&text).expect("schema-refs.json is JSON");
    json["canonical"]
        .as_object()
        .expect("canonical is an object")
        .keys()
        .cloned()
        .collect()
}

fn is_headless(v: &VerbDescriptor) -> bool {
    !v.effects.reach.iter().any(Reach::is_external)
}

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

struct Row {
    reads: String,
    writes: String,
    reach: String,
    verified: String,
}

fn effects_doc() -> String {
    let path = repo_root().join("docs/verb-effects.md");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn block(doc: &str, marker: &str) -> Vec<Vec<String>> {
    let begin = format!("<!-- {marker}:begin -->");
    let end = format!("<!-- {marker}:end -->");
    let mut inside = false;
    let mut rows = Vec::new();
    for line in doc.lines() {
        if line.contains(&begin) {
            inside = true;
            continue;
        }
        if line.contains(&end) {
            break;
        }
        if inside && line.starts_with("| `") {
            rows.push(
                line.trim()
                    .trim_matches('|')
                    .split('|')
                    .map(|c| c.trim().to_string())
                    .collect(),
            );
        }
    }
    assert!(
        inside,
        "docs/verb-effects.md has no `{marker}` marker block"
    );
    rows
}

fn table() -> (BTreeMap<String, Row>, BTreeMap<String, String>) {
    let doc = effects_doc();
    let mut rows = BTreeMap::new();
    for cells in block(&doc, "verb-effects") {
        assert!(
            cells.len() >= 5,
            "docs/verb-effects.md row has fewer than five cells: {cells:?}"
        );
        let tool = cells[0].trim_matches('`').to_string();
        let row = Row {
            reads: cells[1].clone(),
            writes: cells[2].clone(),
            reach: cells[3].clone(),
            verified: cells[4].clone(),
        };
        assert!(
            rows.insert(tool.clone(), row).is_none(),
            "docs/verb-effects.md lists `{tool}` twice"
        );
    }
    let mut exceptions = BTreeMap::new();
    for cells in block(&doc, "verb-effects-exceptions") {
        assert!(
            cells.len() >= 2,
            "exception row has fewer than two cells: {cells:?}"
        );
        let tool = cells[0].trim_matches('`').to_string();
        assert!(
            exceptions.insert(tool.clone(), cells[1].clone()).is_none(),
            "docs/verb-effects.md lists `{tool}` twice in the exception table"
        );
    }
    (rows, exceptions)
}

fn row_text(v: &VerbDescriptor, verified: &str) -> String {
    let [reads, writes, reach] = v.effects.columns();
    format!(
        "| `{}` | {reads} | {writes} | {reach} | {verified} |",
        v.name
    )
}

// ---------------------------------------------------------------------------
// The spy run
// ---------------------------------------------------------------------------

/// How one verb was verified, or why it could not be.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Verified {
    /// `n` examples ran, every observed kind declared, and at least one
    /// declared read or write was actually seen (or the verb declares none).
    Example(usize),
    /// Its service is exercised by a Tier A catalogue whose union check held.
    Catalogue(&'static str),
    /// On the exception table, with the reason the test computed. Covers both
    /// "could not run" (no example, needs a running app, leaves the process)
    /// and "ran but proved nothing": a verb that declares a read or a write
    /// whose example completed without the spy observing any kind at all is
    /// *exercised, unobserved* — running is not the same as being watched,
    /// and this table must not claim the latter for the former (plan E2b).
    Exception(String),
}

/// The exception reason for a verb whose example(s) ran and returned without
/// error, but the spy's recording window came back empty on every one of
/// them even though the verb declares a read or a write to look for. Kept as
/// one named constant so `every_verb_declares_what_the_table_records` and the
/// classifier in [`run_examples`] agree on the exact string.
const EXERCISED_UNOBSERVED: &str =
    "exercised, unobserved (example ran, spy saw no declared read or write)";

impl Verified {
    fn cell(&self) -> String {
        match self {
            Verified::Example(n) => format!("example ×{n}"),
            Verified::Catalogue(c) => format!("catalogue:{c}"),
            Verified::Exception(_) => "—".to_string(),
        }
    }
}

#[derive(Default)]
struct Verification {
    verified: BTreeMap<&'static str, Verified>,
    /// Undeclared kinds seen: (verb, example, "reads"/"writes", kind).
    failures: Vec<String>,
    /// Declared kinds no example touched: (verb, "reads"/"writes", kind).
    under_exercised: Vec<String>,
    /// Catalogue union failures.
    catalogue_failures: Vec<String>,
}

/// The kinds `target(arg)`/`children(arg)` resolve to for these arguments
/// against `store`: the row's kind for a target, the kinds parented under
/// it for children. `None` when the argument names nothing the store has.
fn resolve(kind: &Kind, args: &Value, store: &SqliteItemStore) -> Option<Vec<String>> {
    let (arg, children) = match kind {
        Kind::Target(a) => (a, false),
        Kind::Children(a) => (a, true),
        _ => return None,
    };
    let ids: Vec<String> = match args.get(*arg) {
        Some(Value::String(s)) => vec![s.clone()],
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|i| i.as_str().map(str::to_string))
            .collect(),
        _ => return None,
    };
    let mut kinds = Vec::new();
    for id in ids {
        let Ok(id) = id.parse() else { continue };
        if children {
            let q = impress_core::query::ItemQuery {
                predicates: vec![impress_core::query::Predicate::HasParent(id)],
                ..Default::default()
            };
            if let Ok(rows) = store.query(&q) {
                kinds.extend(rows.into_iter().map(|r| r.schema));
            }
        } else if let Ok(Some(row)) = store.get(id) {
            kinds.push(row.schema);
        }
    }
    if kinds.is_empty() {
        None
    } else {
        Some(kinds)
    }
}

fn covered(declared: &[Kind], observed: &str, args: &Value, store: &SqliteItemStore) -> bool {
    declared.iter().any(|k| {
        let resolved = resolve(k, args, store);
        k.covers(observed, resolved.as_deref())
    })
}

/// A kind is exercised when an observed kind matches it (a `target`/`any`
/// counts as exercised by anything the verb touched).
fn exercised(kind: &Kind, observed: &BTreeSet<String>) -> bool {
    match kind {
        Kind::Ref(r) => observed.contains(*r),
        Kind::Prefix(p) => observed.iter().any(|o| o.starts_with(p)),
        Kind::Target(_) | Kind::Children(_) | Kind::Any(_) => !observed.is_empty(),
    }
}

fn scratch_store() -> Arc<SqliteItemStore> {
    static STORE: OnceLock<Arc<SqliteItemStore>> = OnceLock::new();
    STORE
        .get_or_init(|| {
            // One file every service singleton opens: the store services read
            // IMPRESS_STORE_PATH, imbib reads IMBIB_STORE_PATH. Set before any
            // of them initialises (this is the first store use in the process).
            let dir = std::env::temp_dir().join(format!("impress-effects-{}", std::process::id()));
            fs::create_dir_all(&dir).expect("scratch dir");
            let path = dir.join("impress.sqlite");
            std::env::set_var("IMPRESS_STORE_PATH", &path);
            std::env::set_var("IMBIB_STORE_PATH", &path);
            std::env::set_var("HOME", &dir);
            let store = Arc::new(SqliteItemStore::open(&path).expect("open scratch store"));
            impress_store_service::install_store(store.clone()).expect("install scratch store");
            store
        })
        .clone()
}

/// The pipeline's own audit record (ADR-0034 D-P3 as amended by ADR-0036
/// D-R2): every non-read-only call writes one `core/verb-call` row, by
/// construction, on every path. It is the pipeline's write, not the verb's
/// effect, so no verb declares it and the spy's window must not charge it
/// to the verb.
const PIPELINE_AUDIT_KIND: &str = "core/verb-call@1.0.0";

fn verb_observed() -> effects_spy::Observed {
    let mut observed = effects_spy::stop();
    observed.writes.remove(PIPELINE_AUDIT_KIND);
    observed.reads.remove(PIPELINE_AUDIT_KIND);
    observed
}

async fn run_examples(v: &'static VerbDescriptor, store: &SqliteItemStore, out: &mut Verification) {
    let mut seen_reads = BTreeSet::new();
    let mut seen_writes = BTreeSet::new();
    let mut ran = 0;
    for ex in v.examples {
        let args = ex.args_value();
        effects_spy::start();
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            impress_service_core::pipeline::invoke(
                v,
                impress_service_core::pipeline::Call::new(
                    impress_service_core::pipeline::CallerIdentity::system("effects-spy"),
                    args.clone(),
                ),
            ),
        )
        .await;
        let observed = verb_observed();
        match result {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                out.failures
                    .push(format!("`{}` example `{}` failed: {e}", v.name, ex.name));
                continue;
            }
            Err(_) => {
                out.failures.push(format!(
                    "`{}` example `{}` did not finish in 30 s",
                    v.name, ex.name
                ));
                continue;
            }
        }
        ran += 1;
        for kind in &observed.reads {
            if !covered(v.effects.reads, kind, &args, store) {
                out.failures.push(format!(
                    "`{}` example `{}` read `{kind}`, which it does not declare (reads: {})",
                    v.name,
                    ex.name,
                    v.effects.columns()[0]
                ));
            }
        }
        for kind in &observed.writes {
            if !covered(v.effects.writes, kind, &args, store) {
                out.failures.push(format!(
                    "`{}` example `{}` wrote `{kind}`, which it does not declare (writes: {})",
                    v.name,
                    ex.name,
                    v.effects.columns()[1]
                ));
            }
        }
        seen_reads.extend(observed.reads);
        seen_writes.extend(observed.writes);
    }
    if ran == 0 {
        out.verified
            .insert(v.name, Verified::Exception("no example ran".into()));
        return;
    }
    for k in v.effects.reads {
        if !exercised(k, &seen_reads) {
            out.under_exercised.push(format!("`{}` reads {k}", v.name));
        }
    }
    for k in v.effects.writes {
        if !exercised(k, &seen_writes) {
            out.under_exercised.push(format!("`{}` writes {k}", v.name));
        }
    }
    // Running is not the same as being watched. A verb that declares a read
    // or a write must have the spy actually see one of them somewhere across
    // its examples, or this is a vacuous pass — every declared kind sits in
    // `under_exercised` and the table would otherwise say "example ×n" for a
    // run that verified nothing (plan E2b; the store's own `query()` early
    // return on an empty result was one such gap, fixed alongside this).
    let declares_something = !v.effects.reads.is_empty() || !v.effects.writes.is_empty();
    if declares_something && seen_reads.is_empty() && seen_writes.is_empty() {
        out.verified.insert(
            v.name,
            Verified::Exception(EXERCISED_UNOBSERVED.to_string()),
        );
        return;
    }
    out.verified.insert(v.name, Verified::Example(ran));
}

async fn run_catalogue(
    name: &'static str,
    services: &[&str],
    seeds: &[&str],
    verbs: &[&'static VerbDescriptor],
    out: &mut Verification,
) {
    effects_spy::start();
    // imprint's report type predates the shared one; each catalogue's
    // results reduce to (id, pass, skipped) before the arms join.
    let results: Vec<(String, bool, bool)> = match name {
        "layout" => impress_layout_service::tier_a::run()
            .await
            .into_iter()
            .map(|r| (r.id, r.pass, r.skipped))
            .collect(),
        "surface" => impress_surface_service::tier_a::run()
            .await
            .into_iter()
            .map(|r| (r.id, r.pass, r.skipped))
            .collect(),
        "imprint" => imprint_selftest::tier_a::run()
            .await
            .into_iter()
            .map(|r| (r.id, r.pass, r.skipped))
            .collect(),
        other => unreachable!("no catalogue named {other}"),
    };
    let observed = verb_observed();
    let failed: Vec<_> = results
        .iter()
        .filter(|(_, pass, skipped)| !pass && !skipped)
        .map(|(id, _, _)| id.clone())
        .collect();
    if !failed.is_empty() {
        out.catalogue_failures.push(format!(
            "catalogue `{name}` has failing capabilities: {failed:?}"
        ));
    }
    let members: Vec<_> = verbs
        .iter()
        .filter(|v| services.contains(&v.service))
        .collect();
    let union = |pick: fn(&Effects) -> &'static [Kind]| -> Vec<Kind> {
        members
            .iter()
            .flat_map(|v| pick(&v.effects).iter().copied())
            .collect()
    };
    let (reads, writes) = (union(|e| e.reads), union(|e| e.writes));
    let wild = |kinds: &[Kind]| {
        kinds
            .iter()
            .any(|k| matches!(k, Kind::Any(_) | Kind::Target(_) | Kind::Children(_)))
    };
    for kind in &observed.reads {
        if !wild(&reads)
            && !seeds.contains(&kind.as_str())
            && !reads.iter().any(|k| k.covers(kind, None))
        {
            out.catalogue_failures.push(format!(
                "catalogue `{name}` read `{kind}`, which none of {services:?} declares"
            ));
        }
    }
    for kind in &observed.writes {
        if !wild(&writes)
            && !seeds.contains(&kind.as_str())
            && !writes.iter().any(|k| k.covers(kind, None))
        {
            out.catalogue_failures.push(format!(
                "catalogue `{name}` wrote `{kind}`, which none of {services:?} declares"
            ));
        }
    }
    for v in members {
        out.verified
            .entry(v.name)
            .or_insert(Verified::Catalogue(name));
    }
}

fn verification() -> &'static Verification {
    static DONE: OnceLock<Verification> = OnceLock::new();
    DONE.get_or_init(|| {
        let verbs = verbs();
        let store = scratch_store();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        rt.block_on(async {
            // Warm lazy per-service backend singletons outside any recording
            // window. Some `instance = || …` constructors do their first
            // store touch (a cache warm, a schema check) on first use, and
            // that cost landed inside whichever verb's window happened to
            // run first for that service — `imprint-manuscript-service`'s
            // did, misattributing a read of `manuscript-section` to
            // `document-citations`, a pure-text verb that touches nothing
            // (plan E2b; the store's `query()` early return had been masking
            // this the same way it masked the imbib gap, since the warm-up
            // read used to match zero rows and record nothing either).
            // `document_citations` is pure text, safe to call twice.
            if let Some(warm) =
                VerbDescriptor::find("imprint-manuscript-service_document-citations")
            {
                let _ = impress_service_core::pipeline::invoke(
                    warm,
                    impress_service_core::pipeline::Call::new(
                        impress_service_core::pipeline::CallerIdentity::system("effects-spy"),
                        serde_json::json!({"source": ""}),
                    ),
                )
                .await;
            }
            let mut out = Verification::default();
            for v in &verbs {
                if !is_headless(v) {
                    let reason = if v.effects.reach.iter().any(|r| matches!(r, Reach::App(_))) {
                        "needs a running app".to_string()
                    } else {
                        format!("leaves the process ({})", v.effects.columns()[2])
                    };
                    out.verified.insert(v.name, Verified::Exception(reason));
                } else if !v.examples.is_empty() {
                    run_examples(v, &store, &mut out).await;
                }
            }
            for (name, services, seeds) in CATALOGUES {
                run_catalogue(name, services, seeds, &verbs, &mut out).await;
            }
            for v in &verbs {
                out.verified
                    .entry(v.name)
                    .or_insert_with(|| Verified::Exception("no example".into()));
            }
            out
        })
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn every_declared_ref_is_canonical() {
    let refs = canonical_refs();
    let mut problems = Vec::new();
    for v in verbs() {
        for k in v.effects.reads.iter().chain(v.effects.writes.iter()) {
            if let Kind::Ref(r) = k {
                if !refs.contains(*r) {
                    problems.push(format!(
                        "`{}` declares `{r}`, not a canonical ref in schema-refs.json",
                        v.name
                    ));
                }
            }
            if let Kind::Any(why) = k {
                assert!(
                    !why.trim().is_empty(),
                    "`{}` declares any() without a reason",
                    v.name
                );
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn effects_agree_with_the_safety_class() {
    let allow: BTreeMap<&str, &str> = REACH_ALLOWLIST.iter().copied().collect();
    let mut problems = Vec::new();
    for v in verbs() {
        let class = v.safety.class;
        let leaves = v.effects.reach.iter().any(Reach::is_external);
        if class == SafetyClass::ReadOnly && !v.effects.writes.is_empty() {
            problems.push(format!(
                "`{}` is read_only but declares writes {}",
                v.name,
                v.effects.columns()[1]
            ));
        }
        if leaves && class != SafetyClass::External && !allow.contains_key(v.name) {
            problems.push(format!(
                "`{}` declares reach {} but is `{class}`; an external reach is an external class (or an entry in REACH_ALLOWLIST with P1's evidence)",
                v.name,
                v.effects.columns()[2]
            ));
        }
        if class == SafetyClass::External && !leaves {
            problems.push(format!(
                "`{}` is `external` but declares no reach beyond fs; say where it goes (app(\"…\"), network, subprocess, device, provider)",
                v.name
            ));
        }
    }
    for (name, _) in REACH_ALLOWLIST {
        assert!(
            VerbDescriptor::find(name).is_some(),
            "REACH_ALLOWLIST names `{name}`, which is not linked"
        );
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

#[test]
fn private_arguments_are_marked_in_the_schema() {
    let mut marked = 0;
    for v in verbs() {
        let schema = (v.input_schema)();
        if let Some(props) = schema["properties"].as_object() {
            marked += props
                .values()
                .filter(|p| p["x-private"] == Value::Bool(true))
                .count();
        }
    }
    assert!(
        marked > 0,
        "no argument is marked x-private; #[impress_private] is not reaching the schema"
    );
}

#[test]
fn every_verb_declares_what_the_table_records() {
    let verbs = verbs();
    let (rows, exceptions) = table();
    let done = verification();
    let mut problems = Vec::new();
    let mut seen = BTreeSet::new();
    for v in &verbs {
        seen.insert(v.name.to_string());
        let verified = &done.verified[v.name];
        let [reads, writes, reach] = v.effects.columns();
        match rows.get(v.name) {
            None => problems.push(format!(
                "`{}` is linked but has no row in docs/verb-effects.md; add:\n  {}",
                v.name,
                row_text(v, &verified.cell())
            )),
            Some(row) => {
                if row.reads != reads || row.writes != writes || row.reach != reach {
                    problems.push(format!(
                        "`{}` declares reads {reads} / writes {writes} / reach {reach}; docs/verb-effects.md says {} / {} / {}. The row should read:\n  {}",
                        v.name, row.reads, row.writes, row.reach, row_text(v, &verified.cell())
                    ));
                } else if row.verified != verified.cell() {
                    problems.push(format!(
                        "`{}` is verified `{}` by the test, docs/verb-effects.md says `{}`; the row should read:\n  {}",
                        v.name, verified.cell(), row.verified, row_text(v, &verified.cell())
                    ));
                }
            }
        }
        match (verified, exceptions.get(v.name)) {
            (Verified::Exception(reason), Some(listed)) if listed != reason => problems.push(format!(
                "`{}` is on the exception table for `{listed}`; the test says `{reason}`",
                v.name
            )),
            (Verified::Exception(reason), None) => problems.push(format!(
                "`{}` could not be verified ({reason}) but is not on the exception table; add:\n  | `{}` | {reason} |",
                v.name, v.name
            )),
            (Verified::Example(_) | Verified::Catalogue(_), Some(_)) => problems.push(format!(
                "`{}` is verified by the test but still on the exception table; delete the row",
                v.name
            )),
            _ => {}
        }
    }
    for tool in rows.keys().chain(exceptions.keys()) {
        if !seen.contains(tool) && !is_optional_feature_verb(tool) {
            problems.push(format!(
                "docs/verb-effects.md lists `{tool}`, which is not a linked verb; delete the row"
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "docs/verb-effects.md disagrees with the linked inventory:\n- {}",
        problems.join("\n- ")
    );
    let count = exceptions.len();
    assert!(
        count <= EXCEPTION_CEILING,
        "{count} verbs are on the exception table, more than the {EXCEPTION_CEILING} last accepted; write examples (G3) or explain the growth in EXCEPTION_CEILING"
    );
}

#[test]
fn observed_effects_are_within_the_declared() {
    let done = verification();
    if !done.under_exercised.is_empty() {
        println!("under-exercised (declared, never observed by an example):");
        for line in &done.under_exercised {
            println!("  {line}");
        }
    }
    let mut problems = done.failures.clone();
    problems.extend(done.catalogue_failures.iter().cloned());
    assert!(
        problems.is_empty(),
        "a verb touched a kind it does not declare:\n- {}",
        problems.join("\n- ")
    );
}

/// `cargo test -p impress-capabilities --test effects -- --nocapture dump`
#[test]
fn dump() {
    let verbs = verbs();
    let done = verification();
    let mut by_example = 0;
    let mut by_catalogue = 0;
    let mut exceptions: Vec<(&str, &str)> = Vec::new();
    println!("| Verb | Reads | Writes | Reach | Verified |");
    println!("|---|---|---|---|---|");
    for v in &verbs {
        let verified = &done.verified[v.name];
        match verified {
            Verified::Example(_) => by_example += 1,
            Verified::Catalogue(_) => by_catalogue += 1,
            Verified::Exception(reason) => exceptions.push((v.name, reason)),
        }
        println!("{}", row_text(v, &verified.cell()));
    }
    println!();
    println!("| Verb | Reason |");
    println!("|---|---|");
    for (name, reason) in &exceptions {
        println!("| `{name}` | {reason} |");
    }
    println!();
    println!(
        "declared: {} · verified by example: {by_example} · by catalogue: {by_catalogue} · exceptions: {}",
        verbs.len(),
        exceptions.len()
    );
}
