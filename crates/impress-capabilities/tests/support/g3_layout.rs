//! Per-example layout fixtures over the harness's private store.
//!
//! Each example uses its own `g3-layout` device, and named records use
//! distinct G3 names. Preparation happens before the effects spy opens;
//! verification reads the persisted tree after it closes.

use std::path::Path;
use std::sync::Arc;

use impress_core::sqlite_store::SqliteItemStore;
use impress_layout_service::service::{DefaultLayoutService, LayoutService};
use impress_layout_service::store::LayoutStore;
use impress_layout_service::{PaneRefDto, PresetStore};
use serde_json::Value;

const APP: &str = "g3-layout";
const SELECTED: &str = "5a000000-0000-4000-8000-000000000002";
const PINNED: &str = "5a000000-0000-4000-8000-000000000001";
const SECOND_SELECTED: &str = "5a000000-0000-4000-8000-000000000003";

fn device(method: &str) -> String {
    // Descriptor names use hyphens; only the Rust method match uses `_`.
    // Preparation, invocation and persisted readback must address one scope.
    format!("g3-{}", method.replace('_', "-"))
}
fn role(name: &str) -> PaneRefDto {
    PaneRefDto::role(name)
}
fn success(ok: bool, message: String, step: &str) -> Result<(), String> {
    if ok {
        Ok(())
    } else {
        Err(format!("layout fixture {step}: {message}"))
    }
}

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    if !verb.starts_with("layout-service_") || !example.starts_with("g3-") {
        return Ok(());
    }
    let method = verb
        .strip_prefix("layout-service_")
        .unwrap()
        .replace('-', "_");
    let service = DefaultLayoutService::new(); // Same installed store/session as dispatch.
    if method == "reset_preset" {
        // A reset requires a *shipped* preset. g3-layout has no shipped
        // table entry, so this one example edits imbib/Triage in scratch.
        let reset_device = device(&method);
        let initial = service
            .get_layout("imbib".into(), Some(reset_device.clone()))
            .await;
        success(initial.ok, initial.message, "reset cold start")?;
        let applied = service
            .apply_preset(
                "imbib".into(),
                Some(reset_device.clone()),
                "Triage".into(),
                None,
                None,
            )
            .await;
        success(applied.ok, applied.message, "apply shipped Triage")?;
        let changed = service
            .close(
                "imbib".into(),
                Some(reset_device.clone()),
                role("navigator"),
                None,
                None,
            )
            .await;
        success(changed.ok, changed.message, "edit Triage tree")?;
        let edited = service
            .save_preset(
                "imbib".into(),
                Some(reset_device),
                "Triage".into(),
                None,
                true,
                None,
            )
            .await;
        success(edited.ok, edited.message, "save edited Triage")?;
        let presets = PresetStore::new(store.clone());
        let (row, stored) = presets
            .load("imbib", "Triage")
            .map_err(|e| e.to_string())?
            .ok_or("edited Triage preset vanished")?;
        if presets.matches_shipped(&row, &stored) != Some(false) {
            return Err("fixture did not make Triage differ from its shipped tree".into());
        }
        return Ok(());
    }
    let seed_device = device(&method);
    let initial = service
        .get_layout(APP.into(), Some(seed_device.clone()))
        .await;
    success(initial.ok, initial.message, "cold start")?;
    if matches!(method.as_str(), "resize" | "set_container_kind")
        && initial
            .layout
            .as_ref()
            .and_then(|layout| layout.windows.first())
            .map(|window| window.root.raw())
            != Some(4)
    {
        return Err("three-column fixture root changed; update the example's container id".into());
    }
    match method.as_str() {
        "apply_layout" | "delete_layout" | "list_layouts" => {
            let name = match method.as_str() {
                "apply_layout" => "G3 Apply",
                "delete_layout" => "G3 Delete",
                _ => "G3 Listed",
            };
            let saved = service
                .save_layout(
                    APP.into(),
                    Some(seed_device.clone()),
                    name.into(),
                    None,
                    None,
                )
                .await;
            success(saved.ok, saved.message, "save layout")?;
            if method == "apply_layout" {
                let changed = service
                    .close(APP.into(), Some(seed_device), role("navigator"), None, None)
                    .await;
                success(changed.ok, changed.message, "change before recall")?;
            }
        }
        "apply_preset" | "list_presets" => {
            let name = if method == "apply_preset" {
                "G3 Apply Preset"
            } else {
                "G3 Listed Preset"
            };
            let saved = service
                .save_preset(
                    APP.into(),
                    Some(seed_device.clone()),
                    name.into(),
                    None,
                    true,
                    None,
                )
                .await;
            success(saved.ok, saved.message, "save preset")?;
            if method == "apply_preset" {
                let changed = service
                    .close(APP.into(), Some(seed_device), role("navigator"), None, None)
                    .await;
                success(changed.ok, changed.message, "change before preset")?;
            }
        }
        "focus_direction" => {
            let focused = service
                .focus(APP.into(), Some(seed_device), role("navigator"), None, None)
                .await;
            success(focused.ok, focused.message, "initial focus")?;
        }
        "get_channel" => {
            let selected = service
                .select(
                    APP.into(),
                    Some(seed_device),
                    role("list"),
                    "publication".into(),
                    vec![SELECTED.into()],
                    None,
                    None,
                )
                .await;
            success(selected.ok, selected.message, "select for channel")?;
        }
        "restore" => {
            let zoomed = service
                .maximize(APP.into(), Some(seed_device), role("detail"), None, None)
                .await;
            success(zoomed.ok, zoomed.message, "maximize before restore")?;
        }
        "redo" => {
            let split = service
                .split(
                    APP.into(),
                    Some(seed_device.clone()),
                    role("list"),
                    "horizontal".into(),
                    true,
                    None,
                    None,
                    None,
                )
                .await;
            success(split.ok, split.message, "split before redo")?;
            let undone = service
                .undo(
                    APP.into(),
                    Some(seed_device),
                    "arrangement".into(),
                    None,
                    None,
                    None,
                )
                .await;
            success(undone.ok, undone.message, "undo before redo")?;
        }
        "undo" => {
            let split = service
                .split(
                    APP.into(),
                    Some(seed_device),
                    role("list"),
                    "horizontal".into(),
                    true,
                    None,
                    None,
                    None,
                )
                .await;
            success(split.ok, split.message, "split before undo")?;
        }
        _ => {}
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    if !verb.starts_with("layout-service_") || !example.starts_with("g3-") {
        return Ok(());
    }
    if result["ok"] != true {
        return Err(format!("{verb} did not succeed: {result}"));
    }
    let method = verb
        .strip_prefix("layout-service_")
        .unwrap()
        .replace('-', "_");
    if method == "reset_preset" {
        let presets = PresetStore::new(store.clone());
        let (row, stored) = presets
            .load("imbib", "Triage")
            .map_err(|e| e.to_string())?
            .ok_or("reset removed the shipped Triage preset")?;
        if presets.matches_shipped(&row, &stored) != Some(true) {
            return Err("reset did not restore the shipped Triage revision".into());
        }
        return Ok(());
    }
    let device = device(&method);
    let layout_store = LayoutStore::new(store.clone());
    let live = layout_store
        .live_row(APP, &device)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("{verb} has no persisted live layout"))?
        .1;
    let roles = || {
        live.windows
            .first()
            .map(|w| {
                live.leaves(w.id)
                    .iter()
                    .filter_map(|tile| {
                        live.pane(*tile)
                            .and_then(|pane| pane.role.as_ref())
                            .map(ToString::to_string)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    let tree = serde_json::to_value(&live).map_err(|e| e.to_string())?;
    match method.as_str() {
        "apply_layout" | "apply_preset" => {
            if roles() != ["navigator", "list", "detail"] {
                return Err(format!("{verb} did not restore three panes: {:?}", roles()));
            }
        }
        "close" if live.panes().len() != 2 => return Err("close did not persist two panes".into()),
        "detach" if live.windows.len() != 2 => {
            return Err("detach did not persist a second window".into())
        }
        "focus" | "focus_direction" if result["focused"].as_u64().is_none() => {
            return Err("focus returned no pane".into())
        }
        "get_channel" if result["selections"]["publication"] != serde_json::json!([SELECTED]) => {
            return Err(format!("channel omitted selection: {result}"))
        }
        "get_layout" if result["layout"].is_null() => {
            return Err("get_layout returned no tree".into())
        }
        "get_pane" if result["spec"].is_null() || result["query"].is_null() => {
            return Err("get_pane omitted spec/query".into())
        }
        "maximize" if live.windows.first().and_then(|w| w.maximized).is_none() => {
            return Err("maximize not persisted".into())
        }
        "move_tile" if roles() != ["list", "detail", "navigator"] => {
            return Err(format!("move did not reorder panes: {:?}", roles()))
        }
        "redo" if live.panes().len() != 4 => return Err("redo did not restore split pane".into()),
        "resize"
            if tree["tiles"]["4"]["container"]["linear"]["shares"]
                != serde_json::json!([3.0, 2.0, 1.0]) =>
        {
            return Err("resize did not persist 3:2:1 shares".into());
        }
        "resolve_reference" if result["role"] != "detail" || result["tile"] != 3 => {
            return Err(format!(
                "detail reference did not resolve to tile 3: {result}"
            ));
        }
        "restore"
            if live
                .windows
                .first()
                .and_then(|window| window.maximized)
                .is_some() =>
        {
            return Err("restore left the zoomed pane set".into());
        }
        "save_layout" => {
            let named = layout_store.list_named(APP).map_err(|e| e.to_string())?;
            if !named.iter().any(|row| {
                row.name.as_deref() == Some("G3 Saved")
                    && row.purpose.as_deref() == Some("G3 saved arrangement")
            }) {
                return Err("save_layout omitted the owned name/purpose".into());
            }
        }
        "save_preset" => {
            let presets = PresetStore::new(store.clone());
            let (_, saved) = presets
                .load(APP, "G3 Saved Preset")
                .map_err(|e| e.to_string())?
                .ok_or("save_preset did not persist the owned preset")?;
            if saved
                .layout
                .as_ref()
                .is_none_or(|layout| layout.panes().len() != 3)
            {
                return Err("saved preset has no three-pane tree".into());
            }
        }
        "select"
            if live
                .channels
                .current(1, "publication")
                .map(|id| id.to_string())
                .as_deref()
                != Some(SECOND_SELECTED) =>
        {
            return Err("select did not publish the paper on channel 1".into());
        }
        "set_channel" if tree["tiles"]["2"]["pane"]["channel"]["number"] != 2 => {
            return Err("list pane did not move to channel 2".into());
        }
        "set_collapsed"
            if tree["tiles"]["3"]["pane"]["collapsed_share"]
                .as_f64()
                .is_none() =>
        {
            return Err("detail pane did not retain its collapsed share".into());
        }
        "set_container_kind" if tree["tiles"]["4"]["container"]["tabs"].is_null() => {
            return Err("root was not retyped to tabs".into());
        }
        "set_default_channel" if tree["windows"][0]["default_channel"]["number"] != 4 => {
            return Err("window follow channel was not set to 4".into());
        }
        "set_pane"
            if tree["tiles"]["2"]["pane"]["view_kind"] != "plot"
                || tree["tiles"]["2"]["pane"]["role"] != "preview"
                || tree["tiles"]["2"]["pane"]["query"]["kinds"]
                    != serde_json::json!(["figure"]) =>
        {
            return Err("replacement pane spec was not persisted".into());
        }
        "set_query"
            if tree["tiles"]["2"]["pane"]["query"]["kinds"]
                != serde_json::json!(["manuscript"])
                || tree["tiles"]["2"]["pane"]["query"]["text"] != "dark matter" =>
        {
            return Err("list pane query did not change".into());
        }
        "set_role" if tree["tiles"]["1"]["pane"]["role"] != "console" => {
            return Err("navigator pane did not take console role".into());
        }
        "set_view_kind" if tree["tiles"]["3"]["pane"]["view_kind"] != "pdf" => {
            return Err("detail pane did not switch to PDF".into());
        }
        "set_window_geometry" if tree["windows"][0]["geometry"]["w"] != 1440.0 => {
            return Err("window frame width was not persisted".into());
        }
        "split" if live.panes().len() != 4 => {
            return Err("split did not persist a fourth pane".into())
        }
        "swap" if roles() != ["navigator", "detail", "list"] => {
            return Err(format!("swap did not exchange pane order: {:?}", roles()));
        }
        "undo" if live.panes().len() != 3 => {
            return Err("undo did not remove the fixture split".into())
        }
        "bind_param" => {
            let binding = live
                .panes()
                .iter()
                .filter_map(|id| live.pane(*id))
                .find(|pane| {
                    pane.role
                        .as_ref()
                        .is_some_and(|role| role.to_string() == "detail")
                })
                .and_then(|pane| {
                    pane.params
                        .iter()
                        .find(|binding| binding.decl.name == "item")
                })
                .ok_or("bind_param did not persist the detail item binding")?;
            let source = serde_json::to_value(&binding.source).map_err(|e| e.to_string())?;
            if source["source"] != "fixed" || source["item"] != PINNED {
                return Err(format!("bind_param persisted the wrong source: {source}"));
            }
        }
        "commit" | "delete_layout" | "list_layouts" => {
            let named = layout_store.list_named(APP).map_err(|e| e.to_string())?;
            let name = match method.as_str() {
                "commit" => "G3 Commit",
                "delete_layout" => "G3 Delete",
                _ => "G3 Listed",
            };
            let present = named.iter().any(|row| row.name.as_deref() == Some(name));
            if present == (method == "delete_layout") {
                return Err(format!("{verb} saved-row readback unexpected for {name}"));
            }
            if method == "list_layouts"
                && !result["layouts"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|row| row["name"] == name))
            {
                return Err("list_layouts omitted its owned named layout".into());
            }
        }
        "list_presets"
            if !result["presets"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["name"] == "G3 Listed Preset")) =>
        {
            return Err("list_presets omitted its owned preset".into())
        }
        _ => {}
    }
    if args["app_id"] != APP {
        return Err(format!("{verb} escaped owned app scope"));
    }
    Ok(())
}
