//! Policy: `(caller, safety class, verb) → run | review | deny` (ADR-0034 D3,
//! plan-verb-pipeline § Policy).
//!
//! The mechanism behind "human review points are explicit": a mutating,
//! destructive or external verb from an agent is *queued* as the verb's
//! review surface instead of run, and the call answers
//! `{ok: false, code: "review-pending", surface_id}`; the person's later
//! confirmation re-enters the pipeline as the person. Nothing halts the
//! window.
//!
//! The default policy runs everything for every caller, so behaviour is
//! unchanged until a policy is configured — by [`install`] from the host, or
//! by `IMPRESS_VERB_POLICY` for a session:
//!
//! * `run-all` (the default);
//! * `review-agent-writes`: agents and providers are queued for every
//!   mutating, destructive or external verb;
//! * `review-agent-destructive`: agents and providers are queued for
//!   destructive and external verbs only (ADR-0034 D3's default once the
//!   generated review surface exists, ADR-0035 D2).
//!
//! Queuing needs a [`ReviewQueue`] — the surface the person confirms is
//! ADR-0035 G-side work — so a process with a review policy and no queue
//! answers `review-pending` naming that no queue is installed; the verb still
//! does not run, which is the safe direction.

use std::sync::{Arc, OnceLock, RwLock};

use serde_json::Value;

use super::identity::CallerIdentity;
use crate::descriptor::{SafetyClass, VerbDescriptor};
use crate::refusal::Refusal;

/// The generic refusal code for a call the policy queued.
pub const REVIEW_PENDING: &str = "review-pending";
/// The generic refusal code for a call the policy refused outright.
pub const FORBIDDEN: &str = "forbidden";

/// What the policy decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Run,
    Review,
    Deny(String),
}

/// A policy is a pure function of the caller and the descriptor.
pub trait Policy: Send + Sync {
    fn decide(&self, caller: &CallerIdentity, verb: &VerbDescriptor) -> Decision;
}

/// Runs everything: the default until a host configures otherwise.
pub struct RunEverything;

impl Policy for RunEverything {
    fn decide(&self, _: &CallerIdentity, _: &VerbDescriptor) -> Decision {
        Decision::Run
    }
}

/// Queue agents and providers for the listed classes; the person, the app
/// and the system always run.
pub struct ReviewAgents {
    pub classes: &'static [SafetyClass],
}

impl ReviewAgents {
    /// Every class that is not read-only.
    pub const WRITES: ReviewAgents = ReviewAgents {
        classes: &[
            SafetyClass::Mutating,
            SafetyClass::Destructive,
            SafetyClass::External,
        ],
    };
    /// Destructive and external only.
    pub const DESTRUCTIVE: ReviewAgents = ReviewAgents {
        classes: &[SafetyClass::Destructive, SafetyClass::External],
    };
}

impl Policy for ReviewAgents {
    fn decide(&self, caller: &CallerIdentity, verb: &VerbDescriptor) -> Decision {
        let reviewed = matches!(
            caller,
            CallerIdentity::Agent(_) | CallerIdentity::Provider(_)
        ) && self.classes.contains(&verb.safety.class);
        if reviewed {
            Decision::Review
        } else {
            Decision::Run
        }
    }
}

/// Where a reviewed call goes: the host creates the verb's review surface and
/// answers its id.
pub trait ReviewQueue: Send + Sync {
    fn enqueue(
        &self,
        caller: &CallerIdentity,
        verb: &VerbDescriptor,
        args: &Value,
    ) -> Result<String, Refusal>;
}

static POLICY: RwLock<Option<Arc<dyn Policy>>> = RwLock::new(None);
static QUEUE: RwLock<Option<Arc<dyn ReviewQueue>>> = RwLock::new(None);
static FROM_ENV: OnceLock<Option<Arc<dyn Policy>>> = OnceLock::new();

/// Install (or replace) the process's policy.
pub fn install(policy: Arc<dyn Policy>) {
    if let Ok(mut slot) = POLICY.write() {
        *slot = Some(policy);
    }
}

/// Install (or replace) the process's review queue.
pub fn install_queue(queue: Arc<dyn ReviewQueue>) {
    if let Ok(mut slot) = QUEUE.write() {
        *slot = Some(queue);
    }
}

/// The policy named by `IMPRESS_VERB_POLICY`, read once.
fn from_env() -> Option<Arc<dyn Policy>> {
    FROM_ENV
        .get_or_init(|| match std::env::var("IMPRESS_VERB_POLICY").as_deref() {
            Ok("review-agent-writes") => Some(Arc::new(ReviewAgents::WRITES) as Arc<dyn Policy>),
            Ok("review-agent-destructive") => Some(Arc::new(ReviewAgents::DESTRUCTIVE)),
            _ => None,
        })
        .clone()
}

/// Decide for one call: the installed policy, else the environment's, else
/// run.
pub fn decide(caller: &CallerIdentity, verb: &VerbDescriptor) -> Decision {
    let installed = POLICY.read().ok().and_then(|p| p.clone());
    match installed.or_else(from_env) {
        Some(policy) => policy.decide(caller, verb),
        None => Decision::Run,
    }
}

/// Queue a reviewed call and build its answer.
pub fn queue(caller: &CallerIdentity, verb: &VerbDescriptor, args: &Value) -> Value {
    let queue = QUEUE.read().ok().and_then(|q| q.clone());
    let mut answer = match queue {
        Some(queue) => match queue.enqueue(caller, verb, args) {
            Ok(surface_id) => {
                let mut v = crate::strict::refusal_value(&Refusal::new(
                    REVIEW_PENDING,
                    format!(
                        "{} from {caller} is queued for review; confirm surface {surface_id}",
                        verb.name
                    ),
                ));
                v["surface_id"] = Value::String(surface_id);
                v
            }
            Err(refusal) => crate::strict::refusal_value(&refusal),
        },
        None => crate::strict::refusal_value(&Refusal::new(
            REVIEW_PENDING,
            format!(
                "{} is {} and {caller} may not run it without review; no review queue \
                 is installed in this process, so the call was not run",
                verb.name, verb.safety.class
            ),
        )),
    };
    if let Some(object) = answer.as_object_mut() {
        object.insert("verb".into(), Value::String(verb.name.to_string()));
    }
    answer
}

/// The answer for a denied call.
pub fn deny(verb: &VerbDescriptor, reason: String) -> Value {
    crate::strict::refusal_value(&Refusal::new(FORBIDDEN, format!("{}: {reason}", verb.name)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::descriptor::{Safety, Source};
    use crate::ServiceFuture;

    fn schema() -> Value {
        serde_json::json!({})
    }
    fn handler(_: Value) -> ServiceFuture {
        Box::pin(async { Ok(Value::Null) })
    }
    fn verb(class: SafetyClass) -> VerbDescriptor {
        VerbDescriptor {
            name: "t-service_x",
            service: "t-service",
            method: "x",
            description: "d",
            input_schema: schema,
            output_schema: schema,
            safety: Safety {
                class,
                idempotent: false,
            },
            since: "0.1.0",
            effects: crate::Effects::NONE,
            deprecated: None,
            aliases: &[],
            examples: &[],
            strict: false,
            source: Source::Linked,
            handler,
        }
    }

    #[test]
    fn the_default_runs_everything() {
        let v = verb(SafetyClass::Destructive);
        assert_eq!(
            RunEverything.decide(&CallerIdentity::agent("mcp"), &v),
            Decision::Run
        );
    }

    #[test]
    fn review_policies_queue_agents_and_never_the_person() {
        let agent = CallerIdentity::agent("mcp");
        let writes = ReviewAgents::WRITES;
        assert_eq!(
            writes.decide(&agent, &verb(SafetyClass::Mutating)),
            Decision::Review
        );
        assert_eq!(
            writes.decide(&agent, &verb(SafetyClass::ReadOnly)),
            Decision::Run
        );
        assert_eq!(
            writes.decide(&CallerIdentity::Person, &verb(SafetyClass::Destructive)),
            Decision::Run
        );
        assert_eq!(
            writes.decide(
                &CallerIdentity::system("d"),
                &verb(SafetyClass::Destructive)
            ),
            Decision::Run
        );
        let destructive = ReviewAgents::DESTRUCTIVE;
        assert_eq!(
            destructive.decide(&agent, &verb(SafetyClass::Mutating)),
            Decision::Run
        );
        assert_eq!(
            destructive.decide(&agent, &verb(SafetyClass::External)),
            Decision::Review
        );
    }

    #[test]
    fn a_queued_call_answers_review_pending_with_the_verb() {
        let answer = queue(
            &CallerIdentity::agent("mcp"),
            &verb(SafetyClass::Mutating),
            &Value::Null,
        );
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["code"], REVIEW_PENDING);
        assert_eq!(answer["verb"], "t-service_x");
        assert_eq!(answer["wire_version"], crate::wire::WIRE_VERSION);
    }
}
