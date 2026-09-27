//! `ImpressScenarioService` — `validate`, `run`, `list`, `get`, `create`
//! (docs/plan-self-reflective-layer.md S1, § Scenarios).
//!
//! Modelled on `impress-surface-service/src/service.rs`: every argument is
//! strict, every result carries `wire_version`, a spec is validated
//! wherever it is stored.

use std::sync::Arc;

use impress_core::item::ActorKind;
use impress_core::sqlite_store::SqliteItemStore;
use impress_service_core::wire::WIRE_VERSION;
use impress_service_core::{Refusal, VerbDescriptor};
use impress_service_macros::{impress_service, impress_service_impl};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::dto::{
    ScenarioListResult, ScenarioResult, ScenarioRunResult, ScenarioSummaryDto,
    ScenarioValidateResult, SpecArg,
};
use crate::store::ScenarioStore;
use crate::tier_a::TierACaller;
use crate::tier_b::TierBCaller;

/// Every scenario verb an agent needs (S1's row): validate a spec, store
/// one, list/get what is stored, and run it — Tier A on a scratch store,
/// Tier B against a running app.
#[impress_service]
pub trait ImpressScenarioService: Send + Sync + 'static {
    /// Every structural problem with a scenario spec (`impress-scenario::validate`).
    /// `ok` is false when any problem was found; this crate cannot check
    /// that a `call` step names a real verb without the inventory, so it
    /// adds that check on top of `impress-scenario`'s own structural pass.
    #[impress_method]
    #[impress_example(
        name = "default",
        args = r#"{"spec": {"wire_version": 1, "id": "example.noop", "description": "a scenario with one no-op step", "tier": "a", "steps": [{"call": "impress-scenario-service_scenario-list", "args": {}, "as": "agent:scenario"}]}}"#
    )]
    async fn scenario_validate(&self, spec: SpecArg) -> ScenarioValidateResult;

    /// Store a spec as a new `impress/scenario@1.0.0` row, after validating
    /// it exactly as `scenario_validate` does. Refused `invalid-spec` with
    /// every problem when any is found; nothing is stored.
    #[impress_method(safety = mutating, effects(reads = ["impress/scenario@1.0.0"], writes = ["impress/scenario@1.0.0"]))]
    #[impress_example(
        name = "default",
        args = r#"{"spec": {"wire_version": 1, "id": "example.noop", "description": "a scenario with one no-op step", "tier": "a", "steps": [{"call": "impress-scenario-service_scenario-list", "args": {}, "as": "agent:scenario"}]}}"#
    )]
    async fn scenario_create(&self, spec: SpecArg, tags: Option<Vec<String>>) -> ScenarioResult;

    /// One stored scenario, by its row id OR its stable `scenario_id`
    /// (`layout.saved_round_trip`) — whichever `id` names.
    #[impress_method(effects(reads = ["impress/scenario@1.0.0"]))]
    #[impress_example(name = "default", args = r#"{"id": "example.noop"}"#)]
    async fn scenario_get(&self, id: String) -> ScenarioResult;

    /// Every stored scenario, oldest first, without their specs (see
    /// `scenario_get` for the full document).
    #[impress_method(effects(reads = ["impress/scenario@1.0.0"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    async fn scenario_list(&self) -> ScenarioListResult;

    /// Run one stored scenario by its `scenario_id`, Tier A on a fresh
    /// scratch store or Tier B against `base_url` (default: this device's
    /// own app, resolved the way the layout Tier B catalogue does).
    /// `external`: a Tier B run leaves the process over loopback HTTP, and
    /// a scenario's steps may call any verb, including a mutating or
    /// destructive one — the same reasoning that makes `workflow-service_run`
    /// (and every other "run arbitrary steps" verb) an external safety class
    /// rather than trying to infer a tighter one from what happens to run.
    #[impress_method(safety = external, effects(reads = ["impress/scenario@1.0.0"], writes = [any("a scenario's steps may call any verb, including a mutating one")], reach = [network]))]
    async fn scenario_run(
        &self,
        scenario_id: String,
        tier: Option<String>,
        base_url: Option<String>,
    ) -> ScenarioRunResult;
}

#[derive(Clone, Default)]
pub struct DefaultImpressScenarioService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultImpressScenarioService {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store_arc(&self) -> Arc<SqliteItemStore> {
        self.store
            .clone()
            .unwrap_or_else(impress_store_service::store_instance)
    }

    fn scenarios(&self) -> ScenarioStore {
        ScenarioStore::new(self.store_arc())
    }

    /// Everything `impress-scenario::validate` finds, plus — when the
    /// inventory this process links has it — every `call` step naming a
    /// verb that does not exist.
    fn problems_of(
        &self,
        raw: &serde_json::Value,
    ) -> (
        Option<impress_scenario::Scenario>,
        Vec<impress_scenario::Problem>,
    ) {
        let parsed: Result<impress_scenario::Scenario, _> = serde_json::from_value(raw.clone());
        let Ok(scenario) = parsed else {
            return (
                None,
                vec![impress_scenario::Problem {
                    step: None,
                    message: format!(
                        "not a well-formed scenario: {}",
                        parsed.err().map(|e| e.to_string()).unwrap_or_default()
                    ),
                }],
            );
        };
        let mut problems = impress_scenario::validate(&scenario);
        for (index, step) in scenario.steps.iter().enumerate() {
            if let impress_scenario::Step::Call(call) = step {
                if VerbDescriptor::find(&call.call).is_none() {
                    problems.push(impress_scenario::Problem {
                        step: Some(index),
                        message: format!("no such verb: {}", call.call),
                    });
                }
            }
        }
        (Some(scenario), problems)
    }
}

#[async_trait::async_trait]
impl ImpressScenarioService for DefaultImpressScenarioService {
    async fn scenario_validate(&self, spec: SpecArg) -> ScenarioValidateResult {
        ScenarioValidateResult::of(self.problems_of(&spec.0).1)
    }

    async fn scenario_create(&self, spec: SpecArg, tags: Option<Vec<String>>) -> ScenarioResult {
        let (parsed, problems) = self.problems_of(&spec.0);
        let Some(parsed) = parsed.filter(|_| problems.is_empty()) else {
            return ScenarioResult {
                ok: false,
                ..ScenarioResult::refused(Refusal::invalid_argument(format!(
                    "invalid scenario: {}",
                    problems
                        .into_iter()
                        .map(|p| p.message)
                        .collect::<Vec<_>>()
                        .join("; ")
                )))
            };
        };
        let tags = tags.unwrap_or_default();
        match self.scenarios().create(&parsed, &tags, ActorKind::Agent) {
            Ok(row) => ScenarioResult::from_row(&row),
            Err(e) => ScenarioResult::refused(e),
        }
    }

    async fn scenario_get(&self, id: String) -> ScenarioResult {
        let scenarios = self.scenarios();
        let found = if let Ok(item_id) = id.parse() {
            scenarios.get(item_id).ok().flatten()
        } else {
            None
        };
        let found = found.or_else(|| scenarios.get_by_scenario_id(&id).ok().flatten());
        match found {
            Some(row) => ScenarioResult::from_row(&row),
            None => ScenarioResult::refused(Refusal::not_found(format!("no scenario `{id}`"))),
        }
    }

    async fn scenario_list(&self) -> ScenarioListResult {
        match self.scenarios().list() {
            Ok(rows) => ScenarioListResult {
                wire_version: WIRE_VERSION,
                ok: true,
                scenarios: rows
                    .iter()
                    .map(|r| ScenarioSummaryDto {
                        id: r.id.to_string(),
                        scenario_id: r.spec.id.clone(),
                        description: r.spec.description.clone(),
                        tier: match r.spec.tier {
                            impress_scenario::Tier::A => "a".to_string(),
                            impress_scenario::Tier::B => "b".to_string(),
                        },
                        tags: r.tags.clone(),
                    })
                    .collect(),
                refusal: Default::default(),
            },
            Err(e) => ScenarioListResult {
                wire_version: WIRE_VERSION,
                ok: false,
                scenarios: Vec::new(),
                refusal: e.into(),
            },
        }
    }

    async fn scenario_run(
        &self,
        scenario_id: String,
        tier: Option<String>,
        base_url: Option<String>,
    ) -> ScenarioRunResult {
        let row = match self.scenarios().get_by_scenario_id(&scenario_id) {
            Ok(Some(row)) => row,
            Ok(None) => {
                return ScenarioRunResult::refused(Refusal::not_found(format!(
                    "no scenario `{scenario_id}`"
                )))
            }
            Err(e) => return ScenarioRunResult::refused(e),
        };
        let requested_tier = tier.as_deref().unwrap_or(match row.spec.tier {
            impress_scenario::Tier::A => "a",
            impress_scenario::Tier::B => "b",
        });
        let result = if requested_tier == "b" {
            let base = base_url.unwrap_or_else(|| "http://127.0.0.1:23125".to_string());
            let mut caller = TierBCaller::new(&base);
            impress_scenario::run(&row.spec, &mut caller).await
        } else {
            match TierACaller::open() {
                Ok(mut caller) => impress_scenario::run(&row.spec, &mut caller).await,
                Err(e) => {
                    return ScenarioRunResult::refused(Refusal::internal(e));
                }
            }
        };
        let report = impress_service_core::report::SelfTestReport::from_results(vec![result]);
        report.into()
    }
}

fn impress_scenario_service_instance() -> Arc<dyn ImpressScenarioService> {
    Arc::new(DefaultImpressScenarioService::new())
}

impress_service_impl! {
    service = ImpressScenarioService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [],
    },
    impl = DefaultImpressScenarioService,
    instance = || impress_scenario_service_instance(),
    strict_args = true,
    methods = [
        scenario_validate(
            /// The scenario spec, as JSON.
            spec: SpecArg
        ) -> ScenarioValidateResult,
        scenario_create(
            /// The scenario spec, as JSON. Validated first; refused with
            /// every problem if any is found.
            spec: SpecArg,
            /// Free-text labels.
            tags: Option<Vec<String>>
        ) -> ScenarioResult,
        scenario_get(
            /// The row id, or the scenario's own stable `scenario_id`.
            id: String
        ) -> ScenarioResult,
        scenario_list() -> ScenarioListResult,
        scenario_run(
            /// The scenario's stable `scenario_id`.
            scenario_id: String,
            /// `"a"` or `"b"`; the scenario's own declared tier when absent.
            tier: Option<String>,
            /// The app's loopback base URL for a Tier B run (this device's
            /// impress by default).
            base_url: Option<String>
        ) -> ScenarioRunResult,
    ],
}
