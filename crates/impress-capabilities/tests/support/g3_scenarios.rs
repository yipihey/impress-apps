//! Independent scenario examples; each case owns its stored no-op document.
use impress_core::{item::ActorKind, sqlite_store::SqliteItemStore, store::ItemStore};
use impress_scenario_service::{dto::SpecArg, ScenarioStore};
use serde_json::{json, Value};
use std::{path::Path, sync::Arc};

pub async fn prepare(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _root: &Path,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-scenario-service_") else {
        return Ok(());
    };
    if !matches!(
        method,
        "scenario-create" | "scenario-get" | "scenario-list" | "scenario-run"
    ) {
        return Ok(());
    }
    let scenarios = ScenarioStore::new(store.clone());
    for row in scenarios.list().map_err(|e| e.to_string())? {
        if row.spec.id == "example.noop" {
            store.delete(row.id).map_err(|e| e.to_string())?;
        }
    }
    if method != "scenario-create" {
        let spec = SpecArg(json!({"wire_version":1,"id":"example.noop","description":"a scenario with one no-op step","tier":"a","steps":[{"call":"impress-scenario-service_scenario-list","args":{},"as":"agent:scenario"}]})).parse()?;
        scenarios
            .create(&spec, &[], ActorKind::System)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    _example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    let Some(method) = verb.strip_prefix("impress-scenario-service_") else {
        return Ok(());
    };
    if result["ok"] != true {
        return Err(format!("scenario refused: {result}"));
    }
    match method {
        "scenario-create" | "scenario-get" => {
            let row = ScenarioStore::new(store.clone())
                .get_by_scenario_id("example.noop")
                .map_err(|e| e.to_string())?
                .ok_or("no persisted example scenario")?;
            if result["id"] != row.id.to_string()
                || result["scenario_id"] != row.spec.id
                || result["spec"]["steps"].as_array().map(Vec::len) != Some(1)
            {
                return Err(format!(
                    "scenario document differs from persisted row: {result}"
                ));
            }
        }
        "scenario-list" => {
            if !result["scenarios"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|row| row["scenario_id"] == "example.noop"))
            {
                return Err("seeded scenario missing from list".into());
            }
        }
        "scenario-run"
            if result["passed"] != 1 || result["failed"] != 0 || result["skipped"] != 0 =>
        {
            return Err(format!("no-op scenario did not run: {result}"));
        }
        _ => {}
    }
    Ok(())
}
