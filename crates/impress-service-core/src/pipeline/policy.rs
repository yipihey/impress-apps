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

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::identity::CallerIdentity;
use crate::descriptor::{Kind, SafetyClass, VerbDescriptor};
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
    /// D-R11: a destructive verb whose declared write set overlaps another
    /// call's, still in flight on the same kind. `String` is the conflicting
    /// kind.
    Conflict(String),
}

// ---------------------------------------------------------------------------
// D-R11: concurrent-write conflict detection
// ---------------------------------------------------------------------------
//
// "Two concurrent calls whose declared write sets overlap: a destructive
// overlap is refused (`conflict`); a mutating overlap is logged."
// (plan-self-reflective-layer.md's E3 row, D-R11).
//
// This is an IN-FLIGHT SET KEYED BY KIND, entirely local to this file (kept
// out of `pipeline/mod.rs`'s `prepare`/`finish` — the audit/call-context
// machinery L1 owns concurrently) — which means it has no hook at the exact
// moment a call finishes to release its kinds. Instead an entry expires
// after [`IN_FLIGHT_TTL`]: long enough to see two calls that actually
// overlap in time (the Tier A proof below fires them back to back with no
// `await` between), short enough that a slow verb does not poison the kind
// for calls that start long after it returned. A precise release (a guard
// dropped when the call's `finish()` runs) is the natural next step once
// this lives beside that code; noted here rather than reached for across a
// module boundary this plan keeps separate.
const IN_FLIGHT_TTL: Duration = Duration::from_secs(5);

struct InFlight {
    entries: Mutex<HashMap<String, Instant>>,
}

impl InFlight {
    fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Instant>> {
        self.entries.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Drop every entry older than the TTL.
    fn sweep(&self, now: Instant) {
        self.lock().retain(|_, at| now.duration_since(*at) < IN_FLIGHT_TTL);
    }

    /// Kinds of `writes` already in flight, before recording `writes` as
    /// in-flight too (every kind, present or not, is (re)stamped `now`).
    fn overlap_and_record(&self, writes: &[&str], now: Instant) -> Vec<String> {
        let mut table = self.lock();
        let overlap: Vec<String> = writes
            .iter()
            .filter(|k| table.contains_key(**k))
            .map(|k| k.to_string())
            .collect();
        for k in writes {
            table.insert(k.to_string(), now);
        }
        overlap
    }
}

static IN_FLIGHT: LazyLock<InFlight> = LazyLock::new(InFlight::new);

/// The literal (`Kind::Ref`) kinds `verb` declares among its writes — the
/// same "dynamic declarations are this static walk's blind spot, not its
/// problem to solve" reasoning `impress-surface-service::runtime`'s
/// `verb_declared_read_refs` gives for reads (E3).
fn literal_write_kinds(verb: &VerbDescriptor) -> Vec<&'static str> {
    verb.effects
        .writes
        .iter()
        .filter_map(|k| match k {
            Kind::Ref(r) => Some(*r),
            _ => None,
        })
        .collect()
}

/// D-R11's check, run for every call whose safety class is not read-only
/// (read-only verbs write nothing to conflict over). A destructive verb
/// whose declared writes overlap another call's in-flight writes is refused
/// `conflict`; a mutating verb's overlap is logged (`tracing::warn!`) and
/// still runs — the row's "refused / logged" split, by class.
fn check_conflict(verb: &VerbDescriptor) -> Option<Decision> {
    if verb.safety.class == SafetyClass::ReadOnly {
        return None;
    }
    let writes = literal_write_kinds(verb);
    if writes.is_empty() {
        return None;
    }
    let now = Instant::now();
    IN_FLIGHT.sweep(now);
    let overlap = IN_FLIGHT.overlap_and_record(&writes, now);
    if overlap.is_empty() {
        return None;
    }
    match verb.safety.class {
        SafetyClass::Destructive | SafetyClass::External => {
            Some(Decision::Conflict(overlap.join(", ")))
        }
        _ => {
            tracing::warn!(
                target: "verb",
                verb = verb.name,
                kinds = %overlap.join(", "),
                "mutating call overlaps another in-flight call's declared writes (D-R11)"
            );
            None
        }
    }
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

/// Decide for one call: D-R11's conflict check first (every caller, not
/// just agents — a resource conflict is not a review policy), then the
/// installed policy, else the environment's, else run.
pub fn decide(caller: &CallerIdentity, verb: &VerbDescriptor) -> Decision {
    if let Some(conflict) = check_conflict(verb) {
        return conflict;
    }
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

/// The answer for a call refused over D-R11: a destructive verb whose
/// declared writes overlap another call's in-flight writes on `kinds`.
pub fn conflict(verb: &VerbDescriptor, kinds: String) -> Value {
    crate::strict::refusal_value(&Refusal::conflict(format!(
        "{} is destructive and its declared writes ({kinds}) overlap another call still in \
         flight on the same kind (D-R11)",
        verb.name
    )))
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

    /// A verb declaring `writes` (as `Kind::Ref`s), for D-R11's tests. Every
    /// call passes a distinct `name`/kind: [`IN_FLIGHT`] is one process-wide
    /// static, and `cargo test` runs these in parallel threads.
    fn verb_writing(name: &'static str, class: SafetyClass, writes: &'static [Kind]) -> VerbDescriptor {
        VerbDescriptor {
            name,
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
            effects: crate::descriptor::Effects {
                reads: &[],
                writes,
                reach: &[],
            },
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

    // ─── D-R11: concurrent-write conflict detection ───────────────────────

    #[test]
    fn two_destructive_calls_with_overlapping_writes_conflict() {
        const WRITES: &[Kind] = &[Kind::Ref("d-r11-test/destructive-overlap")];
        let a = verb_writing("d-r11_a1", SafetyClass::Destructive, WRITES);
        let b = verb_writing("d-r11_a2", SafetyClass::Destructive, WRITES);
        let agent = CallerIdentity::agent("mcp");
        assert_eq!(decide(&agent, &a), Decision::Run, "the first call runs");
        assert_eq!(
            decide(&agent, &b),
            Decision::Conflict("d-r11-test/destructive-overlap".to_string()),
            "the second, overlapping, destructive call is refused"
        );
    }

    #[test]
    fn a_mutating_overlap_is_not_refused() {
        const WRITES: &[Kind] = &[Kind::Ref("d-r11-test/mutating-overlap")];
        let a = verb_writing("d-r11_b1", SafetyClass::Mutating, WRITES);
        let b = verb_writing("d-r11_b2", SafetyClass::Mutating, WRITES);
        let agent = CallerIdentity::agent("mcp");
        assert_eq!(decide(&agent, &a), Decision::Run);
        assert_eq!(
            decide(&agent, &b),
            Decision::Run,
            "a mutating overlap is logged, not refused"
        );
    }

    #[test]
    fn disjoint_write_sets_never_conflict() {
        const WRITES_A: &[Kind] = &[Kind::Ref("d-r11-test/disjoint-a")];
        const WRITES_B: &[Kind] = &[Kind::Ref("d-r11-test/disjoint-b")];
        let a = verb_writing("d-r11_c1", SafetyClass::Destructive, WRITES_A);
        let b = verb_writing("d-r11_c2", SafetyClass::Destructive, WRITES_B);
        let agent = CallerIdentity::agent("mcp");
        assert_eq!(decide(&agent, &a), Decision::Run);
        assert_eq!(decide(&agent, &b), Decision::Run);
    }

    #[test]
    fn a_read_only_verb_never_conflicts() {
        assert_eq!(check_conflict(&verb(SafetyClass::ReadOnly)), None);
    }
}
