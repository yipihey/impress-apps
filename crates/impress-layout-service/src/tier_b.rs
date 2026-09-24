//! Tier B capabilities — drive the RUNNING impress app over its HTTP
//! automation surface.
//!
//! Tier A proves the verbs against an in-memory store. It cannot prove that
//! the Swift host forwards them, that the tree a person is looking at moves,
//! or that a surface renders where a pane is. That is this tier's whole job:
//! every check below is a round trip through `/api/layout/*` or
//! `/api/surface/*` against a real app, and the evidence is what the app
//! reported back.
//!
//! **Auto-skip.** One `GET /api/status` probe gates the tier. No app → every
//! capability reports `skipped`, and the report passes: a headless CI box with
//! no GUI must stay green, and a skip that says why is not a pass that lies
//! (ADR-0032). This mirrors `imprint_selftest::tier_b::run`'s structure
//! exactly.
//!
//! **Restore what you change.** The catalogue mutates the live tree of an app
//! someone may be using. So it opens by saving the current arrangement as a
//! throwaway named layout, and closes — unconditionally, whatever happened in
//! between — by applying that layout back and deleting it, and by deleting
//! every surface it created. The restore is itself a reported capability, so a
//! failure to clean up is visible rather than silent.
//!
//! **The shapes are copied from Rust, never from prose.** The verb bodies are
//! `impress_layout::Verb`'s own serde spelling (`#[serde(tag = "verb",
//! rename_all = "kebab-case")]`, snake_case fields); the `op` bodies are the
//! six operations `LayoutAutomationRoutes.operations` forwards; the surface
//! event is `impress_surface::Event` (`{"widget", "kind", "value"}`). A
//! capability that guessed a field name would fail as a refusal, which is the
//! right failure — but the point of naming the sources here is that none of
//! them were guessed.

use std::time::Duration;

use serde_json::{json, Value};

use crate::{check, skipped, CapabilityResult, Tier};

/// Where impress listens: `SiblingApp.impress`'s `httpPort`. The table in
/// `ImpressKit/SiblingApp.swift` assigns the port and servers align to it, so
/// this constant is a copy of that table's value, not an independent choice.
pub const IMPRESS_BASE_URL: &str = "http://127.0.0.1:23125";

/// The environment variable that points the catalogue at a DIFFERENT app.
///
/// Tier B drives whatever chassis app is listening, not impress specifically:
/// every capability it asserts is over `/api/layout/*` and `/api/surface/*`,
/// which every app in the suite serves, and its one preset assumption is
/// "ordinal 1 is this app's own Default" — true for implore, impart and impel
/// as much as for impress (`presets::ordinal_targets` numbers the shipped
/// presets first, per app).
///
/// An ENV VAR rather than a second argument on `run_selftest`: that verb's
/// arguments are vocabulary, and changing them is a decision this catalogue
/// does not get to make on its own (plan wave 6, "Ask first"). The default is
/// unchanged, so every existing caller still drives impress on 23125.
///
/// ```text
/// IMPRESS_LAYOUT_SELFTEST_BASE_URL=http://127.0.0.1:23123 \
///     implore layout-selftest-service_run-selftest --tier b
/// ```
pub const BASE_URL_ENV: &str = "IMPRESS_LAYOUT_SELFTEST_BASE_URL";

/// The base url Tier B should drive: the override when it is set and
/// non-empty, `IMPRESS_BASE_URL` otherwise.
pub fn configured_base_url() -> String {
    base_url_from(std::env::var(BASE_URL_ENV).ok())
}

/// The override rule, as a pure function so it has a test: a set,
/// non-blank value wins (trimmed — a trailing newline out of a shell is not
/// a different host); anything else is impress.
pub fn base_url_from(override_value: Option<String>) -> String {
    match override_value {
        Some(value) if !value.trim().is_empty() => value.trim().to_string(),
        _ => IMPRESS_BASE_URL.to_string(),
    }
}

/// The name the catalogue saves the live arrangement under before it touches
/// anything. Deliberately unlikely to collide with a human's layout, and
/// deleted again by the restore step.
const RESTORE_LAYOUT: &str = "__tier-b-selftest-restore__";

/// The name of the scratch surface the surface capability creates.
const SCRATCH_SURFACE: &str = "__tier-b-selftest__";

/// Every capability id this tier reports, in order. Written out so the
/// skip-when-unreachable path and the live path cannot drift: the skip branch
/// maps this list, so a capability added below without a description here
/// fails to compile rather than silently vanishing from a headless run.
const CATALOGUE: [(&str, &str); 8] = [
    ("app.reachable", "impress HTTP automation is reachable"),
    (
        "layout.apply_preset",
        "Applying a preset by ordinal rebuilds the tree",
    ),
    (
        "layout.version_moves",
        "split / resize / swap / close each advance `version`",
    ),
    (
        "layout.saved_round_trip",
        "save / apply / delete a named layout",
    ),
    (
        "layout.channel_selection",
        "A `select` in the list pane reaches the info pane's channel param",
    ),
    (
        "surface.show_and_dispatch",
        "A surface renders and a dispatched event changes its state",
    ),
    (
        "layout.hidden_share",
        "A pane resizes to HIDDEN_SHARE and back",
    ),
    (
        "layout.outline_collection_row",
        "Selecting an outline collection row re-queries the list pane, and `info` follows a list selection",
    ),
];

// ─── the tiny HTTP client ────────────────────────────────────────────────
//
// `reqwest` directly rather than `impress-app-client`: that crate's typed
// clients are built on `imbib-service` and `imprint-service`, i.e. two whole
// domain stacks, and this crate is kit-adjacent (ADR-0033 D7). Taking them on
// to make seven loopback requests is the exact trade `report.rs`'s header
// refuses for forty lines of structs. `imprint-selftest` makes its own raw
// `reqwest` calls for the same reason.

/// A loopback JSON client over one app's automation surface.
struct Http {
    client: reqwest::Client,
    base: String,
}

impl Http {
    fn new(base: &str) -> Self {
        // `no_proxy`: every request here goes to 127.0.0.1, where a proxy is
        // never the right route — and asking macOS for the proxy config from
        // a sandboxed process can abort (see `impress-app-client`'s
        // `loopback_http_client`, which exists because of that crash).
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            client,
            base: base.trim_end_matches('/').to_string(),
        }
    }

    async fn get(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("GET {path}: {e}"))?;
        decode(path, response).await
    }

    async fn post(&self, path: &str, body: &Value) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .post(&url)
            .json(body)
            .send()
            .await
            .map_err(|e| format!("POST {path}: {e}"))?;
        decode(path, response).await
    }

    async fn delete(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        let response = self
            .client
            .delete(&url)
            .send()
            .await
            .map_err(|e| format!("DELETE {path}: {e}"))?;
        decode(path, response).await
    }

    /// `POST /api/layout/verb` with one `impress_layout::Verb` body.
    async fn verb(&self, verb: &Value) -> Result<Value, String> {
        self.post("/api/layout/verb", verb).await
    }

    /// `POST /api/layout/op` with one of the six non-`Verb` operations.
    async fn op(&self, op: &Value) -> Result<Value, String> {
        self.post("/api/layout/op", op).await
    }

    /// `GET /api/layout/tree`.
    async fn tree(&self) -> Result<Value, String> {
        self.get("/api/layout/tree").await
    }

    /// The tree's `version`, which is top-level beside `layout` (not inside
    /// it) — `LayoutController.layoutTreeJSON` builds it that way.
    async fn version(&self) -> Result<u64, String> {
        let tree = self.tree().await?;
        tree.get("version")
            .and_then(Value::as_u64)
            .ok_or_else(|| "tree response carried no `version`".to_string())
    }
}

/// Read one response: non-2xx, or a `{"status":"error"}` envelope, is an error
/// carrying whatever the app said. The layout routes wrap success in
/// `{"status":"ok", …}`; the surface routes answer bare JSON. Both are handled
/// by checking for the error shapes rather than requiring the ok shape.
async fn decode(path: &str, response: reqwest::Response) -> Result<Value, String> {
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|e| format!("{path}: reading body: {e}"))?;
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| format!("{path}: HTTP {status}, body is not JSON ({e}): {text}"))?;
    if !status.is_success() {
        let reason = value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or(text.as_str());
        return Err(format!("{path}: HTTP {status}: {reason}"));
    }
    if value.get("status").and_then(Value::as_str) == Some("error") {
        let reason = value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("unspecified");
        return Err(format!("{path}: refused: {reason}"));
    }
    Ok(value)
}

// ─── tree readers ─────────────────────────────────────────────────────────

/// The `layout` object out of a tree (or verb) response.
fn layout_of(tree: &Value) -> Result<&Value, String> {
    tree.get("layout")
        .filter(|l| l.is_object())
        .ok_or_else(|| "response carried no `layout` object".to_string())
}

/// Every `(tile id, pane)` pair in the tree, in tile order.
fn panes(tree: &Value) -> Result<Vec<(u64, &Value)>, String> {
    let tiles = layout_of(tree)?
        .get("tiles")
        .and_then(Value::as_object)
        .ok_or_else(|| "layout carried no `tiles`".to_string())?;
    let mut out = Vec::new();
    for (id, tile) in tiles {
        if let Some(pane) = tile.get("pane") {
            if let Ok(id) = id.parse::<u64>() {
                out.push((id, pane));
            }
        }
    }
    out.sort_by_key(|(id, _)| *id);
    Ok(out)
}

/// The tile id of the pane holding `role` (`navigator`, `list`, `detail`).
fn tile_with_role(tree: &Value, role: &str) -> Result<u64, String> {
    panes(tree)?
        .into_iter()
        .find(|(_, pane)| pane.get("role").and_then(Value::as_str) == Some(role))
        .map(|(id, _)| id)
        .ok_or_else(|| format!("no pane carries the `{role}` role"))
}

/// The linear container holding `tile`, as `(container id, children, shares)`.
///
/// Shares live on the container as a parallel `shares` array — there is no
/// per-tile `share` field (`impress_layout::Container::Linear`), so reading
/// one pane's share means finding its index among its parent's children.
fn linear_parent(tree: &Value, tile: u64) -> Result<(u64, Vec<u64>, Vec<f64>), String> {
    let tiles = layout_of(tree)?
        .get("tiles")
        .and_then(Value::as_object)
        .ok_or_else(|| "layout carried no `tiles`".to_string())?;
    for (id, value) in tiles {
        let Some(linear) = value.get("container").and_then(|c| c.get("linear")) else {
            continue;
        };
        let children: Vec<u64> = linear
            .get("children")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_u64).collect())
            .unwrap_or_default();
        if !children.contains(&tile) {
            continue;
        }
        let shares: Vec<f64> = linear
            .get("shares")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default();
        let container = id
            .parse::<u64>()
            .map_err(|_| format!("container id `{id}` is not a number"))?;
        return Ok((container, children, shares));
    }
    Err(format!("tile {tile} has no linear parent"))
}

/// One pane's share, read through its parent container.
fn share_of(tree: &Value, tile: u64) -> Result<f64, String> {
    let (container, children, shares) = linear_parent(tree, tile)?;
    let index = children
        .iter()
        .position(|c| *c == tile)
        .ok_or_else(|| format!("tile {tile} vanished from container {container}"))?;
    shares
        .get(index)
        .copied()
        .ok_or_else(|| format!("container {container} has no share at index {index}"))
}

/// A minimal but valid `PaneQuery` — every field the algebra requires,
/// spelled as `impress_core::pane_query::PaneQuery` serialises it.
fn any_publication_query() -> Value {
    json!({
        "kinds": ["publication"],
        "scope": { "scope": "all" },
        "filters": [],
        "text": null,
        "relation": null,
        "sort": [],
        "limit": null
    })
}

// ─── the catalogue ────────────────────────────────────────────────────────

/// Run every Tier B capability against `base_url`, restoring what it changed.
pub async fn run(base_url: &str) -> Vec<CapabilityResult> {
    let http = Http::new(base_url);

    // One probe gates the tier. `/api/status` is the shared automation
    // surface's own liveness route, answered by every app in the suite.
    let status = match http.get("/api/status").await {
        Ok(status) => status,
        Err(reason) => {
            let reason = format!("no impress app responding at {base_url} ({reason})");
            return CATALOGUE
                .iter()
                .map(|(id, description)| {
                    let why = if *id == "app.reachable" {
                        reason.as_str()
                    } else {
                        "app not running"
                    };
                    skipped(id, description, Tier::B, why)
                })
                .collect();
        }
    };

    let mut out = vec![
        check(CATALOGUE[0].0, CATALOGUE[0].1, Tier::B, || async {
            Ok(format!(
                "app={}, version={}, port={}",
                status.get("app").and_then(Value::as_str).unwrap_or("?"),
                status.get("version").and_then(Value::as_str).unwrap_or("?"),
                status.get("port").and_then(Value::as_u64).unwrap_or(0),
            ))
        })
        .await,
    ];

    // Before anything mutates: park the live arrangement under a name we can
    // apply back. If this fails the catalogue still runs — but the restore
    // step will say it had nothing to restore from, rather than pretending.
    let parked = http
        .op(&json!({
            "op": "save-layout",
            "name": RESTORE_LAYOUT,
            "purpose": "tier-b self-test restore point"
        }))
        .await
        .is_ok();

    // Surfaces this run created, deleted by the restore step whatever happens.
    let mut created_surfaces: Vec<String> = Vec::new();

    out.push(apply_preset_capability(&http).await);
    out.push(version_moves_capability(&http).await);
    out.push(saved_layout_capability(&http).await);
    out.push(channel_selection_capability(&http).await);
    out.push(surface_capability(&http, &mut created_surfaces).await);
    out.push(hidden_share_capability(&http).await);
    out.push(outline_collection_capability(&http).await);

    // The `finally`. Nothing above uses `?` at this level, so control always
    // arrives here — a failed capability leaves the tree dirty for exactly as
    // long as it takes to get to this line.
    out.push(restore_capability(&http, parked, &created_surfaces).await);

    out
}

/// 1. Apply a preset by ordinal and read the tree back.
///
/// Ordinal 1 is the app's own default preset: `presets::ordinal_targets`
/// numbers the shipped presets first, then the user's presets, then the named
/// layouts, so position 1 means the same thing on a machine that has never
/// opened the app.
async fn apply_preset_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[1];
    check(id, description, Tier::B, || async {
        http.op(&json!({ "op": "apply-layout", "ordinal": 1 }))
            .await?;
        let tree = http.tree().await?;
        let version = tree
            .get("version")
            .and_then(Value::as_u64)
            .ok_or_else(|| "tree carried no `version` after apply-layout".to_string())?;
        let panes = panes(&tree)?;
        if panes.is_empty() {
            return Err("the tree has no panes after applying ordinal 1".into());
        }
        let kinds: Vec<&str> = panes
            .iter()
            .filter_map(|(_, p)| p.get("view_kind").and_then(Value::as_str))
            .collect();
        Ok(format!(
            "ordinal 1 applied: version={version}, {} panes ({})",
            panes.len(),
            kinds.join(", ")
        ))
    })
    .await
}

/// 2. Split / resize / swap / close, each advancing `version`.
///
/// Strictly increasing, checked between every step: a verb the host accepted
/// but did not apply would leave the version still and is the failure this
/// capability exists to catch.
async fn version_moves_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[2];
    check(id, description, Tier::B, || async {
        let mut steps: Vec<String> = Vec::new();
        let mut version = http.version().await?;

        let mut advanced = |label: &str, before: u64, after: u64| -> Result<(), String> {
            if after <= before {
                return Err(format!(
                    "{label} did not advance `version` ({before} → {after})"
                ));
            }
            steps.push(format!("{label} {before}→{after}"));
            Ok(())
        };

        // Split the detail pane. Focus follows the new pane, and the response
        // names the tiles it changed — we take the new tile from the tree
        // rather than the response so the reader is the same one a person's
        // app uses.
        let before = version;
        let detail = tile_with_role(&http.tree().await?, "detail")?;
        let split = http
            .verb(&json!({
                "verb": "split",
                "target": { "ref": "id", "tile": detail },
                "dir": "horizontal",
                "after": true,
                "new": {
                    "query": any_publication_query(),
                    "view_kind": "info",
                    "channel": { "number": 1 }
                }
            }))
            .await?;
        version = http.version().await?;
        advanced("split", before, version)?;
        let new_tile = split
            .get("focused")
            .and_then(Value::as_u64)
            .ok_or_else(|| "split did not report a focused tile".to_string())?;

        // Resize the container the split produced, through `Verb::Resize`
        // (the whole-container form; `resize-share` is capability 6).
        let before = version;
        let tree = http.tree().await?;
        let (container, children, _) = linear_parent(&tree, new_tile)?;
        let even: Vec<f64> = children.iter().map(|_| 1.0).collect();
        http.verb(&json!({
            "verb": "resize",
            "container": container,
            "shares": even
        }))
        .await?;
        version = http.version().await?;
        advanced("resize", before, version)?;

        // Swap two roles and swap them straight back, so the capability's own
        // arrangement change nets out even before the restore step.
        let before = version;
        let swap = json!({
            "verb": "swap",
            "a": { "ref": "role", "role": "list" },
            "b": { "ref": "role", "role": "detail" }
        });
        http.verb(&swap).await?;
        version = http.version().await?;
        advanced("swap", before, version)?;
        let before = version;
        http.verb(&swap).await?;
        version = http.version().await?;
        advanced("swap-back", before, version)?;

        // Close the pane the split created, leaving the tree as it was found.
        let before = version;
        http.verb(&json!({
            "verb": "close",
            "target": { "ref": "id", "tile": new_tile }
        }))
        .await?;
        version = http.version().await?;
        advanced("close", before, version)?;

        Ok(steps.join(", "))
    })
    .await
}

/// 3. Save a layout, see it listed, apply it back, delete it, see it gone.
async fn saved_layout_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[3];
    const NAME: &str = "__tier-b-selftest-layout__";
    check(id, description, Tier::B, || async {
        // Names are listed under `layouts` with their own ordinals; this reads
        // by name, because the `apply-layout` ordinal space is the *union* of
        // presets and layouts and so does not match this list's numbering.
        let named = |list: &Value| -> bool {
            list.get("layouts")
                .and_then(Value::as_array)
                .map(|rows| {
                    rows.iter()
                        .any(|r| r.get("name").and_then(Value::as_str) == Some(NAME))
                })
                .unwrap_or(false)
        };

        http.op(&json!({
            "op": "save-layout",
            "name": NAME,
            "purpose": "tier-b self-test"
        }))
        .await?;
        if !named(&http.get("/api/layout/layouts").await?) {
            return Err(format!(
                "`{NAME}` was saved but is not in /api/layout/layouts"
            ));
        }

        let applied = http
            .op(&json!({ "op": "apply-layout", "name": NAME }))
            .await?;
        let version = applied
            .get("version")
            .and_then(Value::as_u64)
            .ok_or_else(|| "apply-layout reported no `version`".to_string())?;

        http.op(&json!({ "op": "delete-layout", "name": NAME }))
            .await?;
        if named(&http.get("/api/layout/layouts").await?) {
            return Err(format!("`{NAME}` survived delete-layout"));
        }

        Ok(format!(
            "saved, listed, applied (version={version}) and deleted `{NAME}`"
        ))
    })
    .await
}

/// 4. A selection published in the list pane reaches the info pane's channel.
///
/// The info pane declares an `item` parameter sourced from a channel
/// (`ParamSource::Channel`); the tree's `channels` map is where a published
/// selection lands. So the end-to-end assertion is: the detail pane's param
/// reads channel N, and after a `select` on the list pane, channel N carries
/// exactly the ids that were selected under the kind that was published. That
/// is the whole path the pane's `single_item` resolves through, observed at
/// the one point the tree actually exposes.
async fn channel_selection_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[4];
    check(id, description, Tier::B, || async {
        let tree = http.tree().await?;
        let detail = tile_with_role(&tree, "detail")?;
        let panes = panes(&tree)?;
        let detail_pane = panes
            .iter()
            .find(|(t, _)| *t == detail)
            .map(|(_, p)| *p)
            .ok_or_else(|| format!("tile {detail} is not a pane"))?;

        // Which channel does the detail pane's `item` parameter read?
        let params = detail_pane
            .get("params")
            .and_then(Value::as_array)
            .ok_or_else(|| "the detail pane declares no params".to_string())?;
        let (param_name, channel, kind) = params
            .iter()
            .find_map(|p| {
                let source = p.get("source")?;
                if source.get("source")?.as_str()? != "channel" {
                    return None;
                }
                let channel = source.get("channel")?.get("number")?.as_u64()?;
                let decl = p.get("decl")?;
                Some((
                    decl.get("name")?.as_str()?.to_string(),
                    channel,
                    decl.get("kind")?.as_str()?.to_string(),
                ))
            })
            .ok_or_else(|| {
                "the detail pane has no parameter sourced from a channel — this preset \
                 cannot carry a selection from a list to an info pane"
                    .to_string()
            })?;

        // Publish a selection from the list pane on that channel.
        let list = tile_with_role(&tree, "list")?;
        let selected = uuid::Uuid::new_v4().to_string();
        http.verb(&json!({
            "verb": "select",
            "target": { "ref": "id", "tile": list },
            "kind": kind,
            "ids": [selected]
        }))
        .await?;

        // …and read it back where the detail pane looks for it.
        let after = http.tree().await?;
        let carried = layout_of(&after)?
            .get("channels")
            .and_then(|c| c.get("channels").unwrap_or(c).get(channel.to_string()))
            .and_then(|k| k.get(&kind))
            .and_then(Value::as_array)
            .map(|ids| {
                ids.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        if carried != vec![selected.clone()] {
            return Err(format!(
                "selected {selected} on tile {list}, but channel {channel}'s `{kind}` \
                 carries {carried:?} — the detail pane's `{param_name}` would not follow"
            ));
        }

        Ok(format!(
            "tile {list} (list) published `{kind}` on channel {channel}; the detail pane \
             (tile {detail}) reads `{param_name}` from that channel, which now carries {selected}"
        ))
    })
    .await
}

/// 7. The outline sidebar (plan wave 6, W3).
///
/// Select a collection row → the list pane's query changes → the `info` pane
/// follows a list selection.
///
/// The row is driven the way the Swift outline drives it: the node goes
/// through `outline::outline_target` + `outline::outline_verbs` — the SAME
/// two functions `outline_row_verbs_json` hands the app when a person clicks
/// the row — and the verbs they return are posted one by one. So what is
/// proven is the decision (Rust) plus the app's application of it, over the
/// wire; the click itself is AppKit's and is proven by hand.
///
/// The collection is a fresh id, not a row in the store: a `Collection`
/// scope over an id with no members is a valid, empty query, and the tree
/// and the logs are the evidence, not the rows. So there is no throwaway
/// collection to create or clean up, and nothing is written to the store.
///
/// Evidence, all read back from the app: the tree's list pane carries
/// `scope: collection(<id>)`; channel 1 carries the collection
/// (`select` on the navigator); the list pane logged `pane <n> display:`
/// after the verb (it re-ran its query); after a `select` in the list, the
/// detail pane logged `pane <n> info: <kind> detail for <id>` (it followed).
async fn outline_collection_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[7];
    check(id, description, Tier::B, || async {
        let tree = http.tree().await?;
        let app = tree
            .get("app")
            .and_then(Value::as_str)
            .ok_or_else(|| "tree response names no `app`".to_string())?
            .to_string();
        let spec_of = |role: &str| -> Result<Option<(u64, impress_layout::PaneSpec)>, String> {
            let Ok(tile) = tile_with_role(&tree, role) else {
                return Ok(None);
            };
            let pane = panes(&tree)?
                .into_iter()
                .find(|(t, _)| *t == tile)
                .map(|(_, p)| p.clone())
                .ok_or_else(|| format!("tile {tile} is not a pane"))?;
            let spec: impress_layout::PaneSpec = serde_json::from_value(pane)
                .map_err(|e| format!("the `{role}` pane does not decode as a PaneSpec: {e}"))?;
            Ok(Some((tile, spec)))
        };
        let (list_tile, list_spec) =
            spec_of("list")?.ok_or_else(|| "no pane carries the `list` role".to_string())?;
        let detail = spec_of("detail")?;

        let collection = uuid::Uuid::new_v4();
        let node = crate::outline::OutlineNode::Collection { id: collection };
        let target = crate::outline::outline_target(&app, &node, &Default::default());
        let crate::outline::OutlineTarget::Query { query } = &target else {
            return Err(format!("a collection row must be a query, Rust said {target:?}"));
        };
        let verbs = crate::outline::outline_verbs(
            &node,
            &target,
            &crate::outline::OutlinePanes {
                list: Some(list_spec),
                detail: detail.as_ref().map(|(_, s)| s.clone()),
            },
        );
        if verbs.is_empty() {
            return Err("the outline produced no verbs for a new collection".into());
        }

        let before_verbs = log_cursor();
        for verb in &verbs {
            let body = serde_json::to_value(verb).map_err(|e| e.to_string())?;
            http.verb(&body).await?;
        }

        // 1. The list pane's query IS the collection now.
        let after = http.tree().await?;
        let list_query = panes(&after)?
            .into_iter()
            .find(|(t, _)| *t == list_tile)
            .and_then(|(_, p)| p.get("query").cloned())
            .ok_or_else(|| format!("tile {list_tile} lost its query"))?;
        let expected = serde_json::to_value(query).map_err(|e| e.to_string())?;
        if list_query != expected {
            return Err(format!(
                "the list pane's query is {list_query}, not the collection's {expected}"
            ));
        }
        // 2. The navigator published the collection on channel 1.
        let carried = channel_ids(&after, 1, "collection");
        if carried != vec![collection.to_string()] {
            return Err(format!(
                "channel 1 carries collection {carried:?}, not {collection}"
            ));
        }
        // 3. The list re-ran THE NEW query. The collection is fresh, so the
        // query matches nothing and the pane's own display line says 0 rows.
        // Any other count is the list re-running its OLD query on the
        // `select`'s refresh — seen on impel, where that line read "500 rows"
        // and would have passed as evidence had only the prefix been matched.
        let display = wait_for_log(
            http,
            &before_verbs,
            &[&format!("pane {list_tile} display: 0 rows")],
        )
        .await?;

        // 4. Select in the list; `info` follows.
        let Some((detail_tile, _)) = detail else {
            return Ok(format!(
                "list tile {list_tile} re-queried to collection {collection} ({display}); no detail pane in this layout, so `info` was not checked"
            ));
        };
        let kind = query.kinds.first().cloned().unwrap_or_else(|| "publication".into());
        let item = uuid::Uuid::new_v4();
        let before_select = log_cursor();
        http.verb(&json!({
            "verb": "select",
            "target": { "ref": "id", "tile": list_tile },
            "kind": kind,
            "ids": [item.to_string()]
        }))
        .await?;
        // The line must name THIS item: an earlier capability's selection
        // logged the same `pane N info:` prefix moments ago.
        let followed = wait_for_log(
            http,
            &before_select,
            &[&format!("pane {detail_tile} info: "), &item.to_string()],
        )
        .await?;

        Ok(format!(
            "{} verb(s) from the outline; list tile {list_tile} now queries collection {collection} and logged `{display}`; channel 1 carries it; a `{kind}` select in the list reached tile {detail_tile}: `{followed}`",
            verbs.len()
        ))
    })
    .await
}

/// The ids channel `n` carries for `kind`, read from a tree response.
fn channel_ids(tree: &Value, n: u64, kind: &str) -> Vec<String> {
    layout_of(tree)
        .ok()
        .and_then(|l| l.get("channels"))
        .and_then(|c| c.get("channels").unwrap_or(c).get(n.to_string()))
        .and_then(|k| k.get(kind))
        .and_then(Value::as_array)
        .map(|ids| {
            ids.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// Now, as the `after` cursor `/api/logs` takes. The app and this process
/// share a clock (it is a loopback call), so the slack is only the
/// millisecond truncation on either side — a whole second of it let the
/// previous capability's `pane N info:` line answer for this one.
fn log_cursor() -> String {
    (chrono::Utc::now() - chrono::Duration::milliseconds(5))
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

/// Poll `/api/logs?category=layout&after=<cursor>` for a message containing
/// every one of `needles` (case-insensitively — the Swift side logs
/// `UUID.uuidString`, upper case), for up to three seconds: a pane re-renders
/// on the next main run-loop turn after the verb returns, not inside it.
async fn wait_for_log(http: &Http, after: &str, needles: &[&str]) -> Result<String, String> {
    let wanted: Vec<String> = needles.iter().map(|n| n.to_lowercase()).collect();
    for _ in 0..30 {
        let logs = http
            .get(&format!(
                "/api/logs?category=layout&limit=500&after={after}"
            ))
            .await?;
        let found = logs
            .get("data")
            .and_then(|d| d.get("entries"))
            .and_then(Value::as_array)
            .and_then(|entries| {
                entries.iter().find_map(|e| {
                    let message = e.get("message")?.as_str()?;
                    let lower = message.to_lowercase();
                    wanted
                        .iter()
                        .all(|n| lower.contains(n.as_str()))
                        .then(|| message.to_string())
                })
            });
        if let Some(message) = found {
            return Ok(message);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(format!(
        "no `{}` in the layout log within 3 s",
        needles.join("` + `")
    ))
}

/// 5. Create a surface, render it, dispatch an event, see the state change.
///
/// The spec is written here rather than taken from `surface_examples` so the
/// widget ids are author-given and the capability does not depend on the demo
/// verbs (`surface-demo-service_*`) being linked into whichever app is
/// answering. The event is `impress_surface::Event`'s own shape.
async fn surface_capability(http: &Http, created: &mut Vec<String>) -> CapabilityResult {
    let (id, description) = CATALOGUE[5];

    let spec = json!({
        "surface": "1.0",
        "name": SCRATCH_SURFACE,
        "state": { "bins": 4 },
        "root": {
            "column": [
                { "text": "tier-b self-test" },
                {
                    "id": "bins",
                    "field": { "slider": { "min": 1, "max": 64, "step": 1 } },
                    "label": "Bins",
                    "bind": "state.bins"
                },
                {
                    "id": "choose",
                    "button": {
                        "label": "Use these bins",
                        "on_click": [
                            { "emit": { "name": "bins-chosen",
                                        "payload": { "bins": "{{state.bins}}" } } }
                        ]
                    }
                }
            ]
        }
    });

    // The surface id has to escape the closure so the restore step can delete
    // it even when a later assertion fails.
    let surface_id = match http.post("/api/surface", &spec).await {
        Ok(created_row) => created_row
            .get("id")
            .and_then(Value::as_str)
            .map(str::to_string),
        Err(reason) => {
            return check(id, description, Tier::B, || async move {
                Err(format!("creating the scratch surface failed: {reason}"))
            })
            .await
        }
    };
    let Some(surface_id) = surface_id else {
        return check(id, description, Tier::B, || async {
            Err("POST /api/surface returned no `id`".to_string())
        })
        .await;
    };
    created.push(surface_id.clone());

    check(id, description, Tier::B, || async {
        /// The value of the widget bound to `state.bins` in a render tree.
        fn bins_value(tree: &Value) -> Option<f64> {
            fn walk(node: &Value) -> Option<f64> {
                if node.get("id").and_then(Value::as_str) == Some("bins") {
                    return node.get("node")?.get("value")?.as_f64();
                }
                if let Some(items) = node
                    .get("node")
                    .and_then(|n| n.get("items"))
                    .and_then(Value::as_array)
                {
                    return items.iter().find_map(walk);
                }
                None
            }
            walk(tree.get("root")?)
        }

        let rendered = http
            .get(&format!("/api/surface/{surface_id}/render"))
            .await?;
        let before = bins_value(&rendered)
            .ok_or_else(|| "the render tree has no `bins` widget".to_string())?;

        // A `change` on the slider must move the bound state…
        let changed = http
            .post(
                &format!("/api/surface/{surface_id}/dispatch"),
                &json!({ "widget": "bins", "kind": "change", "value": 17 }),
            )
            .await?;
        if changed.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(format!(
                "dispatching `change` was refused: {}",
                changed
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("no message")
            ));
        }

        // …as seen by a fresh render, not just by the dispatch's own reply.
        let rerendered = http
            .get(&format!("/api/surface/{surface_id}/render"))
            .await?;
        let after = bins_value(&rerendered)
            .ok_or_else(|| "the re-render has no `bins` widget".to_string())?;
        if after != 17.0 {
            return Err(format!(
                "dispatched bins=17 but the re-render shows {after} (was {before})"
            ));
        }

        // A `click` must run the button's effect and emit a named event.
        let clicked = http
            .post(
                &format!("/api/surface/{surface_id}/dispatch"),
                &json!({ "widget": "choose", "kind": "click" }),
            )
            .await?;
        let emitted = clicked
            .get("effects")
            .and_then(Value::as_array)
            .map(|effects| {
                effects
                    .iter()
                    .any(|e| e.get("ok").and_then(Value::as_bool) == Some(true))
            })
            .unwrap_or(false);
        if !emitted {
            return Err(format!(
                "clicking `choose` ran no successful effect: {:?}",
                clicked.get("effects")
            ));
        }

        let events = http
            .get(&format!("/api/surface/{surface_id}/events?after=0"))
            .await?;
        let names: Vec<&str> = events
            .get("events")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter_map(|r| r.get("name").and_then(Value::as_str))
                    .collect()
            })
            .unwrap_or_default();
        if !names.contains(&"bins-chosen") {
            return Err(format!(
                "the click emitted no `bins-chosen` event; the feed carries {names:?}"
            ));
        }

        Ok(format!(
            "surface {surface_id} rendered (bins={before}), `change` moved it to {after}, \
             and `click` emitted bins-chosen"
        ))
    })
    .await
}

/// 6. ⌃⌘S-style: resize a pane to `HIDDEN_SHARE` and bring it back.
///
/// `resize-share` is the operation the chord routes through, and the store
/// clamps with `share.max(HIDDEN_SHARE)` — so asking for the constant is
/// asking for the floor. "Back" is checked as *above the hidden ceiling*
/// rather than as an exact number: un-collapsing restores the sibling
/// average, which is a value the tree computes, not one the caller names.
async fn hidden_share_capability(http: &Http) -> CapabilityResult {
    let (id, description) = CATALOGUE[6];
    check(id, description, Tier::B, || async {
        let tree = http.tree().await?;
        let navigator = tile_with_role(&tree, "navigator")?;
        let original = share_of(&tree, navigator)?;

        http.op(&json!({
            "op": "resize-share",
            "pane": navigator,
            "share": impress_layout::HIDDEN_SHARE
        }))
        .await?;
        let hidden = share_of(&http.tree().await?, navigator)?;
        if hidden > f64::from(impress_layout::HIDDEN_SHARE_CEILING) {
            return Err(format!(
                "resize-share to HIDDEN_SHARE left the pane at {hidden}, above the \
                 {} ceiling — it would still be visible",
                impress_layout::HIDDEN_SHARE_CEILING
            ));
        }

        // Bring it back to the share it had. A person's ⌃⌘S computes the
        // sibling average; a caller that knows the previous value can simply
        // restore it, which is both the exact restoration and a visible pane.
        http.op(&json!({
            "op": "resize-share",
            "pane": navigator,
            "share": original
        }))
        .await?;
        let restored = share_of(&http.tree().await?, navigator)?;
        if restored <= f64::from(impress_layout::HIDDEN_SHARE_CEILING) {
            return Err(format!(
                "the pane stayed hidden at {restored} after being resized back"
            ));
        }

        Ok(format!(
            "tile {navigator}: {original} → {hidden} (≤ {}) → {restored}",
            impress_layout::HIDDEN_SHARE_CEILING
        ))
    })
    .await
}

/// The `finally`: put the tree back and delete everything this run created.
///
/// Reported as its own capability so a failed cleanup is a failed self-test.
/// A catalogue that quietly left a scratch layout behind would be a worse
/// neighbour than one that says it could not tidy up.
async fn restore_capability(
    http: &Http,
    parked: bool,
    created_surfaces: &[String],
) -> CapabilityResult {
    check(
        "layout.restored",
        "The live arrangement and surfaces are left as they were found",
        Tier::B,
        || async {
            let mut notes: Vec<String> = Vec::new();
            let mut problems: Vec<String> = Vec::new();

            for id in created_surfaces {
                match http.delete(&format!("/api/surface/{id}")).await {
                    Ok(_) => notes.push(format!("deleted surface {id}")),
                    Err(e) => problems.push(format!("surface {id} not deleted: {e}")),
                }
            }

            if parked {
                // Applied by NAME: the `apply-layout` ordinal space is the
                // union of presets and named layouts, so an ordinal read from
                // /api/layout/layouts would address the wrong thing.
                match http
                    .op(&json!({ "op": "apply-layout", "name": RESTORE_LAYOUT }))
                    .await
                {
                    Ok(_) => notes.push("re-applied the arrangement that was live".into()),
                    Err(e) => problems.push(format!("could not re-apply `{RESTORE_LAYOUT}`: {e}")),
                }
                match http
                    .op(&json!({ "op": "delete-layout", "name": RESTORE_LAYOUT }))
                    .await
                {
                    Ok(_) => notes.push("deleted the restore point".into()),
                    Err(e) => problems.push(format!("could not delete `{RESTORE_LAYOUT}`: {e}")),
                }
            } else {
                notes.push(
                    "nothing to restore: the arrangement could not be parked before the run".into(),
                );
            }

            if problems.is_empty() {
                Ok(notes.join("; "))
            } else {
                Err(problems.join("; "))
            }
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The skip path is the one a headless box takes, so it is the one that
    /// must be tested without an app: an unreachable port skips every
    /// capability, fails none, and the report still passes.
    #[tokio::test]
    async fn an_unreachable_app_skips_the_whole_tier() {
        // Port 1 is reserved and nothing in the suite listens there.
        let results = run("http://127.0.0.1:1").await;
        assert_eq!(results.len(), CATALOGUE.len());
        assert!(
            results.iter().all(|r| r.skipped),
            "every capability must skip: {:?}",
            results
                .iter()
                .filter(|r| !r.skipped)
                .map(|r| r.id.as_str())
                .collect::<Vec<_>>()
        );
        let report = crate::SelfTestReport::from_results(results);
        assert!(
            report.ok(),
            "a skipped tier must not fail: {}",
            report.summary()
        );
        assert_eq!(report.failed, 0);
        assert_eq!(report.passed, 0);
    }

    /// The skip branch names the reachability capability specifically, so the
    /// reason a run was headless is in the report rather than in a log.
    #[tokio::test]
    async fn the_skip_reason_names_the_unreachable_port() {
        let results = run("http://127.0.0.1:1").await;
        let reachable = results
            .iter()
            .find(|r| r.id == "app.reachable")
            .expect("app.reachable is always reported");
        assert!(
            reachable.detail.contains("127.0.0.1:1"),
            "the skip must say where it looked: {}",
            reachable.detail
        );
    }

    /// Every capability id is distinct and every entry carries a description —
    /// the report is keyed by id, and a duplicate would silently shadow.
    #[test]
    fn the_catalogue_ids_are_unique_and_described() {
        let mut ids: Vec<&str> = CATALOGUE.iter().map(|(id, _)| *id).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "duplicate capability id in CATALOGUE");
        assert!(CATALOGUE.iter().all(|(_, d)| !d.is_empty()));
    }

    /// `share_of` reads a pane's share through its parent's parallel array —
    /// the shape `impress_layout::Container::Linear` actually serialises.
    #[test]
    fn share_of_reads_the_parallel_shares_array() {
        let tree = json!({
            "layout": {
                "tiles": {
                    "1": { "pane": { "role": "navigator" } },
                    "2": { "pane": { "role": "list" } },
                    "3": { "container": { "linear": {
                        "dir": "horizontal",
                        "children": [1, 2],
                        "shares": [0.0001, 3.0]
                    } } }
                }
            }
        });
        assert_eq!(share_of(&tree, 1).unwrap(), 0.0001);
        assert_eq!(share_of(&tree, 2).unwrap(), 3.0);
        assert_eq!(tile_with_role(&tree, "list").unwrap(), 2);
        assert!(share_of(&tree, 99).is_err());
    }
}

#[cfg(test)]
mod base_url_tests {
    use super::*;

    #[test]
    fn unset_or_blank_is_impress() {
        assert_eq!(base_url_from(None), IMPRESS_BASE_URL);
        assert_eq!(base_url_from(Some(String::new())), IMPRESS_BASE_URL);
        assert_eq!(base_url_from(Some("   ".into())), IMPRESS_BASE_URL);
    }

    /// implore, impart and impel, at the ports `SiblingApp` assigns them.
    #[test]
    fn a_sibling_port_is_honoured() {
        for port in ["23123", "23122", "23124"] {
            let url = format!("http://127.0.0.1:{port}");
            assert_eq!(base_url_from(Some(url.clone())), url);
            assert_eq!(base_url_from(Some(format!("{url}\n"))), url);
        }
    }
}
