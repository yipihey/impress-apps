//! `reduce(&spec, &state, &params, &Event) -> Result<(Value, Vec<Effect>)>`: what
//! the human did, turned into a new state plus the side effects the runtime
//! still needs to carry out.
//!
//! This function is pure: a [`Action::Call`] is never invoked here, only
//! template-resolved into an [`Effect::Call`] for `impress-surface-service`'s
//! `Executor` (S4) to run. The same goes for `publish`/`emit`/`open`/`refresh`.
//! The one action `reduce` *does* perform itself is [`Action::Set`] — writing
//! into the returned state directly — because state is the value this function
//! already owns and returns; there is nothing for an `Effect::Set` to hand back
//! to a caller that `reduce`'s own return value doesn't already carry.
//!
//! # `each`: one effect per selected id (wave 5, V5)
//!
//! A widget's event shape stays uniform — a `select` on a table or list is
//! always an array of ids — while a verb keeps its own natural signature (a
//! triage verb takes one `id: String`, never a list). [`Action::Call`] and
//! [`Action::Emit`] close that gap with `each`, a literal path (`run_action`
//! resolves it once, with [`Context::with_item`] unbound) that must name an
//! array; this function then runs that one action once per element, with
//! `item` bound to it for the duration of that element's `args`/`payload`
//! resolution, appending one [`Effect`] per element in order. An empty array
//! produces no effects and is not an error — see [`resolve_each`]. This is a
//! fan-out declaration, not a loop the spec computes with: there is still
//! nothing here but a path lookup and a `for`, exactly the shape ADR-0033 D3
//! already allows a runtime (never a spec) to have.
//!
//! # Finding the node an event names
//!
//! An [`Event::widget`] is an id exactly as [`crate::resolve::resolve`] assigned
//! it — author-given or `n0.2.1`-style auto-derived. `reduce` calls the same
//! [`crate::spec::walk_with_ids`] `resolve` and `validate` use, so a widget id a
//! renderer reports always finds the node that produced it, with no separate
//! bookkeeping to keep in step.

use std::collections::BTreeMap;

use serde_json::{Map, Value};

use crate::spec::{walk_with_ids, Action, Event, EventKind, Node, NodeKind, SurfaceSpec};
use crate::template::{resolve_value, Context, Template, TemplateError};

/// A side effect `reduce` decided should happen but does not perform itself —
/// every action kind except `set`, which is folded into the returned state
/// directly (see the module docs).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Effect {
    Call {
        verb: String,
        args: Value,
        into: Option<String>,
    },
    /// `ids` is the resolved value to publish: either the literal path the
    /// action named (walked the same way `bind` is), or — when the action gave
    /// none — the triggering event's own `value`, which is what
    /// `{"publish": {}}` on a table/list `on_select` means in the plan's worked
    /// example.
    Publish {
        ids: Value,
    },
    Emit {
        name: String,
        payload: Value,
    },
    Open {
        query: Value,
        view_kind: String,
        target: Option<String>,
    },
    Refresh {
        source: String,
    },
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum ReduceError {
    #[error("event names widget '{widget}', which is not in this surface")]
    UnknownWidget { widget: String },
    #[error(
        "widget '{widget}' has no `bind` to change (a `change` event only applies to a field)"
    )]
    NotBindable { widget: String },
    #[error("`bind`/`set` path '{path}' must start with 'state.'")]
    InvalidPath { path: String },
    /// [`Action::Call`]/[`Action::Emit`]'s `each` resolved to something other
    /// than a JSON array — the one runtime check `validate` cannot make
    /// statically (it only knows the path's root, never its value).
    #[error("`each` path '{path}' did not resolve to an array")]
    EachNotArray { path: String },
    #[error(transparent)]
    Template(#[from] TemplateError),
}

/// See the module docs.
pub fn reduce(
    spec: &SurfaceSpec,
    state: &Value,
    params: &Value,
    event: &Event,
) -> Result<(Value, Vec<Effect>), ReduceError> {
    let index: BTreeMap<String, &Node> = walk_with_ids(&spec.root).into_iter().collect();
    let node = index
        .get(event.widget.as_str())
        .ok_or_else(|| ReduceError::UnknownWidget {
            widget: event.widget.clone(),
        })?;

    let mut new_state = state.clone();
    let mut effects = Vec::new();
    let event_value = serde_json::json!({
        "widget": event.widget,
        "kind": event_kind_str(event.kind),
        "value": event.value,
    });

    match event.kind {
        EventKind::Change => {
            let bind = node.bind.clone().ok_or_else(|| ReduceError::NotBindable {
                widget: event.widget.clone(),
            })?;
            set_path(&mut new_state, &bind, event.value.clone())?;
            run_actions(
                &node.on_change,
                &mut new_state,
                params,
                &event_value,
                &mut effects,
            )?;
        }
        EventKind::Click => {
            if let NodeKind::Button(b) = &node.kind {
                run_actions(
                    &b.on_click,
                    &mut new_state,
                    params,
                    &event_value,
                    &mut effects,
                )?;
            }
            // A click on anything else is a no-op: only `button` declares
            // `on_click`, and the plan gives no other meaning to the event kind.
        }
        EventKind::Select => match &node.kind {
            NodeKind::Table(t) => {
                run_actions(
                    &t.on_select,
                    &mut new_state,
                    params,
                    &event_value,
                    &mut effects,
                )?;
            }
            NodeKind::List(l) => {
                run_actions(
                    &l.on_select,
                    &mut new_state,
                    params,
                    &event_value,
                    &mut effects,
                )?;
            }
            _ => {}
        },
        EventKind::Submit => {
            // "runs `on_submit` if declared else is a no-op" — an empty
            // `on_submit` list already does nothing, so no branch is needed.
            run_actions(
                &node.on_submit,
                &mut new_state,
                params,
                &event_value,
                &mut effects,
            )?;
        }
    }

    Ok((new_state, effects))
}

fn event_kind_str(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Change => "change",
        EventKind::Click => "click",
        EventKind::Select => "select",
        EventKind::Submit => "submit",
    }
}

fn run_actions(
    actions: &[Action],
    state: &mut Value,
    params: &Value,
    event_value: &Value,
    effects: &mut Vec<Effect>,
) -> Result<(), ReduceError> {
    for action in actions {
        run_action(action, state, params, event_value, effects)?;
    }
    Ok(())
}

fn run_action(
    action: &Action,
    state: &mut Value,
    params: &Value,
    event_value: &Value,
    effects: &mut Vec<Effect>,
) -> Result<(), ReduceError> {
    // Rebuilt before every action (rather than held across the loop) so a `set`
    // earlier in the same handler is visible to a `{{state.…}}` reference in a
    // later action, without holding a borrow of `state` across the `set_path`
    // call that follows it.
    let source = Value::Object(Map::new()); // sources are not re-run mid-reduce
    let ctx = Context::new(state, params, &source, event_value);

    match action {
        Action::Set { path, value } => {
            let resolved = resolve_value(value, &ctx)?;
            set_path(state, path, resolved)?;
        }
        Action::Call {
            verb,
            args,
            into,
            each,
        } => match each {
            None => {
                let resolved_args = resolve_value(args, &ctx)?;
                effects.push(Effect::Call {
                    verb: verb.clone(),
                    args: resolved_args,
                    into: into.clone(),
                });
            }
            Some(each_path) => {
                for item in resolve_each(each_path, &ctx)? {
                    let item_ctx = ctx.with_item(&item);
                    let resolved_args = resolve_value(args, &item_ctx)?;
                    effects.push(Effect::Call {
                        verb: verb.clone(),
                        args: resolved_args,
                        into: into.clone(),
                    });
                }
            }
        },
        Action::Publish { ids } => {
            let resolved = match ids {
                Some(path) => read_state_path(path, state)?,
                None => event_value.get("value").cloned().unwrap_or(Value::Null),
            };
            effects.push(Effect::Publish { ids: resolved });
        }
        Action::Emit {
            name,
            payload,
            each,
        } => match each {
            None => {
                let resolved = resolve_value(payload, &ctx)?;
                effects.push(Effect::Emit {
                    name: name.clone(),
                    payload: resolved,
                });
            }
            Some(each_path) => {
                for item in resolve_each(each_path, &ctx)? {
                    let item_ctx = ctx.with_item(&item);
                    let resolved = resolve_value(payload, &item_ctx)?;
                    effects.push(Effect::Emit {
                        name: name.clone(),
                        payload: resolved,
                    });
                }
            }
        },
        Action::Open {
            query,
            view_kind,
            target,
        } => {
            let resolved_query = resolve_value(query, &ctx)?;
            effects.push(Effect::Open {
                query: resolved_query,
                view_kind: view_kind.clone(),
                target: target.clone(),
            });
        }
        Action::Refresh { source } => {
            effects.push(Effect::Refresh {
                source: source.clone(),
            });
        }
    }
    Ok(())
}

/// Write `value` at `path` (`state.a.b.c`), creating intermediate objects as
/// needed. Never removes a key it did not touch: every write is an insert or an
/// overwrite of exactly the named path, nothing else in `state` is visited.
fn set_path(state: &mut Value, path: &str, value: Value) -> Result<(), ReduceError> {
    let mut parts = path.split('.');
    if parts.next() != Some("state") {
        return Err(ReduceError::InvalidPath {
            path: path.to_string(),
        });
    }
    let segments: Vec<&str> = parts.collect();
    if segments.is_empty() {
        return Err(ReduceError::InvalidPath {
            path: path.to_string(),
        });
    }
    if !state.is_object() {
        *state = Value::Object(Map::new());
    }
    let mut cur = state;
    for (i, seg) in segments.iter().enumerate() {
        let map = match cur {
            Value::Object(m) => m,
            _ => {
                *cur = Value::Object(Map::new());
                match cur {
                    Value::Object(m) => m,
                    _ => unreachable!("just assigned an object"),
                }
            }
        };
        if i + 1 == segments.len() {
            map.insert((*seg).to_string(), value);
            return Ok(());
        }
        cur = map
            .entry((*seg).to_string())
            .or_insert_with(|| Value::Object(Map::new()));
    }
    Ok(())
}

/// Resolve an `each` literal path (any of the four `Context` roots — not
/// `state.` only, unlike `bind`/`set`/`publish.ids`: `validate::validate`
/// checks this) against `ctx` and require the result to be a JSON array. Reuses
/// [`Template::Single`]'s resolution — and therefore its errors — rather than a
/// second path-walking implementation: an unknown root or a missing path is
/// reported through the same [`TemplateError`] channel `resolve_value` already
/// uses, wrapped into a [`ReduceError`] by the same `#[from]` conversion.
fn resolve_each(each_path: &str, ctx: &Context) -> Result<Vec<Value>, ReduceError> {
    let segments: Vec<String> = each_path.split('.').map(str::to_string).collect();
    let value = Template::Single(segments).resolve(ctx)?;
    match value {
        Value::Array(items) => Ok(items),
        _ => Err(ReduceError::EachNotArray {
            path: each_path.to_string(),
        }),
    }
}

fn read_state_path(path: &str, state: &Value) -> Result<Value, ReduceError> {
    if !path.starts_with("state.") && path != "state" {
        return Err(ReduceError::InvalidPath {
            path: path.to_string(),
        });
    }
    let mut cur = state;
    for seg in path.split('.').skip(1) {
        cur = match cur.as_object().and_then(|m| m.get(seg)) {
            Some(v) => v,
            None => return Ok(Value::Null),
        };
    }
    Ok(cur.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::{Button, Node, NodeKind, SurfaceSpec, SURFACE_VERSION};

    fn star_button_spec(state: Value) -> SurfaceSpec {
        let root = Node::leaf(NodeKind::Button(Button {
            label: "Star".to_string(),
            on_click: vec![Action::Call {
                verb: "triage-service_set-starred".to_string(),
                args: serde_json::json!({"id": "{{item}}", "starred": true}),
                into: None,
                each: Some("state.selected".to_string()),
            }],
        }))
        .with_id("star-btn");
        SurfaceSpec {
            surface: SURFACE_VERSION.to_string(),
            name: "t".to_string(),
            params: Vec::new(),
            state,
            sources: BTreeMap::new(),
            root,
        }
    }

    fn click() -> Event {
        Event {
            widget: "star-btn".to_string(),
            kind: EventKind::Click,
            value: Value::Null,
        }
    }

    #[test]
    fn each_fans_out_one_call_effect_per_element_with_item_bound() {
        let spec = star_button_spec(serde_json::json!({"selected": ["a", "b"]}));
        let params = Value::Null;
        let (_, effects) = reduce(&spec, &spec.state, &params, &click()).unwrap();
        assert_eq!(
            effects,
            vec![
                Effect::Call {
                    verb: "triage-service_set-starred".to_string(),
                    args: serde_json::json!({"id": "a", "starred": true}),
                    into: None,
                },
                Effect::Call {
                    verb: "triage-service_set-starred".to_string(),
                    args: serde_json::json!({"id": "b", "starred": true}),
                    into: None,
                },
            ]
        );
    }

    #[test]
    fn an_empty_each_array_produces_no_effects_and_is_not_an_error() {
        let spec = star_button_spec(serde_json::json!({"selected": []}));
        let params = Value::Null;
        let (_, effects) = reduce(&spec, &spec.state, &params, &click()).unwrap();
        assert_eq!(effects, Vec::new());
    }

    #[test]
    fn a_non_array_each_is_a_reduce_error_naming_the_path() {
        let spec = star_button_spec(serde_json::json!({"selected": "not-an-array"}));
        let params = Value::Null;
        let err = reduce(&spec, &spec.state, &params, &click()).unwrap_err();
        assert_eq!(
            err,
            ReduceError::EachNotArray {
                path: "state.selected".to_string()
            }
        );
    }

    #[test]
    fn each_fans_out_emit_the_same_way_as_call() {
        let root = Node::leaf(NodeKind::Button(Button {
            label: "Star".to_string(),
            on_click: vec![Action::Emit {
                name: "triaged".to_string(),
                payload: serde_json::json!({"id": "{{item}}"}),
                each: Some("state.selected".to_string()),
            }],
        }))
        .with_id("star-btn");
        let spec = SurfaceSpec {
            surface: SURFACE_VERSION.to_string(),
            name: "t".to_string(),
            params: Vec::new(),
            state: serde_json::json!({"selected": ["x", "y"]}),
            sources: BTreeMap::new(),
            root,
        };
        let params = Value::Null;
        let (_, effects) = reduce(&spec, &spec.state, &params, &click()).unwrap();
        assert_eq!(
            effects,
            vec![
                Effect::Emit {
                    name: "triaged".to_string(),
                    payload: serde_json::json!({"id": "x"}),
                },
                Effect::Emit {
                    name: "triaged".to_string(),
                    payload: serde_json::json!({"id": "y"}),
                },
            ]
        );
    }
}
