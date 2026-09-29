//! Scratch fixtures for the first alphabetical half of ImbibLibraryService.

use std::path::Path;
use std::sync::Arc;

use impress_core::collection_ops::{self, IMBIB_COLLECTION};
use impress_core::item::{FlagState, ItemId, Value as ItemValue};
use impress_core::query::ItemQuery;
use impress_core::schema::refs;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use serde_json::Value;

const PREFIX: &str = "5c000000-0000-4000-8000-0000000000";

fn id(suffix: &str) -> String {
    format!("{PREFIX}{suffix}")
}

fn uuid(suffix: &str) -> Result<ItemId, String> {
    ItemId::parse_str(&id(suffix)).map_err(|e| e.to_string())
}

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    match (verb, example) {
        ("imbib-library-service_list-libraries", "reading-library-list") => {
            library(store, "67", "G3 listed library", false, false)?;
            collection(store, "b1", "G3 listed collection one", "67")?;
            collection(store, "b2", "G3 listed collection two", "67")?;
            // This read-only remote library has a distinct schema and must
            // not leak into the local-library list.
            let item_id = uuid("b3")?;
            reset(store, item_id)?;
            let mut remote = super::seed_item(item_id, refs::IMBIB_SCIX_LIBRARY.as_str(), None);
            remote.payload.insert(
                "remote_id".into(),
                ItemValue::String("g3-read-only-remote".into()),
            );
            remote
                .payload
                .insert("name".into(), ItemValue::String("G3 read-only SciX".into()));
            remote
                .payload
                .insert("permission_level".into(), ItemValue::String("read".into()));
            store.insert(remote).map_err(|e| e.to_string())?;
        }
        ("imbib-library-service_export-ris", "representative-ris-export") => {
            library(store, "c1", "G3 RIS export library", false, false)?;
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3RIS2026",
                Some(uuid("c1")?),
            )?;
            let mut item = super::seed_item(
                uuid("c2")?,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY.as_str(),
                Some(uuid("c1")?),
            );
            reset(store, item.id)?;
            for (key, value) in [
                ("cite_key", "G3RIS2026"),
                ("entry_type", "article"),
                ("author_text", "Doe, Jane"),
                ("title", "RIS parity paper"),
                ("journal", "Research Journal"),
                ("volume", "12"),
                ("number", "3"),
                ("pages", "100-110"),
                ("doi", "10.5555/g3-ris"),
                ("abstract_text", "Representative abstract"),
                ("url", "https://example.org/g3-ris"),
                ("publisher", "Example Press"),
                ("address", "Boston"),
                ("issn", "1234-5678"),
                ("note", "G3 export note"),
                ("series", "Research Series"),
                ("edition", "2"),
            ] {
                item.payload
                    .insert(key.into(), ItemValue::String(value.into()));
            }
            item.payload.insert("year".into(), ItemValue::Int(2026));
            item.payload.insert(
                "keywords".into(),
                ItemValue::Array(vec![
                    ItemValue::String("alpha".into()),
                    ItemValue::String("beta".into()),
                ]),
            );
            item.payload.insert(
                "extra_fields".into(),
                ItemValue::Object(
                    [("language".into(), ItemValue::String("en".into()))]
                        .into_iter()
                        .collect(),
                ),
            );
            store.insert(item).map_err(|e| e.to_string())?;
        }
        ("imbib-library-service_sidebar-view", "reading-sidebar") => {
            library(store, "84", "G3 sidebar library", false, false)?;
            paper(store, "8a", "84", "G3Sidebar2026", "G3 sidebar paper", None)?;
        }
        ("imbib-library-service_set-library-default", "make-reading-default") => {
            library(store, "81", "G3 new default", false, false)?;
        }
        ("imbib-library-service_list-collections", "library-collections") => {
            library(store, "61", "G3 collection listing", false, false)?;
            collection(store, "62", "G3 listed collection", "61")?;
        }
        ("imbib-library-service_list-collection-members", "collection-paper") => {
            library(store, "63", "G3 member library", false, false)?;
            collection(store, "64", "G3 member collection", "63")?;
            paper(store, "65", "63", "G3Member2026", "G3 member paper", None)?;
            member(store, "64", "65")?;
        }
        ("imbib-library-service_remove-from-collection", "unfile-paper") => {
            library(store, "7a", "G3 unfile library", false, false)?;
            collection(store, "7b", "G3 unfile collection", "7a")?;
            paper(store, "7c", "7a", "G3Unfile2026", "G3 unfile paper", None)?;
            member(store, "7b", "7c")?;
        }
        ("imbib-library-service_update-library-members", "file-into-library") => {
            library(store, "d0", "G3 library member source", false, false)?;
            library(store, "d1", "G3 library member destination", false, false)?;
            paper(
                store,
                "d2",
                "d0",
                "G3LibraryMember2026",
                "G3 library member paper",
                None,
            )?;
        }
        ("imbib-library-service_list-assignments", "library-assignments") => {
            library(store, "d3", "G3 assignment library", false, false)?;
            paper(
                store,
                "d6",
                "d3",
                "G3Assigned2026",
                "G3 assigned paper",
                None,
            )?;
            assignment(store, "da", "d6", "G3 listed assignee")?;
        }
        ("imbib-library-service_create-assignment", "assign-paper") => {
            library(store, "d4", "G3 create assignment library", false, false)?;
            paper(
                store,
                "d5",
                "d4",
                "G3CreateAssign2026",
                "G3 create assignment paper",
                None,
            )?;
        }
        ("imbib-library-service_delete-assignment", "drop-assignment") => {
            library(store, "de", "G3 delete assignment library", false, false)?;
            paper(
                store,
                "df",
                "de",
                "G3DeleteAssign2026",
                "G3 delete assignment paper",
                None,
            )?;
            assignment(store, "d7", "df", "G3 deleted assignee")?;
        }
        ("imbib-library-service_list-library-activity", "library-activity") => {
            library(store, "d8", "G3 activity library", false, false)?;
            activity(store, "db", "d8", "imported")?;
        }
        ("imbib-library-service_update-collection-members", "file-existing-paper") => {
            library(store, "c0", "G3 membership library", false, false)?;
            collection(store, "c1", "G3 membership collection", "c0")?;
            paper(
                store,
                "c2",
                "c0",
                "G3Membership2026",
                "G3 membership paper",
                None,
            )?;
        }
        ("imbib-library-service_purge-dismissed-from-collection", "unfile-dismissed-paper") => {
            library(store, "89", "G3 dismissal library", false, false)?;
            collection(store, "6f", "G3 dismissal collection", "89")?;
            paper(
                store,
                "70",
                "89",
                "G3Purged2026",
                "G3 dismissed member",
                Some("10.5555/g3-purge"),
            )?;
            dismissed(store, "71", "10.5555/g3-purge")?;
            member(store, "6f", "70")?;
        }
        ("imbib-library-service_list-publications", "list-scratch-paper") => {
            library(store, "88", "G3 scratch library", false, false)?;
            paper(store, "6b", "88", "G3Listed2026", "G3 listed paper", None)?;
        }
        ("imbib-library-service_query-publications", "project-papers") => {
            library(store, "72", "G3 queried library", false, false)?;
            paper(store, "73", "72", "G3Query2026", "G3 queried paper", None)?;
        }
        ("imbib-library-service_query-recent", "recent-project-paper") => {
            library(store, "74", "G3 recent library", false, false)?;
            paper(store, "75", "74", "G3Recent2026", "G3 recent paper", None)?;
        }
        ("imbib-library-service_query-starred", "starred-project-paper") => {
            library(store, "76", "G3 starred query library", false, false)?;
            paper_with_status(store, "77", "76", false, true, None)?;
        }
        ("imbib-library-service_query-unread", "unread-project-paper") => {
            library(store, "78", "G3 unread query library", false, false)?;
            paper_with_status(store, "79", "78", false, false, None)?;
        }
        (
            "imbib-library-service_search-publications",
            "find-unique-spectrum" | "filtered-project-spectrum" | "filtered-collection-spectrum",
        ) => {
            library(store, "88", "G3 search library", false, false)?;
            paper(
                store,
                "7f",
                "88",
                "G3UniqueSpectrum2026",
                "G3 Unique Spectrum",
                None,
            )?;
            if example == "filtered-collection-spectrum" {
                collection(store, "89", "G3 search collection", "88")?;
                member(store, "89", "7f")?;
            }
        }
        ("imbib-library-service_set-read", "finish-reading") => {
            library(store, "88", "G3 status library", false, false)?;
            paper_with_status(store, "82", "88", false, false, None)?;
        }
        ("imbib-library-service_set-starred", "star-project-paper") => {
            library(store, "88", "G3 status library", false, false)?;
            paper_with_status(store, "83", "88", false, false, None)?;
        }
        ("imbib-library-service_set-flag", "flag-for-review") => {
            library(store, "88", "G3 status library", false, false)?;
            paper_with_status(store, "80", "88", false, false, None)?;
        }
        ("imbib-library-service_move-publications", "move-to-project") => {
            library(store, "6c", "G3 move source", false, false)?;
            library(store, "6d", "G3 move destination", false, false)?;
            paper(store, "6e", "6c", "G3Moved2026", "G3 moved paper", None)?;
        }
        ("imbib-library-service_is-paper-dismissed", "known-dismissed-doi") => {
            dismissed(store, "60", "10.5555/g3-known-dismissed")?;
        }
        ("imbib-library-service_list-dismissed-papers", "dismissed-list") => {
            dismissed(store, "66", "10.5555/g3-listed-dismissed")?;
        }
        ("imbib-library-service_list-muted-items", "active-mute-rules") => {
            muted(store, "6a", "author", "G3 muted author")?;
        }
        ("imbib-library-service_import-papers", "import-fetched-record") => {
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3SearchRecord2026",
                None,
            )?;
            library(store, "85", "G3 search imports", false, false)?;
        }
        ("imbib-library-service_list-linked-files", "paper-attachments") => {
            library(store, "88", "G3 attachment library", false, false)?;
            paper(
                store,
                "68",
                "88",
                "G3Attachment2026",
                "G3 attachment paper",
                None,
            )?;
            linked_file(store, "69", "68", "g3-attachment.pdf", true)?;
        }
        ("imbib-library-service_retention-cleanup", "expire-old-search") => {
            library(store, "86", "G3 exploration library", false, false)?;
            smart_search(store, "87", "86")?;
        }
        ("imbib-library-service_count-publications", "count-scratch-paper") => {
            library(store, "52", "G3 count library", false, false)?;
            paper(store, "53", "52", "G3Count2026", "G3 counted paper", None)?;
        }
        ("imbib-library-service_count-unread", "count-unread-in-library") => {
            library(store, "50", "G3 unread library", false, false)?;
            paper_with_status(store, "54", "50", false, false, None)?;
            paper_with_status(store, "55", "50", true, false, None)?;
        }
        ("imbib-library-service_count-starred", "count-starred-in-library") => {
            library(store, "51", "G3 starred library", false, false)?;
            paper_with_status(store, "56", "51", false, true, None)?;
            paper_with_status(store, "57", "51", false, false, None)?;
        }
        ("imbib-library-service_count-flagged", "count-blue-flags") => {
            library(store, "58", "G3 flagged library", false, false)?;
            paper_with_status(store, "59", "58", false, false, Some("g3-blue"))?;
            paper_with_status(store, "5a", "58", false, false, Some("red"))?;
        }
        ("imbib-library-service_create-library", "new-project-library") => {
            reset_matching(
                store,
                refs::IMBIB_LIBRARY,
                "name",
                "G3 reading project",
                None,
            )?;
        }
        ("imbib-library-service_delete-library-undoable", "remove-empty-library") => {
            library(store, "0a", "G3 disposable library", false, false)?;
        }
        ("imbib-library-service_delete-libraries", "delete-library-batch") => {
            library(store, "0d", "G3 batch disposable one", false, false)?;
            library(store, "0e", "G3 batch disposable two", false, false)?;
        }
        ("imbib-library-service_get-default-library", "project-default") => {
            library(store, "0b", "G3 default library", true, false)?;
        }
        ("imbib-library-service_get-inbox-library", "inbox-library") => {
            library(store, "0c", "G3 Inbox", false, true)?;
        }
        ("imbib-library-service_create-collection", "manual-collection") => {
            reset_matching(store, refs::IMBIB_COLLECTION, "name", "G3 methods", None)?;
            library(store, "10", "G3 collection library", false, false)?;
        }
        ("imbib-library-service_add-to-collection", "file-paper") => {
            library(store, "0d", "G3 filing library", false, false)?;
            collection(store, "11", "G3 papers", "0d")?;
            paper(store, "12", "0d", "G3File2026", "G3 filed paper", None)?;
        }
        ("imbib-library-service_get-publication", "paper-summary") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(
                store,
                "20",
                "1f",
                "G3Spectra2026",
                "G3 stellar spectra",
                None,
            )?;
        }
        ("imbib-library-service_get-publication-detail", "paper-metadata") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "21", "1f", "G3Detail2026", "G3 paper detail", None)?;
        }
        ("imbib-library-service_delete-publications-undoable", "delete-scratch-paper") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(
                store,
                "22",
                "1f",
                "G3Delete2026",
                "G3 disposable paper",
                None,
            )?;
        }
        ("imbib-library-service_duplicate-publications", "copy-paper-to-project") => {
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3Copy2026",
                Some(uuid("24")?),
            )?;
            library(store, "26", "G3 source library", false, false)?;
            library(store, "24", "G3 destination library", false, false)?;
            paper(store, "23", "26", "G3Copy2026", "G3 paper to copy", None)?;
        }
        ("imbib-library-service_deduplicate-library", "merge-same-doi") => {
            library(store, "25", "G3 dedup library", false, false)?;
            paper(
                store,
                "27",
                "25",
                "G3DuplicateA",
                "G3 first paper",
                Some("10.5555/g3-same"),
            )?;
            paper(
                store,
                "28",
                "25",
                "G3DuplicateB",
                "G3 second paper",
                Some("10.5555/g3-same"),
            )?;
        }
        ("imbib-library-service_dismiss-paper", "dismiss-known-doi") => {
            reset_matching(
                store,
                refs::IMBIB_DISMISSED_PAPER,
                "doi",
                "10.5555/g3-dismiss",
                None,
            )?;
        }
        ("imbib-library-service_create-muted-item", "mute-keyword") => {
            reset_matching(
                store,
                refs::IMBIB_MUTED_ITEM,
                "value",
                "G3 irrelevant topic",
                None,
            )?;
        }
        ("imbib-library-service_import-bibtex", "import-one-entry") => {
            reset_matching(
                store,
                refs::IMBIB_BIBLIOGRAPHY_ENTRY,
                "cite_key",
                "G3Imported2026",
                None,
            )?;
            library(store, "30", "G3 BibTeX library", false, false)?;
        }
        ("imbib-library-service_export-bibtex", "export-cite-key") => {
            library(store, "31", "G3 export library", false, false)?;
            paper(store, "33", "31", "G3Export2026", "G3 exported paper", None)?;
        }
        ("imbib-library-service_export-all-bibtex", "export-project-library") => {
            library(store, "31", "G3 export library", false, false)?;
            paper(
                store,
                "32",
                "31",
                "G3AllExport2026",
                "G3 all-export paper",
                None,
            )?;
        }
        ("imbib-library-service_count-pdfs", "one-pdf") => {
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "40", "1f", "G3Pdf2026", "G3 PDF paper", None)?;
            linked_file(store, "42", "40", "counted.pdf", true)?;
        }
        ("imbib-library-service_add-linked-file", "link-local-pdf") => {
            reset_matching(
                store,
                refs::IMBIB_LINKED_FILE,
                "filename",
                "paper.pdf",
                Some(uuid("41")?),
            )?;
            library(store, "1f", "G3 paper library", false, false)?;
            paper(store, "41", "1f", "G3Link2026", "G3 linked paper", None)?;
            let dir = root.join("library");
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            std::fs::write(dir.join("paper.pdf"), b"%PDF-1.4\nG3test")
                .map_err(|e| e.to_string())?;
        }
        _ => {}
    }
    Ok(())
}

fn reset(store: &SqliteItemStore, item_id: ItemId) -> Result<(), String> {
    if store.get(item_id).map_err(|e| e.to_string())?.is_some() {
        store.delete(item_id).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn reset_matching(
    store: &SqliteItemStore,
    schema: impress_core::SchemaRef,
    field: &str,
    value: &str,
    parent: Option<ItemId>,
) -> Result<(), String> {
    let rows = store
        .query(&ItemQuery {
            schema: Some(schema),
            ..Default::default()
        })
        .map_err(|e| e.to_string())?;
    for row in rows {
        if row.payload.get(field) == Some(&ItemValue::String(value.into()))
            && parent.is_none_or(|id| row.parent == Some(id))
        {
            store.delete(row.id).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn library(
    store: &SqliteItemStore,
    suffix: &str,
    name: &str,
    default: bool,
    inbox: bool,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(item_id, refs::IMBIB_LIBRARY.as_str(), None);
    item.payload
        .insert("name".into(), ItemValue::String(name.into()));
    item.payload
        .insert("is_default".into(), ItemValue::Bool(default));
    item.payload
        .insert("is_inbox".into(), ItemValue::Bool(inbox));
    item.payload
        .insert("is_system".into(), ItemValue::Bool(false));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn collection(
    store: &SqliteItemStore,
    suffix: &str,
    name: &str,
    library_suffix: &str,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_COLLECTION.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload
        .insert("name".into(), ItemValue::String(name.into()));
    item.payload
        .insert("is_smart".into(), ItemValue::Bool(false));
    item.payload.insert("sort_order".into(), ItemValue::Int(0));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn assignment(
    store: &SqliteItemStore,
    suffix: &str,
    paper_suffix: &str,
    assignee: &str,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_ASSIGNMENT.as_str(),
        Some(uuid(paper_suffix)?),
    );
    item.payload
        .insert("assignee_name".into(), ItemValue::String(assignee.into()));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn activity(
    store: &SqliteItemStore,
    suffix: &str,
    library_suffix: &str,
    activity_type: &str,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_ACTIVITY_RECORD.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload.insert(
        "activity_type".into(),
        ItemValue::String(activity_type.into()),
    );
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn paper(
    store: &SqliteItemStore,
    suffix: &str,
    library_suffix: &str,
    cite_key: &str,
    title: &str,
    doi: Option<&str>,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_BIBLIOGRAPHY_ENTRY.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload
        .insert("cite_key".into(), ItemValue::String(cite_key.into()));
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    item.payload
        .insert("title".into(), ItemValue::String(title.into()));
    item.payload.insert("year".into(), ItemValue::Int(2026));
    if let Some(doi) = doi {
        item.payload
            .insert("doi".into(), ItemValue::String(doi.into()));
    }
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn paper_with_status(
    store: &SqliteItemStore,
    suffix: &str,
    library_suffix: &str,
    read: bool,
    starred: bool,
    flag: Option<&str>,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_BIBLIOGRAPHY_ENTRY.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload.insert(
        "cite_key".into(),
        ItemValue::String(format!("G3Status{suffix}2026")),
    );
    item.payload.insert(
        "title".into(),
        ItemValue::String(format!("G3 status paper {suffix}")),
    );
    item.payload
        .insert("entry_type".into(), ItemValue::String("article".into()));
    item.is_read = read;
    item.is_starred = starred;
    item.flag = flag.map(|color| FlagState {
        color: color.into(),
        style: None,
        length: None,
    });
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn linked_file(
    store: &SqliteItemStore,
    suffix: &str,
    paper_suffix: &str,
    filename: &str,
    pdf: bool,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_LINKED_FILE.as_str(),
        Some(uuid(paper_suffix)?),
    );
    item.payload
        .insert("filename".into(), ItemValue::String(filename.into()));
    item.payload.insert("is_pdf".into(), ItemValue::Bool(pdf));
    item.payload.insert("file_size".into(), ItemValue::Int(15));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn member(
    store: &SqliteItemStore,
    collection_suffix: &str,
    paper_suffix: &str,
) -> Result<(), String> {
    collection_ops::add_members(
        store,
        &IMBIB_COLLECTION,
        &id(collection_suffix),
        &[id(paper_suffix)],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn dismissed(store: &SqliteItemStore, suffix: &str, doi: &str) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(item_id, refs::IMBIB_DISMISSED_PAPER.as_str(), None);
    item.payload
        .insert("doi".into(), ItemValue::String(doi.into()));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn muted(
    store: &SqliteItemStore,
    suffix: &str,
    mute_type: &str,
    value: &str,
) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(item_id, refs::IMBIB_MUTED_ITEM.as_str(), None);
    item.payload
        .insert("mute_type".into(), ItemValue::String(mute_type.into()));
    item.payload
        .insert("value".into(), ItemValue::String(value.into()));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

fn smart_search(store: &SqliteItemStore, suffix: &str, library_suffix: &str) -> Result<(), String> {
    let item_id = uuid(suffix)?;
    reset(store, item_id)?;
    let mut item = super::seed_item(
        item_id,
        refs::IMBIB_SMART_SEARCH.as_str(),
        Some(uuid(library_suffix)?),
    );
    item.payload.insert(
        "name".into(),
        ItemValue::String("G3 expired exploration".into()),
    );
    item.payload
        .insert("query".into(), ItemValue::String("expired".into()));
    item.payload
        .insert("last_executed".into(), ItemValue::Int(0));
    store.insert(item).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn verify(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    _args: &Value,
    result: &Value,
) -> Result<(), String> {
    match (verb, example) {
        ("imbib-library-service_list-libraries", "reading-library-list") => {
            let rows = result.as_array().ok_or("expected a list of libraries")?;
            let row = rows
                .iter()
                .find(|row| row["id"] == id("67"))
                .ok_or("result omitted scratch library")?;
            let stored = load(store, &id("67"))?.ok_or("scratch library disappeared")?;
            let actual_collection_count =
                collection_ops::list_tree_in(store, &IMBIB_COLLECTION, Some(&id("67")))
                    .map_err(|e| e.to_string())?
                    .len();
            if stored.payload.get("name")
                != Some(&ItemValue::String(
                    row["name"].as_str().unwrap_or_default().into(),
                ))
                || row["collection_count"].as_u64() != Some(actual_collection_count as u64)
                || actual_collection_count != 2
                || row["is_default"] != false
                || row["is_inbox"] != false
                || row["publication_count"] != 0
                || row["can_edit"] != true
            {
                return Err(format!(
                    "generated library metadata did not match scratch store: {row}"
                ));
            }
            if rows.iter().any(|row| row["id"] == id("b3")) {
                return Err("read-only SciX library leaked into local library list".into());
            }
            let remote = load(store, &id("b3"))?.ok_or("read-only SciX fixture disappeared")?;
            if remote.schema != refs::IMBIB_SCIX_LIBRARY
                || remote.payload.get("permission_level") != Some(&ItemValue::String("read".into()))
            {
                return Err("read-only SciX permission fixture was not persisted".into());
            }
        }
        ("imbib-library-service_export-ris", "representative-ris-export") => {
            let rows = store
                .query(&ItemQuery {
                    schema: Some(refs::IMBIB_BIBLIOGRAPHY_ENTRY),
                    ..Default::default()
                })
                .map_err(|e| e.to_string())?;
            if !rows.iter().any(|row| {
                row.payload.get("cite_key") == Some(&ItemValue::String("G3RIS2026".into()))
                    && row.parent == Some(uuid("c1").expect("fixed fixture UUID"))
            }) {
                return Err("representative RIS paper was not persisted in scratch library".into());
            }
        }
        ("imbib-library-service_sidebar-view", "reading-sidebar") => {
            require_row(&result["libraries"], &id("84"))?;
        }
        ("imbib-library-service_set-library-default", "make-reading-default") => {
            let row = load(store, &id("81"))?.ok_or("default library disappeared")?;
            if row.payload.get("is_default") != Some(&ItemValue::Bool(true)) {
                return Err("library was not made default".into());
            }
        }
        ("imbib-library-service_list-collections", "library-collections") => {
            require_row(result, &id("62"))?;
        }
        ("imbib-library-service_list-collection-members", "collection-paper") => {
            require_row(result, &id("65"))?;
        }
        ("imbib-library-service_remove-from-collection", "unfile-paper") => {
            require_unfiled(store, "7b", "7c")?;
        }
        ("imbib-library-service_update-library-members", "file-into-library") => {
            let row = load(store, &id("d2"))?.ok_or("moved paper disappeared")?;
            if row.parent != Some(uuid("d1")?) {
                return Err("paper was not moved into the destination library".into());
            }
        }
        ("imbib-library-service_list-assignments", "library-assignments") => {
            require_row(result, &id("da"))?;
        }
        ("imbib-library-service_create-assignment", "assign-paper") => {
            let created = result["id"].as_str().ok_or("assignment id missing")?;
            let row = load(store, created)?.ok_or("assignment was not persisted")?;
            if row.parent != Some(uuid("d5")?)
                || row.payload.get("assignee_name")
                    != Some(&ItemValue::String("G3 assignee".into()))
            {
                return Err("assignment was not stored on the publication".into());
            }
        }
        ("imbib-library-service_delete-assignment", "drop-assignment") => {
            if load(store, &id("d7"))?.is_some() {
                return Err("assignment row was not deleted".into());
            }
        }
        ("imbib-library-service_list-library-activity", "library-activity") => {
            require_row(result, &id("db"))?;
        }
        ("imbib-library-service_update-collection-members", "file-existing-paper") => {
            let assigned = result["assigned"]
                .as_array()
                .ok_or("missing assigned identifiers")?;
            let not_found = result["not_found"]
                .as_array()
                .ok_or("missing not_found identifiers")?;
            if assigned != &[Value::String("G3Membership2026".into())]
                || not_found != &[Value::String("missing-G3".into())]
            {
                return Err("collection membership result changed input-order outcomes".into());
            }
            let members =
                collection_ops::list_members(store, &IMBIB_COLLECTION, &uuid("c1")?.to_string())
                    .map_err(|e| e.to_string())?;
            let paper_id = uuid("c2")?;
            if !members.iter().any(|member| member.id == paper_id) {
                return Err(
                    "service reported assignment without persisting the member edge".into(),
                );
            }
        }
        ("imbib-library-service_purge-dismissed-from-collection", "unfile-dismissed-paper") => {
            require_unfiled(store, "6f", "70")?;
        }
        ("imbib-library-service_list-publications", "list-scratch-paper") => {
            require_row(result, &id("6b"))?;
        }
        ("imbib-library-service_query-publications", "project-papers") => {
            require_row(result, &id("73"))?;
        }
        ("imbib-library-service_query-recent", "recent-project-paper") => {
            require_row(result, &id("75"))?;
        }
        ("imbib-library-service_query-starred", "starred-project-paper") => {
            require_row(result, &id("77"))?;
        }
        ("imbib-library-service_query-unread", "unread-project-paper") => {
            require_row(result, &id("79"))?;
        }
        (
            "imbib-library-service_search-publications",
            "find-unique-spectrum" | "filtered-project-spectrum" | "filtered-collection-spectrum",
        ) => {
            require_row(result, &id("7f"))?;
        }
        ("imbib-library-service_set-read", "finish-reading") => {
            let row = load(store, &id("82"))?.ok_or("read paper disappeared")?;
            if !row.is_read {
                return Err("paper was not marked read".into());
            }
        }
        ("imbib-library-service_set-starred", "star-project-paper") => {
            let row = load(store, &id("83"))?.ok_or("starred paper disappeared")?;
            if !row.is_starred {
                return Err("paper was not starred".into());
            }
        }
        ("imbib-library-service_set-flag", "flag-for-review") => {
            let row = load(store, &id("80"))?.ok_or("flagged paper disappeared")?;
            if row.flag.as_ref().map(|f| f.color.as_str()) != Some("orange") {
                return Err("paper was not flagged orange".into());
            }
        }
        ("imbib-library-service_move-publications", "move-to-project") => {
            let row = load(store, &id("6e"))?.ok_or("moved paper disappeared")?;
            if row.parent != Some(uuid("6d")?) {
                return Err("paper was not moved to destination library".into());
            }
        }
        ("imbib-library-service_list-dismissed-papers", "dismissed-list") => {
            require_row(result, &id("66"))?;
        }
        ("imbib-library-service_list-muted-items", "active-mute-rules") => {
            require_row(result, &id("6a"))?;
        }
        ("imbib-library-service_import-papers", "import-fetched-record") => {
            let ids = result["imported_ids"]
                .as_array()
                .ok_or("missing imported IDs")?;
            if ids.len() != 1 {
                return Err(format!(
                    "expected one imported search result; ImportSummary was {result}"
                ));
            }
            let row = load(store, ids[0].as_str().ok_or("import ID is not text")?)?
                .ok_or("imported search result not persisted")?;
            if row.parent != Some(uuid("85")?)
                || row.payload.get("cite_key")
                    != Some(&ItemValue::String("G3SearchRecord2026".into()))
            {
                return Err("search result was not imported into its library".into());
            }
        }
        ("imbib-library-service_list-linked-files", "paper-attachments") => {
            require_row(result, &id("69"))?;
        }
        ("imbib-library-service_retention-cleanup", "expire-old-search") => {
            if load(store, &id("87"))?.is_some() {
                return Err("expired exploration search survived cleanup".into());
            }
        }
        ("imbib-library-service_count-publications", "count-scratch-paper") => {
            let count = store
                .count(&ItemQuery {
                    schema: Some(refs::IMBIB_BIBLIOGRAPHY_ENTRY),
                    ..Default::default()
                })
                .map_err(|e| e.to_string())?;
            if count == 0
                || result.as_u64() != Some(count as u64)
                || load(store, &id("53"))?.is_none()
            {
                return Err("scratch paper was omitted from publication count".into());
            }
        }
        ("imbib-library-service_create-library", "new-project-library") => {
            let new_id = result["id"]
                .as_str()
                .ok_or("create-library returned no ID")?;
            let row = load(store, new_id)?.ok_or("new library not persisted")?;
            if row.schema != refs::IMBIB_LIBRARY {
                return Err("new row is not a library".into());
            }
        }
        ("imbib-library-service_delete-library-undoable", "remove-empty-library") => {
            if load(store, &id("0a"))?.is_some() {
                return Err("library survived deletion".into());
            }
        }
        ("imbib-library-service_delete-libraries", "delete-library-batch") => {
            if load(store, &id("0d"))?.is_some() || load(store, &id("0e"))?.is_some() {
                return Err("one or more batch libraries survived deletion".into());
            }
        }
        ("imbib-library-service_create-collection", "manual-collection") => {
            let new_id = result["id"]
                .as_str()
                .ok_or("create-collection returned no ID")?;
            let row = load(store, new_id)?.ok_or("new collection not persisted")?;
            // The legacy response currently maps the collection tree parent to
            // `library_id`, so a root collection reports null. The owning
            // library is stored in the envelope parent and checked here.
            if row.schema != refs::IMBIB_COLLECTION || row.parent != Some(uuid("10")?) {
                return Err("collection was not filed in its library".into());
            }
        }
        ("imbib-library-service_add-to-collection", "file-paper") => {
            let members = collection_ops::list_members(store, &IMBIB_COLLECTION, &id("11"))
                .map_err(|e| e.to_string())?;
            if members.len() != 1 || members[0].id != uuid("12")? {
                return Err("paper was not filed into the collection".into());
            }
        }
        ("imbib-library-service_delete-publications-undoable", "delete-scratch-paper") => {
            if load(store, &id("22"))?.is_some() {
                return Err("paper survived deletion".into());
            }
        }
        ("imbib-library-service_duplicate-publications", "copy-paper-to-project") => {
            let copies = result.as_array().ok_or("copy result was not an array")?;
            if copies.len() != 1 {
                return Err("expected one copied paper".into());
            }
            let copy_id = copies[0].as_str().ok_or("copy ID was not a string")?;
            let copy = load(store, copy_id)?.ok_or("copy was not persisted")?;
            if copy.parent != Some(uuid("24")?) || load(store, &id("23"))?.is_none() {
                return Err("copy was not in destination or source vanished".into());
            }
        }
        ("imbib-library-service_deduplicate-library", "merge-same-doi") => {
            let surviving = usize::from(load(store, &id("27"))?.is_some())
                + usize::from(load(store, &id("28"))?.is_some());
            if surviving != 1 {
                return Err("deduplication did not leave exactly one paper".into());
            }
        }
        ("imbib-library-service_import-bibtex", "import-one-entry") => {
            let ids = result.as_array().ok_or("import result was not an array")?;
            if ids.len() != 1 {
                return Err("BibTeX import did not create one paper".into());
            }
            let imported = load(store, ids[0].as_str().ok_or("import ID was not text")?)?
                .ok_or("imported paper not persisted")?;
            if imported.parent != Some(uuid("30")?)
                || imported.schema != refs::IMBIB_BIBLIOGRAPHY_ENTRY
            {
                return Err("BibTeX paper was not saved in the target library".into());
            }
        }
        ("imbib-library-service_export-bibtex", "export-cite-key") => {
            if !result.as_str().unwrap_or("").contains("G3Export2026") {
                return Err("export omitted the requested cite key".into());
            }
        }
        ("imbib-library-service_export-all-bibtex", "export-project-library") => {
            if !result.as_str().unwrap_or("").contains("G3AllExport2026") {
                return Err("export omitted the library's paper".into());
            }
        }
        ("imbib-library-service_add-linked-file", "link-local-pdf") => {
            let file_id = result["id"].as_str().ok_or("linked file ID missing")?;
            let file = load(store, file_id)?.ok_or("linked file not persisted")?;
            if file.schema != refs::IMBIB_LINKED_FILE || file.parent != Some(uuid("41")?) {
                return Err("file was not attached to the paper".into());
            }
        }
        _ => {}
    }
    Ok(())
}

fn load(
    store: &SqliteItemStore,
    item_id: &str,
) -> Result<Option<impress_core::item::Item>, String> {
    let item_id = ItemId::parse_str(item_id).map_err(|e| e.to_string())?;
    store.get(item_id).map_err(|e| e.to_string())
}

fn require_row(result: &Value, expected_id: &str) -> Result<(), String> {
    let rows = result.as_array().ok_or("expected a list of rows")?;
    if rows.iter().any(|row| row["id"] == expected_id) {
        Ok(())
    } else {
        Err(format!("result omitted scratch row {expected_id}"))
    }
}

fn require_unfiled(
    store: &SqliteItemStore,
    collection_suffix: &str,
    paper_suffix: &str,
) -> Result<(), String> {
    let members = collection_ops::list_members(store, &IMBIB_COLLECTION, &id(collection_suffix))
        .map_err(|e| e.to_string())?;
    let paper_id = uuid(paper_suffix)?;
    if members.iter().any(|row| row.id == paper_id) || load(store, &id(paper_suffix))?.is_none() {
        return Err("paper was removed from the store or remains in the collection".into());
    }
    Ok(())
}
