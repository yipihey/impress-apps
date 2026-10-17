//! `StoreQueryService` — grouped global search, cross-kind relations, and
//! generic get/browse (ADR-0022 D6 / D8 / D5-G6), now koine's
//! (`koine_store_query::service`, docs/plan-koine-kit-moves.md KM9).
//!
//! The four `store-query-service_*` verbs register from koine's inventory,
//! over the store port, and read the process store this crate's store
//! module installs. This module re-exports them so every
//! `impress_store_service::query_service` path still resolves; the tests
//! below keep proving them over SQLite.

pub use koine_store_query::service::*;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item, make_item_named, test_store};
    use impress_core::item::Value;
    use impress_core::reference::{EdgeType, TypedReference};
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_core::store::{FieldMutation, ItemStore};
    use std::sync::Arc;

    fn svc() -> (Arc<SqliteItemStore>, DefaultStoreQueryService) {
        let store = test_store();
        let service = DefaultStoreQueryService::with_store(store.clone());
        (store, service)
    }

    fn link(store: &SqliteItemStore, source: &str, target: &str, edge: EdgeType) {
        store
            .update(
                uuid::Uuid::parse_str(source).unwrap(),
                vec![FieldMutation::AddReference(TypedReference {
                    target: uuid::Uuid::parse_str(target).unwrap(),
                    edge_type: edge,
                    metadata: None,
                })],
            )
            .expect("add reference");
    }

    fn dismiss(store: &SqliteItemStore, id: &str) {
        store
            .update(
                uuid::Uuid::parse_str(id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "status".into(),
                    Value::String("dismissed".into()),
                )],
            )
            .expect("dismiss");
    }

    // ─── search_all ──────────────────────────────────────────────────────

    #[tokio::test]
    async fn search_all_returns_kind_tagged_hits_and_names_the_buckets() {
        let (store, s) = svc();
        make_item_named(&store, "manuscript", "Nucleosynthesis in dwarfs");
        make_item_named(&store, "figure", "Nucleosynthesis yields");
        make_item_named(&store, "task", "Rewrite the nucleosynthesis section");
        make_item_named(&store, "manuscript", "Something else entirely");

        let out = s.search_all("nucleosynthesis".into(), 10).await;
        assert!(out.ok, "{}", out.message);
        assert_eq!(out.hits.len(), 3, "{:?}", out.hits);
        assert_eq!(
            out.kinds,
            vec!["figure", "manuscript", "task"],
            "kinds are named in result order"
        );
        assert!(out.hits.iter().all(|h| !h.snippet.is_empty()));
        assert!(out.message.contains("3 hit(s)"), "{}", out.message);
    }

    #[tokio::test]
    async fn search_all_caps_each_kind_separately() {
        let (store, s) = svc();
        for n in 0..12 {
            make_item_named(&store, "email-message", &format!("budget thread {n}"));
        }
        let manuscript = make_item_named(&store, "manuscript", "Budget narrative");

        let out = s.search_all("budget".into(), 2).await;
        assert!(out.ok, "{}", out.message);
        assert_eq!(
            out.hits
                .iter()
                .filter(|h| h.schema_ref == "email-message")
                .count(),
            2,
            "the per-kind cap must bind: {:?}",
            out.hits
        );
        assert!(
            out.hits.iter().any(|h| h.id == manuscript),
            "the manuscript must survive 12 messages"
        );
    }

    #[tokio::test]
    async fn search_all_treats_the_query_as_words_not_syntax() {
        let (store, s) = svc();
        make_item_named(&store, "manuscript", "Dark matter halos");

        for hostile in [
            "foo AND (",
            "\"unbalanced",
            "NEAR(",
            "*",
            ")))",
            "'; DROP TABLE items; --",
        ] {
            let out = s.search_all(hostile.into(), 5).await;
            assert!(out.ok, "{hostile:?} must not fail: {}", out.message);
        }

        // Empty input is an empty answer, not an error.
        let empty = s.search_all("   ".into(), 5).await;
        assert!(empty.ok);
        assert!(empty.hits.is_empty());
        assert!(empty.kinds.is_empty());

        // A real query still works.
        let real = s.search_all("dark".into(), 5).await;
        assert_eq!(real.hits.len(), 1, "{:?}", real.hits);
        assert_eq!(real.hits[0].title, "Dark matter halos");
    }

    #[tokio::test]
    async fn search_all_withholds_dismissed_items_only() {
        let (store, s) = svc();
        let live = make_item_named(&store, "task", "Recalibrate the detector");
        let gone = make_item_named(&store, "task", "Recalibrate someday");
        dismiss(&store, &gone);

        let out = s.search_all("recalibrate".into(), 10).await;
        let ids: Vec<&str> = out.hits.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(ids, vec![live.as_str()], "{:?}", out.hits);
    }

    #[tokio::test]
    async fn search_all_accepts_zero_and_negative_limits() {
        let (store, s) = svc();
        make_item_named(&store, "manuscript", "Widget study");
        for limit in [0i64, -1, i64::MIN, i64::MAX] {
            let out = s.search_all("widget".into(), limit).await;
            assert!(out.ok, "limit {limit}: {}", out.message);
            assert_eq!(out.hits.len(), 1, "limit {limit}");
        }
    }

    // ─── related_items ───────────────────────────────────────────────────

    #[tokio::test]
    async fn related_items_walks_both_directions_across_kinds() {
        let (store, s) = svc();
        let manuscript = make_item_named(&store, "manuscript", "Draft II");
        let figure = make_item_named(&store, "figure", "Rotation curve");
        let paper = make_item_named(&store, "imbib/bibliography-entry", "Zwicky 1933");
        let task = make_item_named(&store, "task", "Redo the fit");
        let message = make_item_named(&store, "email-message", "Re: Draft II");

        link(&store, &manuscript, &figure, EdgeType::Contains);
        link(&store, &manuscript, &paper, EdgeType::Cites);
        link(&store, &task, &manuscript, EdgeType::ProducedBy);
        link(&store, &message, &manuscript, EdgeType::InResponseTo);

        let out = s.related_items(manuscript.clone(), 10).await;
        assert!(out.ok, "{}", out.message);
        assert_eq!(out.related.len(), 4, "{:?}", out.related);

        let contains = out
            .related
            .iter()
            .find(|r| r.edge_type == "Contains")
            .unwrap();
        assert_eq!(contains.id, figure);
        assert_eq!(contains.schema_ref, "figure");
        assert_eq!(contains.direction, "outgoing");

        let produced = out
            .related
            .iter()
            .find(|r| r.edge_type == "ProducedBy")
            .unwrap();
        assert_eq!(produced.id, task);
        assert_eq!(produced.direction, "incoming");

        // The other end sees the mirror image.
        let back = s.related_items(figure, 10).await;
        assert_eq!(back.related.len(), 1);
        assert_eq!(back.related[0].id, manuscript);
        assert_eq!(back.related[0].direction, "incoming");
        assert_eq!(back.related[0].title, "Draft II");
    }

    #[tokio::test]
    async fn related_items_skips_deleted_ends() {
        let (store, s) = svc();
        let manuscript = make_item_named(&store, "manuscript", "Draft II");
        let kept = make_item_named(&store, "figure", "Panel A");
        let doomed = make_item_named(&store, "figure", "Panel B");
        link(&store, &manuscript, &kept, EdgeType::Contains);
        link(&store, &manuscript, &doomed, EdgeType::Contains);
        assert_eq!(
            s.related_items(manuscript.clone(), 10).await.related.len(),
            2
        );

        store
            .delete(uuid::Uuid::parse_str(&doomed).unwrap())
            .unwrap();
        let out = s.related_items(manuscript, 10).await;
        assert_eq!(out.related.len(), 1, "{:?}", out.related);
        assert_eq!(out.related[0].id, kept);
    }

    #[tokio::test]
    async fn related_items_fails_loudly_on_bad_ids() {
        let (store, s) = svc();
        let malformed = s.related_items("not-a-uuid".into(), 10).await;
        assert!(!malformed.ok);
        assert!(
            malformed.message.contains("invalid UUID"),
            "{}",
            malformed.message
        );

        let missing = s.related_items(uuid::Uuid::new_v4().to_string(), 10).await;
        assert!(!missing.ok);
        assert!(missing.message.contains("not found"), "{}", missing.message);

        // An item with no edges is an empty list, not a failure — the two
        // answers must be distinguishable.
        let lonely = make_item_named(&store, "manuscript", "Untouched");
        let empty = s.related_items(lonely, 10).await;
        assert!(empty.ok);
        assert!(empty.related.is_empty());
    }

    // ─── get_item ────────────────────────────────────────────────────────

    #[tokio::test]
    async fn get_item_returns_the_whole_envelope_and_the_payload() {
        let (store, s) = svc();
        let id = make_item_named(&store, "manuscript", "Draft II");
        let uuid = uuid::Uuid::parse_str(&id).unwrap();
        let parent = make_item_named(&store, "manuscript-collection", "Chapters");
        store
            .update(
                uuid,
                vec![
                    FieldMutation::SetStarred(true),
                    FieldMutation::SetFlag(Some(impress_core::item::FlagState {
                        color: "amber".into(),
                        style: None,
                        length: None,
                    })),
                    FieldMutation::AddTag("writing/active".into()),
                    FieldMutation::SetPayload(
                        "status".into(),
                        Value::String("internal-review".into()),
                    ),
                    FieldMutation::SetPayload("word_count".into(), Value::Int(4200)),
                    FieldMutation::SetParent(Some(uuid::Uuid::parse_str(&parent).unwrap())),
                ],
            )
            .expect("triage the manuscript");

        let out = s.get_item(id.clone()).await;
        assert!(out.ok, "{}", out.message);
        let item = out.item.expect("an envelope");
        assert_eq!(item.id, id);
        assert_eq!(item.schema_ref, "manuscript");
        assert_eq!(item.title, "Draft II");
        assert_eq!(item.status.as_deref(), Some("internal-review"));
        assert_eq!(item.flag.as_deref(), Some("amber"));
        assert!(item.starred);
        assert_eq!(item.tags, vec!["writing/active"]);
        assert_eq!(item.parent_id.as_deref(), Some(parent.as_str()));
        // ISO 8601 / RFC 3339, and both stamps parse.
        for stamp in [&item.created, &item.modified] {
            chrono::DateTime::parse_from_rfc3339(stamp)
                .unwrap_or_else(|e| panic!("{stamp} is not ISO 8601: {e}"));
        }

        // The payload arrives whole and re-parses, which is the contract that
        // makes it worth shipping as a string at all.
        assert!(!out.truncated);
        assert!(out.note.is_none());
        let payload: serde_json::Value =
            serde_json::from_str(&out.payload).expect("payload parses");
        assert_eq!(payload["title"], "Draft II");
        assert_eq!(payload["word_count"], 4200);
    }

    #[tokio::test]
    async fn get_item_falls_back_through_subject_and_name_for_the_title() {
        let (store, s) = svc();
        let with_subject = make_item(&store, "email-message");
        store
            .update(
                uuid::Uuid::parse_str(&with_subject).unwrap(),
                vec![
                    FieldMutation::RemovePayload("title".into()),
                    FieldMutation::SetPayload("subject".into(), Value::String("Re: budget".into())),
                ],
            )
            .unwrap();
        assert_eq!(
            s.get_item(with_subject).await.item.unwrap().title,
            "Re: budget",
            "subject is the mail title, exactly as the search index reads it"
        );

        let untitled = make_item(&store, "figure");
        store
            .update(
                uuid::Uuid::parse_str(&untitled).unwrap(),
                vec![FieldMutation::RemovePayload("title".into())],
            )
            .unwrap();
        let out = s.get_item(untitled).await;
        assert!(
            out.ok,
            "an untitled item is still readable: {}",
            out.message
        );
        assert_eq!(out.item.unwrap().title, "");
    }

    #[tokio::test]
    async fn get_item_truncates_an_enormous_payload_and_says_so() {
        let (store, s) = svc();
        let id = make_item_named(&store, "manuscript", "Long draft");
        let body = "x".repeat(MAX_PAYLOAD_BYTES * 2);
        store
            .update(
                uuid::Uuid::parse_str(&id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "body_content".into(),
                    Value::String(body),
                )],
            )
            .expect("write a huge body");

        let out = s.get_item(id).await;
        assert!(out.ok, "{}", out.message);
        assert!(out.truncated, "a 64 KiB payload must be cut");
        assert!(out.payload.len() <= MAX_PAYLOAD_BYTES);
        let note = out.note.expect("truncation must be announced");
        assert!(note.contains("truncated"), "{note}");
        assert!(
            serde_json::from_str::<serde_json::Value>(&out.payload).is_err(),
            "a truncated payload is a prefix; the note is what tells the caller"
        );
        // The envelope still arrives whole — the cap is on the payload only.
        assert_eq!(out.item.unwrap().title, "Long draft");
    }

    #[tokio::test]
    async fn get_item_truncation_cuts_on_a_character_boundary() {
        let (store, s) = svc();
        let id = make_item_named(&store, "manuscript", "Multibyte");
        store
            .update(
                uuid::Uuid::parse_str(&id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "body_content".into(),
                    // Four-byte characters, so a byte-exact cut lands mid-glyph
                    // for three offsets out of four.
                    Value::String("𝄞".repeat(MAX_PAYLOAD_BYTES)),
                )],
            )
            .unwrap();

        let out = s.get_item(id).await;
        assert!(out.truncated);
        // Reaching this line at all proves the cut was legal: an invalid slice
        // would have panicked inside the service.
        assert!(out.payload.is_char_boundary(out.payload.len()));
        assert!(out.payload.len() <= MAX_PAYLOAD_BYTES);
    }

    #[tokio::test]
    async fn get_item_fails_loudly_on_unknown_and_malformed_ids() {
        let (_store, s) = svc();
        let missing = s.get_item(uuid::Uuid::new_v4().to_string()).await;
        assert!(!missing.ok);
        assert!(missing.item.is_none());
        assert!(missing.payload.is_empty());
        assert!(missing.message.contains("not found"), "{}", missing.message);

        let malformed = s.get_item("not-a-uuid".into()).await;
        assert!(!malformed.ok);
        assert!(
            malformed.message.contains("invalid UUID"),
            "{}",
            malformed.message
        );
    }

    // ─── list_items ──────────────────────────────────────────────────────

    #[tokio::test]
    async fn list_items_pages_one_kind_newest_first() {
        let (store, s) = svc();
        let mut ids = Vec::new();
        for n in 0..5 {
            ids.push(make_item_named(&store, "figure", &format!("Panel {n}")));
        }
        make_item_named(&store, "manuscript", "Not a figure");

        // Touch them in a known order so `modified` is a known order.
        for id in &ids {
            store
                .update(
                    uuid::Uuid::parse_str(id).unwrap(),
                    vec![FieldMutation::SetStarred(true)],
                )
                .unwrap();
        }

        let first = s.list_items("figure".into(), 2, 0).await;
        assert!(first.ok, "{}", first.message);
        assert_eq!(first.total, 5, "total ignores the page window");
        assert_eq!(first.items.len(), 2);
        assert!(
            first.items.iter().all(|i| i.schema_ref == "figure"),
            "the manuscript must not leak into a figure browse: {:?}",
            first.items
        );

        // Paging is a partition: every row exactly once, no repeats.
        let second = s.list_items("figure".into(), 2, 2).await;
        let third = s.list_items("figure".into(), 2, 4).await;
        assert_eq!(third.items.len(), 1, "the tail page is short, not empty");
        let mut seen: Vec<String> = first
            .items
            .iter()
            .chain(second.items.iter())
            .chain(third.items.iter())
            .map(|i| i.id.clone())
            .collect();
        seen.sort();
        let mut expected = ids.clone();
        expected.sort();
        assert_eq!(seen, expected, "paging lost or duplicated a row");

        // Ordering is most-recently-modified first, and stable across calls.
        let all = s.list_items("figure".into(), 0, 0).await;
        let again = s.list_items("figure".into(), 0, 0).await;
        let order: Vec<&str> = all.items.iter().map(|i| i.id.as_str()).collect();
        let order_again: Vec<&str> = again.items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(order, order_again, "browse order must be deterministic");
        assert!(
            all.items.windows(2).all(|w| w[0].modified >= w[1].modified),
            "expected modified-desc, got {:?}",
            all.items.iter().map(|i| &i.modified).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn list_items_walks_every_kind_when_no_schema_is_named() {
        let (store, s) = svc();
        make_item_named(&store, "manuscript", "Draft");
        make_item_named(&store, "figure", "Panel");
        make_item_named(&store, "task", "Redo the fit");

        for every in ["", "any", "  ", "*"] {
            let out = s.list_items(every.into(), 0, 0).await;
            assert!(out.ok, "{every:?}: {}", out.message);
            assert_eq!(out.total, 3, "{every:?} must mean every kind");
            let mut kinds: Vec<&str> = out.items.iter().map(|i| i.schema_ref.as_str()).collect();
            kinds.sort();
            assert_eq!(kinds, vec!["figure", "manuscript", "task"]);
        }
    }

    #[tokio::test]
    async fn list_items_clamps_limits_and_offsets() {
        let (store, s) = svc();
        for n in 0..3 {
            make_item_named(&store, "task", &format!("Task {n}"));
        }

        // 0 and negatives mean "unspecified", never an error or an empty page.
        for limit in [0i64, -1, i64::MIN] {
            let out = s.list_items("task".into(), limit, 0).await;
            assert!(out.ok, "limit {limit}: {}", out.message);
            assert_eq!(out.items.len(), 3, "limit {limit}");
        }
        // A negative offset reads as the start.
        assert_eq!(s.list_items("task".into(), 10, -5).await.items.len(), 3);
        // The ceiling binds without erroring.
        let huge = s.list_items("task".into(), i64::MAX, 0).await;
        assert!(huge.ok, "{}", huge.message);
        assert_eq!(huge.items.len(), 3);
        // Past the end is an empty page, not a failure — and `total` still
        // reports the truth, which is how a caller knows it overshot.
        let past = s.list_items("task".into(), 10, 99).await;
        assert!(past.ok, "{}", past.message);
        assert!(past.items.is_empty());
        assert_eq!(past.total, 3);
    }

    #[tokio::test]
    async fn list_items_reports_an_unknown_kind_as_empty_not_broken() {
        let (store, s) = svc();
        make_item_named(&store, "manuscript", "Draft");
        let out = s.list_items("no-such-kind".into(), 0, 0).await;
        assert!(out.ok, "{}", out.message);
        assert!(out.items.is_empty());
        assert_eq!(out.total, 0);
    }

    #[tokio::test]
    async fn list_items_omits_payloads_but_keeps_the_triage_envelope() {
        let (store, s) = svc();
        let id = make_item_named(&store, "task", "Recalibrate");
        store
            .update(
                uuid::Uuid::parse_str(&id).unwrap(),
                vec![
                    FieldMutation::SetStarred(true),
                    FieldMutation::AddTag("lab/urgent".into()),
                    FieldMutation::SetPayload("status".into(), Value::String("archived".into())),
                ],
            )
            .unwrap();

        let out = s.list_items("task".into(), 0, 0).await;
        let row = &out.items[0];
        assert!(row.starred);
        assert_eq!(row.tags, vec!["lab/urgent"]);
        assert_eq!(
            row.status.as_deref(),
            Some("archived"),
            "a browse that hid archived rows would make its own total a lie"
        );
    }
}
