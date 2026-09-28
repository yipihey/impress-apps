//! The Person-only trust verb's successful store effects, separate from its
//! documented non-Person refusal example. No host, network or global registry.
use std::sync::Arc;

use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::descriptor::SafetyClass;
use impress_service_core::pipeline::{context, CallerIdentity};
use impress_service_core::provider::{RegistrationRequest, Registry, SchemaValidator};
use impress_store_service::provider_service::{DefaultProviderService, ProviderService};
use impress_store_service::providers::build_registry;
use serde_json::{json, Value};

// Deliberately accepts only this test's empty-object schema and payload. Full
// JSON Schema validation is exercised by the host transport's tests/Tier B.
struct FixtureValidator;
impl SchemaValidator for FixtureValidator {
    fn validate(&self, schema: &Value) -> Result<(), String> {
        if *schema == json!({"type":"object","properties":{},"additionalProperties":false}) {
            Ok(())
        } else {
            Err("unexpected fixture schema".into())
        }
    }
    fn validate_instance(&self, schema: &Value, value: &Value) -> Result<(), String> {
        self.validate(schema)?;
        if *value == json!({}) {
            Ok(())
        } else {
            Err("unexpected fixture value".into())
        }
    }
}

pub async fn verify() -> bool {
    let result = check().await;
    if let Err(error) = &result {
        eprintln!("provider trust capability: {error}");
    }
    result.is_ok()
}

async fn check() -> Result<(), Box<dyn std::error::Error>> {
    let workspace =
        std::env::temp_dir().join(format!("impress-provider-effects-{}", std::process::id()));
    std::fs::create_dir_all(&workspace)?;
    let store = Arc::new(SqliteItemStore::open_in_memory()?);
    let registry = Arc::new(build_registry(
        store.clone(),
        &workspace,
        Arc::new(FixtureValidator),
    )?);
    let schema = json!({"type":"object","properties":{},"additionalProperties":false});
    let request: RegistrationRequest = serde_json::from_value(json!({
        "provider":{"id":"effects-fixture","language":"test","version":"1.0.0",
            "endpoint":"http://127.0.0.1:1"},
        "verbs":[{"name":"effects-fixture-service_empty","description":"Empty fixture",
            "input_schema":schema,"output_schema":schema,"safety":{"class":"read_only"},
            "since":"1.0.0","examples":[{"name":"empty","args":{},"expect":{}}]}]
    }))?;
    registry.register(request)?;
    let service = DefaultProviderService::with_registry(registry);
    let call = Arc::new(context::CallContext {
        call_id: "provider-effects-trust".into(),
        trace_id: "provider-effects".into(),
        parent_call: None,
        caller: CallerIdentity::Person,
        verb: "provider-service_set-trusted".into(),
        store_override: None,
        mutation_ids: context::MutationIds::default(),
    });
    for (trusted, expected) in [
        (true, SafetyClass::ReadOnly),
        (false, SafetyClass::External),
    ] {
        let reply = context::scope(
            call.clone(),
            service.set_trusted("effects-fixture".into(), trusted),
        )
        .await;
        if !reply.ok || reply.trusted != Some(trusted) {
            return Err(reply.message.into());
        }
        // Reload through a different registry to prove the durable decision,
        // rather than reading only the writer's in-memory state back.
        let restored: Registry =
            build_registry(store.clone(), &workspace, Arc::new(FixtureValidator))?;
        if restored.summaries()[0].trusted != trusted
            || restored
                .find("effects-fixture-service_empty")
                .ok_or("missing restored verb")?
                .safety()
                .class
                != expected
        {
            return Err("trust decision did not survive a registry reload".into());
        }
    }
    Ok(())
}
