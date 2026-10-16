//! `TriageService` moved to koine (`koine_triage::service`,
//! docs/plan-koine-kit-moves.md KM2): star, flag, tag and status over any item
//! (ADR-0022 D5), over the store port. This module keeps the old path.
//!
//! The verbs (`triage-service_set-starred`, `_set-flag`, `_add-tag`,
//! `_remove-tag`, `_set-status`) register from koine-triage's inventory.
//! Its default deployment reads the process store
//! (`koine_store::process::acquire_or_stand_in`), which a host that has
//! called [`crate::register_process_ports`] (every `set_store_path` /
//! `install_store` does) answers with the suite's SQLite store.

pub use koine_triage::service::*;

/// The service over the suite's SQLite store (the kernel and the service are
/// tested over the memory and directory stores in koine-triage).
#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{make_item, test_store};
    use impress_core::sqlite_store::SqliteItemStore;
    use impress_core::store::ItemStore;
    use impress_core::triage_ops;

    fn item(store: &SqliteItemStore, id: &str) -> impress_core::item::Item {
        store
            .get(uuid::Uuid::parse_str(id).unwrap())
            .unwrap()
            .expect("item present")
    }

    #[tokio::test]
    async fn star_round_trip() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());
        let id = make_item(&store, "manuscript");

        let on = s.set_starred(id.clone(), true).await;
        assert!(on.ok, "{}", on.message);
        assert_eq!(on.id, id);
        assert!(item(&store, &id).is_starred);

        assert!(s.set_starred(id.clone(), false).await.ok);
        assert!(!item(&store, &id).is_starred);
    }

    #[tokio::test]
    async fn flag_set_and_cleared() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());
        let id = make_item(&store, "figure");

        assert!(s.set_flag(id.clone(), Some("red".into())).await.ok);
        assert_eq!(
            item(&store, &id).flag.map(|f| f.color),
            Some("red".to_string())
        );

        let cleared = s.set_flag(id.clone(), None).await;
        assert!(cleared.ok);
        assert!(cleared.message.contains("Cleared"));
        assert!(item(&store, &id).flag.is_none());
    }

    #[tokio::test]
    async fn tags_added_and_removed() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());
        let id = make_item(&store, "email-message");

        assert!(s.add_tag(id.clone(), "reading/queue".into()).await.ok);
        assert!(item(&store, &id).tags.contains(&"reading/queue".into()));

        // Idempotent add.
        assert!(s.add_tag(id.clone(), "reading/queue".into()).await.ok);
        assert_eq!(item(&store, &id).tags.len(), 1);

        assert!(s.remove_tag(id.clone(), "reading/queue".into()).await.ok);
        assert!(item(&store, &id).tags.is_empty());
        // Removing an absent tag is a no-op, not a failure.
        assert!(s.remove_tag(id.clone(), "never/applied".into()).await.ok);
    }

    #[tokio::test]
    async fn status_uses_the_reserved_values_and_free_text_alike() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());
        let id = make_item(&store, "manuscript");

        for value in [
            triage_ops::STATUS_DISMISSED,
            triage_ops::STATUS_ARCHIVED,
            "in-revision",
        ] {
            let set = s.set_status(id.clone(), Some(value.into())).await;
            assert!(set.ok, "{}", set.message);
            assert_eq!(
                triage_ops::status(&*store, &id).unwrap().as_deref(),
                Some(value)
            );
        }

        let cleared = s.set_status(id.clone(), None).await;
        assert!(cleared.ok);
        assert_eq!(triage_ops::status(&*store, &id).unwrap(), None);
    }

    /// The whole point of a generic triage service: one tool, every kind.
    #[tokio::test]
    async fn every_record_kind_can_be_triaged() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());
        for schema in [
            "imbib/bibliography-entry",
            "manuscript",
            "figure",
            "email-message",
            "task",
            "agent-run",
        ] {
            let id = make_item(&store, schema);
            assert!(s.set_starred(id.clone(), true).await.ok, "{schema} star");
            assert!(
                s.set_flag(id.clone(), Some("blue".into())).await.ok,
                "{schema} flag"
            );
            assert!(
                s.add_tag(id.clone(), "triage".into()).await.ok,
                "{schema} tag"
            );
            let it = item(&store, &id);
            assert!(it.is_starred && it.flag.is_some() && !it.tags.is_empty());
        }
    }

    #[tokio::test]
    async fn bad_ids_fail_loudly_rather_than_silently() {
        let store = test_store();
        let s = DefaultTriageService::with_store(store.clone());

        let malformed = s.set_starred("not-a-uuid".into(), true).await;
        assert!(!malformed.ok);
        assert!(
            malformed.message.contains("invalid UUID"),
            "{}",
            malformed.message
        );

        let missing = uuid::Uuid::new_v4().to_string();
        let absent = s.add_tag(missing.clone(), "x".into()).await;
        assert!(!absent.ok);
        assert!(absent.message.contains("not found"), "{}", absent.message);

        let empty_tag = s
            .add_tag(make_item(&store, "manuscript"), "  ".into())
            .await;
        assert!(!empty_tag.ok);
    }
}
