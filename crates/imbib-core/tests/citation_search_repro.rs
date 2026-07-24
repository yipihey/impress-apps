//! Repro for the iOS citation-picker search bug (2026-07-24): searching
//! "Scaling", "Language", or "Kaplan" fails to find "Scaling Laws for
//! Neural Language Models" by Kaplan et al., while "Law" (reportedly) hits.
//! Exercises the exact store path the picker uses: `search_publications`.
#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;

fn temp_db() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("impress.sqlite")
        .to_string_lossy()
        .to_string();
    (dir, path)
}

const KAPLAN: &str = r#"@article{Kaplan2020Scaling,
    author = {Kaplan, Jared and McCandlish, Sam and Henighan, Tom},
    title = {Scaling Laws for Neural Language Models},
    journal = {arXiv e-prints},
    year = {2020},
    abstract = {We study empirical scaling laws for language model performance. The loss scales as a power-law with model size.}
}"#;

fn search(store: &ImbibStore, q: &str) -> usize {
    store
        .search_publications(
            q.to_string(),
            None,
            "dateAdded".into(),
            false,
            Some(50),
            None,
        )
        .expect("search")
        .len()
}

#[test]
fn citation_picker_terms_find_kaplan() {
    let (_dir, path) = temp_db();
    let store = ImbibStore::open(path).expect("open");
    let lib = store.create_library("Test".into()).expect("lib");
    let ids = store.import_bibtex(KAPLAN.into(), lib.id).expect("import");
    assert_eq!(ids.len(), 1, "import should add the paper");

    for term in ["Scaling", "scaling", "Language", "Kaplan", "kaplan", "Law", "Laws"] {
        println!("term {:>10}: {} hit(s)", term, search(&store, term));
    }

    assert_eq!(search(&store, "Scaling"), 1, "title token 'Scaling'");
    assert_eq!(search(&store, "Language"), 1, "title token 'Language'");
    assert_eq!(search(&store, "Kaplan"), 1, "author token 'Kaplan'");
}

#[test]
fn citation_picker_prefixes_match() {
    // Type-ahead: partial words must match (Contains uses an FTS prefix
    // phrase since 2026-07-24). "Scal" → "Scaling", "Kap" → "Kaplan".
    let (_dir, path) = temp_db();
    let store = ImbibStore::open(path).expect("open");
    let lib = store.create_library("Test".into()).expect("lib");
    store.import_bibtex(KAPLAN.into(), lib.id).expect("import");

    for term in ["Scal", "Kap", "Neur", "scaling law"] {
        assert_eq!(search(&store, term), 1, "prefix term '{}'", term);
    }
    assert_eq!(search(&store, "Quantum"), 0, "unrelated term still misses");
}
