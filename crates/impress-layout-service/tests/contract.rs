//! Wave 7 T6b: the written contract of the layout verbs.
//!
//! * strict arguments — a field the input schema does not name is refused
//!   with `invalid-argument` naming it, through the SAME invoker MCP and the
//!   CLI call (review RL-L3, AC-F3);
//! * one pane-reference spelling, and `{}` names nothing;
//! * every result carries `wire_version` (AC-F24) and the live row's
//!   `revision`; a stale `expected_revision` is refused `conflict` and
//!   changes nothing (RL-L1's wire half);
//! * a view kind or record kind outside the vocabulary is refused at verb
//!   time (RL-L12, PH-M7);
//! * several verbs apply as one gesture and one undo step (PH-M2).
//!
//! Its own test binary: the inventory path uses the process-global store.

use std::sync::Arc;

use impress_core::item::ActorKind;
use impress_core::sqlite_store::SqliteItemStore;
use impress_layout::{PaneRef, Verb, ViewKindId};
use impress_layout_service::{DefaultLayoutService, LayoutService, PaneRefDto};
use impress_service_core::wire::WIRE_VERSION;
use serde_json::json;

const APP: &str = "contract-test";

fn device() -> Option<String> {
    Some("contract-device".to_string())
}

fn service() -> DefaultLayoutService {
    DefaultLayoutService::with_store(Arc::new(SqliteItemStore::open_in_memory().unwrap()))
}

/// Call a generated tool exactly as MCP and the CLI do: through the
/// inventory's handler, with a JSON argument object.
async fn call(tool: &str, args: serde_json::Value) -> serde_json::Value {
    let descriptor =
        impress_service_core::inventory::iter::<impress_service_core::McpToolDescriptor>
            .into_iter()
            .find(|d| d.name == tool)
            .unwrap_or_else(|| panic!("no tool {tool}"));
    (descriptor.handler)(args)
        .await
        .unwrap_or_else(|e| panic!("{tool} failed as a transport error, not a refusal: {e}"))
}

fn global_store() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let dir = std::env::temp_dir().join(format!("t6b-contract-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        impress_store_service::set_store_path(dir.join("impress.sqlite").to_str().unwrap())
            .unwrap();
    });
}

#[tokio::test]
async fn an_unknown_field_is_refused_by_name_through_the_mcp_invoker() {
    global_store();
    // The retired tagged spelling, copied from an old result into `close`:
    // it used to read as `{}` = the focused pane, and close it with ok:true.
    let closed = call(
        "layout-service_close",
        json!({"app_id": APP, "device": "strict", "target": {"ref": "id", "tile": 7}}),
    )
    .await;
    assert_eq!(closed["ok"], false, "{closed}");
    assert_eq!(closed["code"], "invalid-argument", "{closed}");
    assert_eq!(closed["wire_version"], WIRE_VERSION);
    let message = closed["message"].as_str().unwrap();
    assert!(message.starts_with("layout-service_close: "), "{message}");
    assert!(
        message.contains("unknown field 'ref' in 'target'"),
        "{message}"
    );
    assert!(
        message.contains("direction, focused, id, role"),
        "{message}"
    );

    // A top-level typo, and one deep inside a query.
    let typo = call(
        "layout-service_focus",
        json!({"app_id": APP, "device": "strict", "target": {"focused": true}, "actr": "agent"}),
    )
    .await;
    assert_eq!(typo["code"], "invalid-argument", "{typo}");
    assert!(
        typo["message"]
            .as_str()
            .unwrap()
            .contains("unknown field 'actr'"),
        "{typo}"
    );

    let deep = call(
        "layout-service_set-query",
        json!({"app_id": APP, "device": "strict", "target": {"role": "list"},
               "query": {"kind": "publication"}}),
    )
    .await;
    assert_eq!(deep["code"], "invalid-argument", "{deep}");
    assert!(
        deep["message"]
            .as_str()
            .unwrap()
            .contains("unknown field 'kind' in 'query'"),
        "{deep}"
    );

    // An empty reference names nothing.
    let empty = call(
        "layout-service_close",
        json!({"app_id": APP, "device": "strict", "target": {}}),
    )
    .await;
    assert_eq!(empty["code"], "invalid-argument", "{empty}");

    // The canonical spelling works, and the answer is versioned.
    let ok = call(
        "layout-service_focus",
        json!({"app_id": APP, "device": "strict", "target": {"role": "list"}}),
    )
    .await;
    assert_eq!(ok["ok"], true, "{ok}");
    assert_eq!(ok["wire_version"], WIRE_VERSION);
    assert!(ok["revision"].as_u64().is_some(), "{ok}");
}

#[tokio::test]
async fn a_stale_expected_revision_is_a_conflict_and_changes_nothing() {
    let svc = service();
    let read = svc.get_layout(APP.into(), device()).await;
    let revision = read.revision.expect("a read says its revision");
    assert_eq!(read.wire_version, WIRE_VERSION);

    // The person moves focus in between (any write moves the revision).
    let moved = svc
        .set_view_kind(
            APP.into(),
            device(),
            PaneRefDto::role("detail"),
            "notes".into(),
            Some("human".into()),
            Some(revision),
        )
        .await;
    assert!(moved.ok, "{}", moved.message);
    let after = moved
        .revision
        .expect("a verb says the revision it produced");
    assert_ne!(after, revision);

    // The agent acts on what it read: refused, nothing changes.
    let stale = svc
        .close(
            APP.into(),
            device(),
            PaneRefDto::role("detail"),
            None,
            Some(revision),
        )
        .await;
    assert!(!stale.ok);
    assert_eq!(stale.code.as_deref(), Some("conflict"), "{}", stale.message);
    assert!(
        stale.message.contains(&format!("revision {after}")),
        "{}",
        stale.message
    );
    let now = svc.get_layout(APP.into(), device()).await;
    assert_eq!(now.revision, Some(after), "the refused verb wrote nothing");

    // With the current revision it goes through.
    let fresh = svc
        .set_view_kind(
            APP.into(),
            device(),
            PaneRefDto::role("detail"),
            "info".into(),
            None,
            Some(after),
        )
        .await;
    assert!(fresh.ok, "{}", fresh.message);

    // The persistence verbs check it too.
    let undo = svc
        .undo(
            APP.into(),
            device(),
            "arrangement".into(),
            None,
            None,
            Some(revision),
        )
        .await;
    assert_eq!(undo.code.as_deref(), Some("conflict"), "{}", undo.message);
}

#[tokio::test]
async fn a_view_kind_or_a_query_kind_outside_the_vocabulary_is_refused() {
    let svc = service();
    let holodeck = svc
        .set_view_kind(
            APP.into(),
            device(),
            PaneRefDto::role("detail"),
            "editor".into(),
            None,
            None,
        )
        .await;
    assert!(!holodeck.ok);
    assert_eq!(holodeck.code.as_deref(), Some("unknown-view-kind"));
    assert!(holodeck.message.contains("source"), "{}", holodeck.message);

    let query: impress_layout::PaneQuery =
        serde_json::from_value(json!({"kinds": ["papers"]})).unwrap();
    let set = svc
        .set_query(
            APP.into(),
            device(),
            PaneRefDto::role("list"),
            query,
            None,
            None,
        )
        .await;
    assert_eq!(
        set.code.as_deref(),
        Some("invalid-argument"),
        "{}",
        set.message
    );

    for kind in ViewKindId::KNOWN {
        let ok = svc
            .set_view_kind(
                APP.into(),
                device(),
                PaneRefDto::role("detail"),
                kind.to_string(),
                None,
                None,
            )
            .await;
        assert!(ok.ok, "{kind}: {}", ok.message);
    }
}

#[tokio::test]
async fn every_result_envelope_carries_the_wire_version() {
    let svc = service();
    let results = [
        serde_json::to_value(svc.get_layout(APP.into(), device()).await).unwrap(),
        serde_json::to_value(
            svc.get_pane(APP.into(), device(), PaneRefDto::role("list"))
                .await,
        )
        .unwrap(),
        serde_json::to_value(
            svc.get_channel(APP.into(), device(), "1".into(), None)
                .await,
        )
        .unwrap(),
        serde_json::to_value(
            svc.resolve_reference(APP.into(), device(), PaneRefDto::focused())
                .await,
        )
        .unwrap(),
        serde_json::to_value(svc.list_layouts(APP.into()).await).unwrap(),
        serde_json::to_value(svc.list_presets(APP.into()).await).unwrap(),
        serde_json::to_value(
            svc.focus(APP.into(), device(), PaneRefDto::role("list"), None, None)
                .await,
        )
        .unwrap(),
        serde_json::to_value(
            svc.close(
                APP.into(),
                device(),
                PaneRefDto::tile(4242.into()),
                None,
                None,
            )
            .await,
        )
        .unwrap(),
        serde_json::to_value(svc.reset_preset(APP.into(), "No Such".into(), None).await).unwrap(),
    ];
    for result in results {
        assert_eq!(result["wire_version"], WIRE_VERSION, "{result}");
        assert!(
            result.get("store").is_none(),
            "a real store is not marked: {result}"
        );
        // snake_case throughout: no key has an uppercase letter.
        for key in result.as_object().unwrap().keys() {
            assert!(!key.chars().any(char::is_uppercase), "{key} in {result}");
        }
    }
}

#[tokio::test]
async fn several_verbs_apply_as_one_gesture_and_one_undo_step() {
    let svc = service();
    let layout = svc.get_layout(APP.into(), device()).await.layout.unwrap();
    let window = layout.current_window().unwrap();
    let list = layout
        .resolve(window, &PaneRef::role(impress_layout::Role::LIST))
        .unwrap();
    let detail = layout
        .resolve(window, &PaneRef::role(impress_layout::Role::DETAIL))
        .unwrap();
    let before = layout.pane(detail).unwrap().view_kind.clone();

    let applied = svc.apply_verbs_as(
        APP,
        device(),
        ActorKind::Human,
        None,
        vec![
            Verb::Focus {
                target: PaneRef::id(list),
            },
            Verb::SetViewKind {
                target: PaneRef::id(list),
                view_kind: ViewKindId::INFO,
            },
            Verb::SetViewKind {
                target: PaneRef::id(detail),
                view_kind: ViewKindId::BIBTEX,
            },
        ],
    );
    assert!(applied.ok, "{}", applied.message);
    assert_eq!(applied.stack.as_deref(), Some("exploration"));
    assert_eq!(applied.stack_pane, Some(list.raw()));

    // One ⌘Z in the list pane takes back all of it, the detail pane included.
    let undone = svc
        .undo(
            APP.into(),
            device(),
            "exploration".into(),
            Some(PaneRefDto::tile(list)),
            None,
            None,
        )
        .await;
    assert!(undone.ok, "{}", undone.message);
    let after = svc.get_layout(APP.into(), device()).await.layout.unwrap();
    assert_eq!(after.pane(detail).unwrap().view_kind, before);
    assert_eq!(after.pane(list).unwrap().view_kind, ViewKindId::LIST);

    // A refusal in the middle applies none of it.
    let revision = svc.get_layout(APP.into(), device()).await.revision;
    let refused = svc.apply_verbs_as(
        APP,
        device(),
        ActorKind::Human,
        None,
        vec![
            Verb::SetViewKind {
                target: PaneRef::id(detail),
                view_kind: ViewKindId::NOTES,
            },
            Verb::Close {
                target: PaneRef::id(4242.into()),
            },
        ],
    );
    assert!(!refused.ok);
    assert_eq!(
        refused.code.as_deref(),
        Some("unknown-tile"),
        "{}",
        refused.message
    );
    let still = svc.get_layout(APP.into(), device()).await;
    assert_eq!(still.revision, revision, "nothing was written");
    assert_eq!(
        still.layout.unwrap().pane(detail).unwrap().view_kind,
        before
    );
}
