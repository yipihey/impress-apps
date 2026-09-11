//! The `imprint-project-service` verbs against a private workspace
//! (ADR-0030 P1, Tier A): tree, file, put (text and a binary read from
//! disk), move, delete, entry, targets, bibliography spec, figure build
//! spec, graph — and the watched-folder refusal.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use imprint_service::{DefaultImprintProjectService, ImprintProjectService};
use uuid::Uuid;

struct World {
    svc: DefaultImprintProjectService,
    store: Arc<SqliteItemStore>,
    dir: tempfile::TempDir,
}

fn manuscript(store: &SqliteItemStore, format: &str, body: &str, external: bool) -> String {
    let id: ItemId = Uuid::new_v4();
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Paper".into()));
    payload.insert("format".into(), Value::String(format.into()));
    payload.insert("status".into(), Value::String("draft".into()));
    payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
    payload.insert("body_content".into(), Value::String(body.into()));
    payload.insert(
        "body_content_hash".into(),
        Value::String(impress_core::manuscript_ops::sha256_hex(body)),
    );
    if external {
        payload.insert(
            "external_source".into(),
            Value::String(r#"{"path":"/tmp/x.tex"}"#.into()),
        );
    }
    let now = Utc::now();
    store
        .insert(Item {
            id,
            schema: "manuscript".into(),
            payload,
            created: now,
            modified: now,
            author: "user:test".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        })
        .unwrap();
    id.to_string()
}

fn world() -> World {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(SqliteItemStore::open_in_memory().unwrap());
    let svc = DefaultImprintProjectService::with_store(store.clone(), dir.path().join("content"));
    World { svc, store, dir }
}

#[tokio::test]
async fn a_latex_project_round_trips_through_the_verbs() {
    let w = world();
    let id = manuscript(
        &w.store,
        "latex",
        "\\documentclass{article}\n\\graphicspath{{figures/}}\n\\input{chapters/intro}\n\\includegraphics{fig1}\n\\bibliography{refs}\n\\cite{knuth84}",
        false,
    );

    // A one-file project before anything is added.
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree.ok, "{}", tree.message);
    assert_eq!(tree.entry_path, "main.tex");
    assert!(tree.files.is_empty());
    assert_eq!(tree.targets.len(), 1);
    assert_eq!(tree.targets[0].engine, "tectonic");
    assert_eq!(tree.project_version, 0);

    // Text through `content`, a binary through `file_path`.
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "chapters/intro.tex".into(),
            Some("\\section{Intro}\nAs \\cite{smith20} showed.".into()),
            None,
            None,
            Some("agent:test".into()),
        )
        .await;
    assert!(put.ok, "{}", put.message);
    let file = put.file.unwrap();
    assert_eq!(file.role, "chapter");
    assert_eq!(file.format.as_deref(), Some("latex"));
    assert!(!file.in_blob_store);

    let png_path = w.dir.path().join("fig1.png");
    std::fs::write(&png_path, b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR").unwrap();
    let put_png = w
        .svc
        .project_put_file(
            id.clone(),
            "figures/fig1.png".into(),
            None,
            Some(png_path.display().to_string()),
            None,
            None,
        )
        .await;
    assert!(put_png.ok, "{}", put_png.message);
    let png = put_png.file.unwrap();
    assert_eq!(png.kind, "binary");
    assert_eq!(png.role, "figure");
    assert!(png.in_blob_store);

    let put_bib = w
        .svc
        .project_put_file(
            id.clone(),
            "refs.bib".into(),
            Some("@article{knuth84, title={Literate}}".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(put_bib.ok);

    // Neither `content` nor `file_path` is a refusal, not a silent empty file.
    let neither = w
        .svc
        .project_put_file(id.clone(), "x.tex".into(), None, None, None, None)
        .await;
    assert!(!neither.ok);
    assert!(neither.message.contains("content"), "{}", neither.message);
    // The entry cannot be shadowed by a row.
    let shadow = w
        .svc
        .project_put_file(
            id.clone(),
            "main.tex".into(),
            Some("x".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(!shadow.ok);

    // The tree now, and the file reads.
    let tree = w.svc.project_tree(id.clone()).await;
    assert_eq!(
        tree.files
            .iter()
            .map(|f| f.path.as_str())
            .collect::<Vec<_>>(),
        vec!["chapters/intro.tex", "figures/fig1.png", "refs.bib"]
    );
    assert_eq!(tree.project_version, 1);
    let read = w
        .svc
        .project_file(id.clone(), "chapters/intro.tex".into())
        .await;
    assert!(read.ok);
    assert!(read.text.unwrap().starts_with("\\section{Intro}"));
    let entry = w.svc.project_file(id.clone(), "main.tex".into()).await;
    assert!(entry.ok);
    assert!(entry.text.unwrap().starts_with("\\documentclass"));
    let bin = w
        .svc
        .project_file(id.clone(), "figures/fig1.png".into())
        .await;
    assert!(bin.ok, "{}", bin.message);
    let temp = bin.temp_path.expect("binary comes back as a temp file");
    assert_eq!(std::fs::read(&temp).unwrap()[..4], b"\x89PNG"[..]);
    let missing = w.svc.project_file(id.clone(), "nope.tex".into()).await;
    assert!(!missing.ok);

    // The graph: chapter and figure resolve (graphicspath + implied
    // extension), the bibliography resolves, both cite keys are seen.
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert!(graph.ok, "{}", graph.message);
    assert!(!graph.has_errors, "{:?}", graph.diagnostics);
    let edges: Vec<(String, String, String)> = graph
        .edges
        .iter()
        .map(|e| (e.from.clone(), e.to.clone(), e.kind.clone()))
        .collect();
    assert!(edges.contains(&(
        "main.tex".into(),
        "chapters/intro.tex".into(),
        "include".into()
    )));
    assert!(edges.contains(&("main.tex".into(), "figures/fig1.png".into(), "image".into())));
    assert!(edges.contains(&("main.tex".into(), "refs.bib".into(), "bibliography".into())));
    assert_eq!(graph.cite_keys, vec!["knuth84", "smith20"]);
    assert_eq!(graph.bibliographies, vec!["refs.bib"]);
    assert_eq!(graph.reachable.len(), 4, "entry + 3 files");

    // Move the chapter: the include breaks, the graph says where.
    let moved = w
        .svc
        .project_move_file(
            id.clone(),
            "chapters/intro.tex".into(),
            "parts/intro.tex".into(),
            None,
        )
        .await;
    assert!(moved.ok, "{}", moved.message);
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert!(graph.has_errors);
    let err = graph
        .diagnostics
        .iter()
        .find(|d| d.severity == "error")
        .unwrap();
    assert_eq!(err.code, "unresolved-include");
    assert_eq!(err.file.as_deref(), Some("main.tex"));
    assert_eq!(err.line, Some(3));
    assert_eq!(graph.unreferenced, vec!["parts/intro.tex"]);

    // Delete, twice.
    let del = w
        .svc
        .project_delete_file(id.clone(), "parts/intro.tex".into())
        .await;
    assert!(del.ok && del.affected_count == 1);
    let del = w
        .svc
        .project_delete_file(id.clone(), "parts/intro.tex".into())
        .await;
    assert!(del.ok && del.affected_count == 0);
}

#[tokio::test]
async fn targets_bibliography_specs_and_figure_builds() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "#include \"chapters/a.typ\"\n#figure(image(\"figures/a.svg\"))\n#bibliography(\"refs.bib\")\n@key1",
        false,
    );
    for (path, text) in [
        ("chapters/a.typ", "== A\n@key2"),
        ("refs.bib", ""),
        ("figures/a.plot", r#"{"kind":"line"}"#),
        ("talk.typ", "= Talk\n#include \"chapters/a.typ\""),
    ] {
        let r = w
            .svc
            .project_put_file(id.clone(), path.into(), Some(text.into()), None, None, None)
            .await;
        assert!(r.ok, "{}", r.message);
    }

    // Two targets over one tree.
    let set = w
        .svc
        .project_set_targets(
            id.clone(),
            Some(r#"[{"id":"paper"},{"id":"talk","entry":"talk.typ","output_kind":"svg"}]"#.into()),
            None,
        )
        .await;
    assert!(set.ok, "{}", set.message);
    assert_eq!(
        set.targets
            .iter()
            .map(|t| t.id.as_str())
            .collect::<Vec<_>>(),
        vec!["paper", "talk"]
    );
    assert_eq!(set.targets[1].engine, "typst");
    assert_eq!(set.targets[1].output_kind, "svg");
    let bad = w
        .svc
        .project_set_targets(
            id.clone(),
            Some(r#"[{"id":"x","engine":"docx"}]"#.into()),
            None,
        )
        .await;
    assert!(!bad.ok);
    assert!(bad.message.contains("engine"), "{}", bad.message);

    // The talk's graph is its own.
    let talk = w.svc.project_graph(id.clone(), Some("talk".into())).await;
    assert!(talk.ok, "{}", talk.message);
    assert_eq!(talk.entry, "talk.typ");
    assert!(talk.reachable.contains(&"chapters/a.typ".to_string()));
    assert!(!talk.reachable.contains(&"refs.bib".to_string()));
    let unknown = w.svc.project_graph(id.clone(), Some("poster".into())).await;
    assert!(!unknown.ok);

    // A projected bibliography.
    let bib = w
        .svc
        .project_set_bibliography(
            id.clone(),
            "refs.bib".into(),
            Some(r#"{"kind":"cited"}"#.into()),
        )
        .await;
    assert!(bib.ok, "{}", bib.message);
    assert_eq!(
        bib.file.unwrap().bib_source_json.as_deref(),
        Some(r#"{"kind":"cited"}"#)
    );
    let bad = w
        .svc
        .project_set_bibliography(
            id.clone(),
            "refs.bib".into(),
            Some(r#"{"kind":"magic"}"#.into()),
        )
        .await;
    assert!(!bad.ok);

    // A figure build: the output is not built yet, so the graph says so and
    // the image reference stays unresolved until it is.
    let build = w
        .svc
        .project_set_figure_build(
            id.clone(),
            "figures/a.plot".into(),
            Some(r#"{"runner":"impress-plot","outputs":["figures/a.svg"]}"#.into()),
        )
        .await;
    assert!(build.ok, "{}", build.message);
    assert_eq!(build.file.as_ref().unwrap().role, "figure-source");
    let graph = w.svc.project_graph(id.clone(), Some("paper".into())).await;
    assert_eq!(graph.steps.len(), 1);
    assert!(graph.steps[0].stale);
    assert_eq!(graph.steps[0].missing_outputs, vec!["figures/a.svg"]);
    assert!(graph
        .diagnostics
        .iter()
        .any(|d| d.code == "output-not-built"));
    assert!(graph
        .diagnostics
        .iter()
        .any(|d| d.code == "unresolved-image"));
    let escape = w
        .svc
        .project_set_figure_build(
            id.clone(),
            "figures/a.plot".into(),
            Some(r#"{"runner":"shell","outputs":["../evil.pdf"]}"#.into()),
        )
        .await;
    assert!(!escape.ok, "outputs cannot leave the tree");
}

#[tokio::test]
async fn watched_folder_manuscripts_refuse_project_writes() {
    let w = world();
    let id = manuscript(&w.store, "latex", "\\documentclass{article}", true);
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "a.tex".into(),
            Some("x".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(!put.ok);
    assert!(put.message.contains("watched-folder"), "{}", put.message);
    // Reads still work: the index is legible.
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree.ok);
    let graph = w.svc.project_graph(id, None).await;
    assert!(graph.ok);
}

#[tokio::test]
async fn bad_ids_and_paths_are_refusals_not_panics() {
    let w = world();
    assert!(!w.svc.project_tree("not-a-uuid".into()).await.ok);
    assert!(!w.svc.project_tree(Uuid::new_v4().to_string()).await.ok);
    let id = manuscript(&w.store, "typst", "= T", false);
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "../escape.typ".into(),
            Some("x".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(!put.ok);
    assert!(put.message.contains(".."), "{}", put.message);
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "a.typ".into(),
            Some("x".into()),
            None,
            Some("main".into()),
            None,
        )
        .await;
    assert!(!put.ok, "main is not a file role");
}

#[tokio::test]
async fn outline_and_citations_span_the_tree_in_reading_order() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "= Paper\n#include \"b.typ\"\n#include \"a.typ\"\n= Conclusion\nSee @last.",
        false,
    );
    for (path, text) in [
        ("a.typ", "== A\n@ka"),
        ("b.typ", "== B\n#include \"c.typ\"\n@kb"),
        ("c.typ", "=== C\n@kc"),
        ("orphan.typ", "== Never\n@never"),
    ] {
        let r = w
            .svc
            .project_put_file(id.clone(), path.into(), Some(text.into()), None, None, None)
            .await;
        assert!(r.ok, "{}", r.message);
    }
    let outline = w.svc.project_outline(id.clone(), None).await;
    assert!(outline.ok, "{}", outline.message);
    assert_eq!(
        outline.reading_order,
        vec!["main.typ", "b.typ", "c.typ", "a.typ"]
    );
    let titles: Vec<(String, String, u32)> = outline
        .sections
        .iter()
        .map(|s| (s.path.clone(), s.title.clone(), s.order_index))
        .collect();
    assert_eq!(
        titles,
        vec![
            ("main.typ".into(), "Paper".into(), 0),
            ("main.typ".into(), "Conclusion".into(), 1),
            ("b.typ".into(), "B".into(), 2),
            ("c.typ".into(), "C".into(), 3),
            ("a.typ".into(), "A".into(), 4),
        ]
    );
    assert!(outline.sections.iter().all(|s| s.id.len() == 36));

    let cites = w.svc.project_citations(id.clone(), None).await;
    assert!(cites.ok, "{}", cites.message);
    let pairs: Vec<(String, String)> = cites
        .usages
        .iter()
        .map(|u| (u.path.clone(), u.key.clone()))
        .collect();
    assert_eq!(
        pairs,
        vec![
            ("main.typ".into(), "last".into()),
            ("b.typ".into(), "kb".into()),
            ("c.typ".into(), "kc".into()),
            ("a.typ".into(), "ka".into()),
        ]
    );
    assert_eq!(cites.keys, vec!["ka", "kb", "kc", "last"]);
    assert_eq!(cites.usages[0].command, "typstat");

    // A LaTeX target on a Typst tree is refused by the compile verb with the
    // engine named, whether or not the renderer is built in.
    let set = w
        .svc
        .project_set_targets(
            id.clone(),
            Some(r#"[{"id":"pdf","engine":"tectonic"}]"#.into()),
            None,
        )
        .await;
    assert!(set.ok, "{}", set.message);
    let refused = w
        .svc
        .project_compile(id.clone(), Some("pdf".into()), None)
        .await;
    assert!(!refused.ok);
    assert_eq!(refused.engine, "tectonic");
    assert!(refused.message.contains("tectonic"), "{}", refused.message);
}

/// Without `typst-render` the compile verb still answers: a failed record that
/// names the missing feature (the "not enabled" DTO the crate's feature comment
/// promises), not a transport error. Until 2026-09-11 this arm compiled only
/// when something else had switched Typst on in imprint-core, because the
/// outcome type it names lived in imprint-core's Typst-only module.
#[cfg(not(feature = "typst-render"))]
#[tokio::test]
async fn compile_without_typst_render_is_a_structured_refusal() {
    let w = world();
    let id = manuscript(&w.store, "typst", "= Paper\nHello.", false);
    let out = w.svc.project_compile(id, None, None).await;
    assert!(!out.ok);
    assert_eq!(out.engine, "typst");
    assert!(out.message.contains("typst-render"), "{}", out.message);
    assert!(out.pdf_path.is_none());
}

#[cfg(feature = "typst-render")]
#[tokio::test]
async fn compile_renders_a_multi_file_typst_project_with_a_projected_bibliography() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "= Paper\n#include \"chapters/intro.typ\"\nAs @knuth84 wrote.\n#bibliography(\"refs.bib\")",
        false,
    );
    // An imbib entry the projection can find, with raw BibTeX.
    {
        let mut payload = BTreeMap::new();
        payload.insert("cite_key".into(), Value::String("knuth84".into()));
        payload.insert("entry_type".into(), Value::String("book".into()));
        payload.insert("title".into(), Value::String("The TeXbook".into()));
        payload.insert(
            "raw_bibtex".into(),
            Value::String(
                "@book{knuth84, author={Donald Knuth}, title={The TeXbook}, year={1984}, publisher={Addison-Wesley}}"
                    .into(),
            ),
        );
        let now = Utc::now();
        w.store
            .insert(Item {
                id: Uuid::new_v4(),
                schema: "imbib/bibliography-entry".into(),
                payload,
                created: now,
                modified: now,
                author: "user:test".into(),
                author_kind: ActorKind::Human,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::Normal,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            })
            .unwrap();
    }
    for (path, text) in [
        (
            "chapters/intro.typ",
            "== Intro\nHello from a chapter, citing @smith20 too.",
        ),
        ("refs.bib", ""),
    ] {
        let r = w
            .svc
            .project_put_file(id.clone(), path.into(), Some(text.into()), None, None, None)
            .await;
        assert!(r.ok, "{}", r.message);
    }
    let bib = w
        .svc
        .project_set_bibliography(
            id.clone(),
            "refs.bib".into(),
            Some(r#"{"kind":"cited"}"#.into()),
        )
        .await;
    assert!(bib.ok, "{}", bib.message);

    let out = w.svc.project_compile(id.clone(), None, None).await;
    assert!(out.ok, "{} / {:?}", out.message, out.diagnostics);
    let pdf = out.pdf_path.expect("a pdf path");
    assert!(std::fs::read(&pdf).unwrap().starts_with(b"%PDF"));
    assert!(out.page_count >= 1);
    let refs = out
        .bibliographies
        .iter()
        .find(|b| b.path == "refs.bib")
        .unwrap();
    assert_eq!(refs.requested, vec!["knuth84", "smith20"]);
    assert_eq!(
        refs.missing,
        vec!["smith20"],
        "the chapter's key is projected and reported missing"
    );
    assert!(out
        .diagnostics
        .iter()
        .any(|d| d.code == "missing-reference" && d.message.contains("smith20")));

    // The live buffer wins over the stored entry.
    let live = w
        .svc
        .project_compile(
            id.clone(),
            None,
            Some("= Live\n#pagebreak()\n= Two\n#pagebreak()\n= Three".into()),
        )
        .await;
    assert!(live.ok, "{}", live.message);
    assert_eq!(live.page_count, 3);

    // A broken chapter names the chapter and its line.
    let broken = w
        .svc
        .project_put_file(
            id.clone(),
            "chapters/intro.typ".into(),
            Some("== Intro\n\n#let x = (\nunclosed".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(broken.ok);
    let out = w.svc.project_compile(id, None, None).await;
    assert!(!out.ok);
    let err = out
        .diagnostics
        .iter()
        .find(|d| d.severity == "error")
        .expect("an error diagnostic");
    assert_eq!(err.file.as_deref(), Some("chapters/intro.typ"));
    assert!(err.line.unwrap_or(0) >= 3, "{err:?}");
}

// ---------------------------------------------------------------------------
// P3: a directory in, a directory out, a revision of the tree
// ---------------------------------------------------------------------------

fn latex_directory() -> tempfile::TempDir {
    let src = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(src.path().join("chapters")).unwrap();
    std::fs::create_dir_all(src.path().join("figures")).unwrap();
    std::fs::write(
        src.path().join("main.tex"),
        "\\documentclass{article}\n\\begin{document}\n\\input{chapters/intro}\n\
         \\includegraphics{figures/f.png}\n\\bibliography{refs}\n\\end{document}\n",
    )
    .unwrap();
    std::fs::write(
        src.path().join("chapters/intro.tex"),
        "\\section{Intro}\nHello \\cite{knuth84}.\n",
    )
    .unwrap();
    std::fs::write(
        src.path().join("figures/f.png"),
        b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR",
    )
    .unwrap();
    std::fs::write(
        src.path().join("refs.bib"),
        "@article{knuth84, title={Literate Programming}}\n",
    )
    .unwrap();
    std::fs::write(src.path().join("main.aux"), "residue").unwrap();
    src
}

#[tokio::test]
async fn a_directory_becomes_a_new_project_manuscript() {
    let w = world();
    let src = latex_directory();
    let r = w
        .svc
        .project_import_directory(
            src.path().display().to_string(),
            None,
            None,
            Some("Imported".into()),
            None,
        )
        .await;
    assert!(r.ok, "{}", r.message);
    assert!(r.created);
    assert_eq!(r.entry_path, "main.tex");
    assert_eq!(r.format, "latex");
    let paths: Vec<&str> = r.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(
        paths,
        vec!["chapters/intro.tex", "figures/f.png", "refs.bib"]
    );
    let roles: Vec<&str> = r.files.iter().map(|f| f.role.as_str()).collect();
    assert_eq!(roles, vec!["chapter", "figure", "bibliography"]);
    assert!(
        r.skipped.iter().any(|s| s.starts_with("main.aux")),
        "{:?}",
        r.skipped
    );

    let tree = w.svc.project_tree(r.manuscript_id.clone()).await;
    assert!(tree.ok, "{}", tree.message);
    assert_eq!(tree.title, "Imported");
    assert_eq!(tree.format, "latex");
    assert_eq!(tree.entry_path, "main.tex");
    assert_eq!(tree.project_version, 1);
    let entry = w
        .svc
        .project_file(r.manuscript_id.clone(), "main.tex".into())
        .await;
    assert!(entry.text.unwrap().contains("\\documentclass"));
    let graph = w.svc.project_graph(r.manuscript_id.clone(), None).await;
    assert!(!graph.has_errors, "{:?}", graph.diagnostics);
    assert!(graph.cite_keys.contains(&"knuth84".to_string()));
}

#[tokio::test]
async fn a_directory_imports_into_an_existing_manuscript_through_the_document() {
    let w = world();
    let id = manuscript(&w.store, "typst", "= Old\nAn older draft.", false);
    let base = w
        .store
        .manuscript_collab_heads(id.parse().unwrap())
        .unwrap();
    assert!(!base.is_empty());

    let src = latex_directory();
    let r = w
        .svc
        .project_import_directory(
            src.path().display().to_string(),
            Some(id.clone()),
            None,
            None,
            Some("agent:import".into()),
        )
        .await;
    assert!(r.ok, "{}", r.message);
    assert!(!r.created);
    assert_eq!(r.manuscript_id, id);

    let tree = w.svc.project_tree(id.clone()).await;
    assert_eq!(
        tree.format, "latex",
        "the format follows the directory's entry"
    );
    assert_eq!(tree.entry_path, "main.tex");
    assert_eq!(tree.files.len(), 3);
    let entry = w.svc.project_file(id.clone(), "main.tex".into()).await;
    assert!(entry.text.unwrap().starts_with("\\documentclass"));
    // The body moved through the document: the old text is still reachable
    // at the base heads.
    let old = w
        .store
        .manuscript_text_at(id.parse().unwrap(), &base)
        .unwrap();
    assert!(old.contains("An older draft."));

    // A watched-folder manuscript refuses.
    let external = manuscript(&w.store, "latex", "x", true);
    let refused = w
        .svc
        .project_import_directory(
            src.path().display().to_string(),
            Some(external),
            None,
            None,
            None,
        )
        .await;
    assert!(!refused.ok);
    assert!(refused.message.contains("external"), "{}", refused.message);
}

#[tokio::test]
async fn export_materialize_and_snapshot_round_trip_the_tree() {
    let w = world();
    let src = latex_directory();
    let r = w
        .svc
        .project_import_directory(src.path().display().to_string(), None, None, None, None)
        .await;
    assert!(r.ok, "{}", r.message);
    let id = r.manuscript_id.clone();

    // Export, bundle layout: files plus the manifest.
    let out_dir = w.dir.path().join("export");
    let export = w
        .svc
        .project_export(id.clone(), out_dir.display().to_string(), None, None)
        .await;
    assert!(export.ok, "{}", export.message);
    assert!(out_dir.join("manifest.json").is_file());
    assert!(out_dir.join("chapters/intro.tex").is_file());
    assert!(out_dir.join("figures/f.png").is_file());
    assert_eq!(
        std::fs::read_to_string(out_dir.join("main.tex")).unwrap(),
        std::fs::read_to_string(src.path().join("main.tex")).unwrap()
    );
    assert!(export.written.contains(&"manifest.json".to_string()));
    let manifest = std::fs::read_to_string(out_dir.join("manifest.json")).unwrap();
    assert!(
        serde_json::from_str::<serde_json::Value>(&manifest)
            .map(|v| v["main_source"] == "main.tex" && v["source_format"] == "tex")
            .unwrap_or(false),
        "{manifest}"
    );

    // Standalone: no manifest.
    let plain_dir = w.dir.path().join("plain");
    let plain = w
        .svc
        .project_export(
            id.clone(),
            plain_dir.display().to_string(),
            None,
            Some("standalone".into()),
        )
        .await;
    assert!(plain.ok, "{}", plain.message);
    assert!(!plain_dir.join("manifest.json").exists());
    let bad = w
        .svc
        .project_export(
            id.clone(),
            plain_dir.display().to_string(),
            None,
            Some("zip".into()),
        )
        .await;
    assert!(!bad.ok);

    // Materialise twice: the second run touches nothing.
    let build_dir = w.dir.path().join("build");
    let first = w
        .svc
        .project_materialize(id.clone(), None, Some(build_dir.display().to_string()))
        .await;
    assert!(first.ok, "{}", first.message);
    assert_eq!(first.written.len(), 4);
    assert!(first.entry.ends_with("main.tex"));
    let second = w
        .svc
        .project_materialize(id.clone(), None, Some(build_dir.display().to_string()))
        .await;
    assert!(second.ok, "{}", second.message);
    assert!(second.written.is_empty(), "{:?}", second.written);
    assert_eq!(second.unchanged.len(), 4);
    // A file the tree no longer has is pruned; a stranger's file is not.
    std::fs::write(build_dir.join("notes.txt"), "mine").unwrap();
    let deleted = w
        .svc
        .project_delete_file(id.clone(), "figures/f.png".into())
        .await;
    assert!(deleted.ok, "{}", deleted.message);
    let third = w
        .svc
        .project_materialize(id.clone(), None, Some(build_dir.display().to_string()))
        .await;
    assert!(third.ok, "{}", third.message);
    assert_eq!(third.removed, vec!["figures/f.png".to_string()]);
    assert!(!build_dir.join("figures/f.png").exists());
    assert!(build_dir.join("notes.txt").is_file());

    // Snapshot: a revision whose archive is the packed tree in the CAS.
    let snap = w
        .svc
        .project_snapshot(
            id.clone(),
            "v1".into(),
            Some("first cut".into()),
            None,
            None,
        )
        .await;
    assert!(snap.ok, "{}", snap.message);
    assert_eq!(snap.file_count, 3);
    assert!(snap.archive_bytes > 0);
    let digest = impress_core::blobs::parse_blob_ref(&snap.archive_ref).expect("a blob ref");
    let blobs = impress_core::blobs::BlobStore::for_workspace(w.dir.path());
    let archive = blobs.get(digest).unwrap().expect("archive in the CAS");
    let entries = imprint_core::project::unpack(&archive).unwrap();
    let names: Vec<&str> = entries.iter().map(|(p, _)| p.as_str()).collect();
    assert_eq!(
        names,
        vec![
            "manifest.json",
            "chapters/intro.tex",
            "main.tex",
            "refs.bib"
        ]
    );
    let revision = w
        .store
        .get(snap.revision_id.parse().unwrap())
        .unwrap()
        .expect("revision row");
    assert_eq!(revision.schema, "manuscript-revision");
    assert_eq!(
        revision.payload.get("source_archive_ref"),
        Some(&Value::String(snap.archive_ref.clone()))
    );
    assert_eq!(
        revision.payload.get("content_hash"),
        Some(&Value::String(snap.content_hash.clone()))
    );
    assert!(matches!(
        revision.payload.get("bundle_manifest_json"),
        Some(Value::String(m)) if m.contains("main.tex")
    ));
    let manuscript = w.store.get(id.parse().unwrap()).unwrap().unwrap();
    assert_eq!(
        manuscript.payload.get("current_revision_ref"),
        Some(&Value::String(snap.revision_id.clone()))
    );

    // A second snapshot of an unchanged tree packs identical bytes and
    // supersedes the first.
    let again = w
        .svc
        .project_snapshot(id.clone(), "v2".into(), None, None, None)
        .await;
    assert!(again.ok, "{}", again.message);
    assert_eq!(again.archive_ref, snap.archive_ref);
    let second_rev = w
        .store
        .get(again.revision_id.parse().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        second_rev.payload.get("predecessor_revision_ref"),
        Some(&Value::String(snap.revision_id.clone()))
    );
}

// ---------------------------------------------------------------------------
// P4: builds are records
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_build_runs_stale_steps_records_a_row_and_keeps_produced_files() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "= Paper\n#image(\"figures/plot.png\")",
        false,
    );
    // A figure source with a shell step, and a target with no document engine.
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "figures/make.sh".into(),
            Some("printf 'PNG' > figures/plot.png".into()),
            None,
            Some("figure-source".into()),
            None,
        )
        .await;
    assert!(put.ok, "{}", put.message);
    let spec = w
        .svc
        .project_set_figure_build(
            id.clone(),
            "figures/make.sh".into(),
            Some(r#"{"runner":"shell","outputs":["figures/plot.png"],"args":{"command":"sh figures/make.sh"}}"#.into()),
        )
        .await;
    assert!(spec.ok, "{}", spec.message);
    let targets = w
        .svc
        .project_set_targets(
            id.clone(),
            Some(r#"[{"id":"figures","engine":"none"}]"#.into()),
            None,
        )
        .await;
    assert!(targets.ok, "{}", targets.message);

    // Shell steps are off unless asked for: the step is skipped, the build ok.
    let quiet = w
        .svc
        .project_build(id.clone(), None, None, None, None)
        .await;
    assert!(quiet.ok, "{}", quiet.message);
    let b = quiet.build.as_ref().unwrap();
    assert_eq!(b.status, "ok");
    assert_eq!(b.engine, "none");
    assert_eq!(b.steps.len(), 1);
    assert_eq!(b.steps[0].status, "skipped");

    // Allowed: the step runs in the materialised directory and its output
    // becomes a row derived from the source.
    let built = w
        .svc
        .project_build(
            id.clone(),
            None,
            Some(true),
            None,
            Some("agent:build".into()),
        )
        .await;
    assert!(built.ok, "{}: {}", built.message, built.log);
    let b = built.build.as_ref().unwrap();
    assert_eq!(b.steps[0].status, "ran", "{:?}", b.steps);
    assert!(built.log.contains("$ sh -c"), "{}", built.log);
    let tree = w.svc.project_tree(id.clone()).await;
    let plot = tree
        .files
        .iter()
        .find(|f| f.path == "figures/plot.png")
        .expect("produced row");
    assert_eq!(plot.role, "output");
    assert_eq!(plot.derived_from.as_deref(), Some("figures/make.sh"));
    assert!(plot
        .derived_from_hash
        .as_deref()
        .is_some_and(|h| !h.is_empty()));
    let bytes = w
        .svc
        .project_file(id.clone(), "figures/plot.png".into())
        .await;
    assert!(bytes.ok, "{}", bytes.message);

    // The graph now sees the step as fresh; a third build does nothing.
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert!(graph.steps.iter().all(|s| !s.stale), "{:?}", graph.steps);
    let again = w
        .svc
        .project_build(id.clone(), None, Some(true), None, None)
        .await;
    assert!(again.ok, "{}", again.message);
    assert_eq!(again.build.unwrap().steps[0].status, "fresh");

    // Three builds recorded, newest first; no pdf output for a none target.
    let builds = w.svc.project_builds(id.clone(), None, None).await;
    assert!(builds.ok);
    assert_eq!(builds.builds.len(), 3);
    assert!(builds.builds[0].started_ms >= builds.builds[2].started_ms);
    let output = w
        .svc
        .project_build_output(id.clone(), None, None, None)
        .await;
    assert!(!output.ok);
    assert!(
        output.message.contains("no pdf output"),
        "{}",
        output.message
    );
}

#[cfg(feature = "typst-render")]
#[tokio::test]
async fn a_typst_build_writes_the_pdf_and_keeps_it_in_the_cas() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "#set page(width: 10cm, height: 6cm)\n= Paper\n#include \"chapters/intro.typ\"",
        false,
    );
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "chapters/intro.typ".into(),
            Some("== Intro\nHello from the chapter.".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(put.ok, "{}", put.message);

    let built = w
        .svc
        .project_build(id.clone(), None, None, None, None)
        .await;
    assert!(built.ok, "{}: {}", built.message, built.log);
    let b = built.build.unwrap();
    assert_eq!(b.engine, "typst");
    assert_eq!(b.status, "ok");
    let pdf = b
        .outputs
        .iter()
        .find(|o| o.kind == "pdf")
        .expect("a pdf output");
    assert_eq!(pdf.name, "main.pdf");
    assert!(pdf
        .blob_ref
        .as_deref()
        .is_some_and(|r| r.starts_with("blob:sha256:")));
    assert!(std::fs::read(&pdf.path).unwrap().starts_with(b"%PDF"));

    // The output verb: from the directory while it is there, from the CAS
    // once it is gone.
    let out = w
        .svc
        .project_build_output(id.clone(), None, None, None)
        .await;
    assert!(out.ok, "{}", out.message);
    assert_eq!(out.path.as_deref(), Some(pdf.path.as_str()));
    std::fs::remove_file(&pdf.path).unwrap();
    let again = w
        .svc
        .project_build_output(id.clone(), Some(b.id.clone()), None, Some("pdf".into()))
        .await;
    assert!(again.ok, "{}", again.message);
    assert!(again.message.contains("CAS"));
    assert!(std::fs::read(again.path.unwrap())
        .unwrap()
        .starts_with(b"%PDF"));

    // The live buffer builds instead of the stored entry.
    let live = w
        .svc
        .project_build(
            id.clone(),
            None,
            None,
            Some("#set page(width: 10cm, height: 6cm)\n= Live".into()),
            None,
        )
        .await;
    assert!(live.ok, "{}", live.message);
}

#[cfg(feature = "typst-render")]
#[tokio::test]
async fn a_markdown_manuscript_builds_through_typst() {
    let w = world();
    let id = manuscript(
        &w.store,
        "markdown",
        "---\ntitle: Notes\n---\n\n# Heading\n\nSome *text* with $x^2$.\n\n- a\n- b\n",
        false,
    );
    let built = w
        .svc
        .project_build(id.clone(), None, None, None, None)
        .await;
    assert!(built.ok, "{}: {}", built.message, built.log);
    let b = built.build.unwrap();
    assert_eq!(b.engine, "markdown");
    assert!(b.outputs.iter().any(|o| o.kind == "pdf"));
    assert!(built.log.contains("markdown → typst"));
}

// ---------------------------------------------------------------------------
// The one-file citation convention survives in the tree
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_one_file_typst_manuscript_that_cites_gets_the_implicit_bibliography() {
    let w = world();
    let id = manuscript(&w.store, "typst", "= Paper\nAs @knuth84 showed.", false);
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree.ok, "{}", tree.message);
    assert!(
        tree.files.is_empty(),
        "no rows are written for the implicit file"
    );
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert!(graph.ok, "{}", graph.message);
    assert!(!graph.has_errors, "{:?}", graph.diagnostics);
    assert_eq!(graph.cite_keys, vec!["knuth84"]);
    assert!(
        graph.bibliographies.iter().any(|b| b == "bibliography.bib"),
        "{:?}",
        graph.bibliographies
    );
}

#[cfg(feature = "typst-render")]
#[tokio::test]
async fn a_one_file_typst_manuscript_compiles_with_its_citations_projected() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "#set page(width: 10cm, height: 8cm)\n= Paper\nAs @knuth84 showed.",
        false,
    );
    let out = w.svc.project_compile(id.clone(), None, None).await;
    assert!(out.ok, "{}: {:?}", out.message, out.diagnostics);
    assert!(out.page_count >= 1);
    // The key is not in this empty library: a missing-reference warning, a
    // placeholder in the rendered bibliography, and still a document.
    assert!(out
        .diagnostics
        .iter()
        .any(|d| d.code == "missing-reference" && d.message.contains("knuth84")));
    let bib = out
        .bibliographies
        .iter()
        .find(|b| b.path == "bibliography.bib")
        .expect("the implicit bibliography was projected");
    assert_eq!(bib.requested, vec!["knuth84"]);
}

// ---------------------------------------------------------------------------
// P5/P6: figures of every kind, and working copies
// ---------------------------------------------------------------------------

#[tokio::test]
async fn new_figures_of_every_kind_get_a_starter_and_a_build_spec() {
    let w = world();
    let id = manuscript(&w.store, "typst", "= Paper", false);
    for (kind, ext, runner) in [
        ("veusz", "vsz", "veusz"),
        ("lilaq", "typ", "typst"),
        ("typst", "typ", "typst"),
        ("implore", "plot.json", "implore"),
        ("impress-plot", "plot.json", "impress-plot"),
        ("script", "py", "shell"),
    ] {
        let path = format!("figures/{kind}-fig");
        let r = w
            .svc
            .project_new_figure(id.clone(), path.clone(), kind.into(), None)
            .await;
        assert!(r.ok, "{kind}: {}", r.message);
        assert_eq!(r.kind, kind);
        let file = r.file.unwrap();
        assert_eq!(file.path, format!("figures/{kind}-fig.{ext}"));
        assert_eq!(file.role, "figure-source");
        let build: serde_json::Value =
            serde_json::from_str(r.build_json.as_deref().unwrap()).unwrap();
        assert_eq!(build["runner"], runner);
        if kind != "script" {
            assert_eq!(build["outputs"][0], format!("figures/{kind}-fig.svg"));
        }
    }
    // The graph now has six steps, all stale (no outputs yet).
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert_eq!(graph.steps.len(), 6, "{:?}", graph.steps);
    assert!(graph.steps.iter().all(|s| s.stale));
    // An existing path is refused.
    let again = w
        .svc
        .project_new_figure(
            id.clone(),
            "figures/veusz-fig.vsz".into(),
            "veusz".into(),
            None,
        )
        .await;
    assert!(!again.ok);
    assert!(again.message.contains("exists"));
    let bad = w
        .svc
        .project_new_figure(id, "figures/x".into(), "gnuplot".into(), None)
        .await;
    assert!(!bad.ok);
}

#[cfg(feature = "typst-render")]
#[tokio::test]
async fn a_native_figure_renders_into_output_rows_and_previews_without_writing() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "= Paper\n#figure(image(\"figures/native.svg\"))",
        false,
    );
    let made = w
        .svc
        .project_new_figure(
            id.clone(),
            "figures/native".into(),
            "impress-plot".into(),
            None,
        )
        .await;
    assert!(made.ok, "{}", made.message);

    // A preview writes nothing.
    let look = w
        .svc
        .project_figure_preview(id.clone(), "figures/native.plot.json".into(), None)
        .await;
    assert!(look.ok, "{}: {}", look.message, look.log);
    assert!(look.svg.as_deref().is_some_and(|s| s.contains("<svg")));
    assert!(look.outputs.is_empty());
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree.files.iter().all(|f| f.path != "figures/native.svg"));

    // Rendering records the output as a row derived from the source.
    let render = w
        .svc
        .project_render_figure(
            id.clone(),
            "figures/native.plot.json".into(),
            None,
            None,
            None,
        )
        .await;
    assert!(render.ok, "{}: {}", render.message, render.log);
    assert_eq!(render.status, "ran");
    assert_eq!(render.outputs.len(), 1);
    assert_eq!(render.outputs[0].path, "figures/native.svg");
    assert_eq!(render.outputs[0].role, "output");
    assert_eq!(
        render.outputs[0].derived_from.as_deref(),
        Some("figures/native.plot.json")
    );
    let graph = w.svc.project_graph(id.clone(), None).await;
    assert!(!graph.has_errors, "{:?}", graph.diagnostics);
    assert!(graph.steps.iter().all(|s| !s.stale));

    // Fresh now; forced re-renders.
    let fresh = w
        .svc
        .project_render_figure(
            id.clone(),
            "figures/native.plot.json".into(),
            None,
            None,
            None,
        )
        .await;
    assert_eq!(fresh.status, "fresh");
    let forced = w
        .svc
        .project_render_figure(
            id.clone(),
            "figures/native.plot.json".into(),
            Some(true),
            None,
            None,
        )
        .await;
    assert_eq!(forced.status, "ran");

    // The whole document builds with the figure in place.
    let built = w.svc.project_build(id, None, None, None, None).await;
    assert!(built.ok, "{}: {}", built.message, built.log);
}

#[tokio::test]
async fn a_working_copy_round_trips_through_checkout_status_and_checkin() {
    let w = world();
    let id = manuscript(
        &w.store,
        "typst",
        "= Paper\n#include \"chapters/a.typ\"",
        false,
    );
    let put = w
        .svc
        .project_put_file(
            id.clone(),
            "chapters/a.typ".into(),
            Some("== A".into()),
            None,
            None,
            None,
        )
        .await;
    assert!(put.ok);
    let base = w
        .store
        .manuscript_collab_heads(id.parse().unwrap())
        .unwrap();

    let dir = w.dir.path().join("checkout");
    let out = w
        .svc
        .project_checkout(id.clone(), dir.display().to_string(), None)
        .await;
    assert!(out.ok, "{}", out.message);
    assert!(dir.join("main.typ").is_file() && dir.join("chapters/a.typ").is_file());
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree
        .working_copy_path
        .as_deref()
        .is_some_and(|p| p.ends_with("checkout")));

    let clean = w.svc.project_status(id.clone(), None).await;
    assert!(clean.ok && clean.is_clean, "{clean:?}");

    // Edit, add, delete in the directory.
    std::fs::write(
        dir.join("main.typ"),
        "= Paper, revised\n#include \"chapters/a.typ\"",
    )
    .unwrap();
    std::fs::create_dir_all(dir.join("figures")).unwrap();
    std::fs::write(dir.join("figures/new.svg"), "<svg/>").unwrap();
    std::fs::remove_file(dir.join("chapters/a.typ")).unwrap();
    let status = w.svc.project_status(id.clone(), None).await;
    assert_eq!(status.changed, vec!["main.typ"]);
    assert_eq!(status.added, vec!["figures/new.svg"]);
    assert_eq!(status.missing, vec!["chapters/a.typ"]);

    // Check in: the entry through the document, the new file as a row, the
    // missing one kept (no prune).
    let checkin = w
        .svc
        .project_checkin(id.clone(), None, None, None, Some("user:tom".into()))
        .await;
    assert!(checkin.ok, "{}", checkin.message);
    assert!(checkin.entry_updated);
    assert_eq!(checkin.checked_in, vec!["figures/new.svg", "main.typ"]);
    assert!(checkin.pruned.is_empty());
    let entry = w.svc.project_file(id.clone(), "main.typ".into()).await;
    assert!(entry.text.unwrap().contains("revised"));
    let old = w
        .store
        .manuscript_text_at(id.parse().unwrap(), &base)
        .unwrap();
    assert!(old.contains("= Paper\n"), "history keeps the earlier text");
    let tree = w.svc.project_tree(id.clone()).await;
    assert!(tree
        .files
        .iter()
        .any(|f| f.path == "figures/new.svg" && f.role == "figure"));
    assert!(
        tree.files.iter().any(|f| f.path == "chapters/a.typ"),
        "kept without prune"
    );

    // Prune drops what the directory dropped.
    let pruned = w
        .svc
        .project_checkin(id.clone(), None, None, Some(true), None)
        .await;
    assert!(pruned.ok, "{}", pruned.message);
    assert_eq!(pruned.pruned, vec!["chapters/a.typ"]);
    let after = w.svc.project_status(id.clone(), None).await;
    assert!(after.is_clean, "{after:?}");
}
