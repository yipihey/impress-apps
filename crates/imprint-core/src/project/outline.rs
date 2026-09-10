//! Sections and citations over a whole tree (ADR-0030 P2): the outline of a
//! multi-file manuscript is the outline of its entry with every included
//! file spliced in where it is included, in include order — which is what
//! the reader sees.
//!
//! The one-file case is byte-identical to `sections::extract` on the body
//! (pinned by `sections_for_a_one_file_tree_match_extract`), so existing
//! section ids do not move; a chapter's sections get a global `order_index`
//! that continues the entry's, and the same `(document_id, title, index)`
//! id derivation.

use std::collections::HashSet;

use uuid::Uuid;

use super::graph::BuildGraph;
use super::model::{ProjectTree, Target};
use super::scan::DepKind;
use crate::citations::extract::{extract_cite_keys, CitationSyntax, CiteKeyUsage};
use crate::sections::{section_id, ExtractedSection, SectionFormat};

/// A section with the file it lives in. Offsets are within that file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeSection {
    pub path: String,
    pub section: ExtractedSection,
}

/// A cite key usage with the file it lives in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeCitation {
    pub path: String,
    pub usage: CiteKeyUsage,
}

/// The files of `target`, entry first, each included file at the position
/// of its first include (depth-first), each file once. Only text splicing
/// (`Include`/`Import`) counts — an image or a bibliography is not text the
/// reader sees.
pub fn reading_order(tree: &ProjectTree, graph: &BuildGraph) -> Vec<String> {
    let mut order = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    fn visit(
        path: &str,
        tree: &ProjectTree,
        graph: &BuildGraph,
        seen: &mut HashSet<String>,
        order: &mut Vec<String>,
    ) {
        if !seen.insert(path.to_string()) {
            return;
        }
        if tree.text_of(path).is_none() {
            return;
        }
        order.push(path.to_string());
        let mut includes: Vec<_> = graph
            .deps
            .edges_from(path)
            .filter(|e| matches!(e.kind, DepKind::Include | DepKind::Import))
            .collect();
        includes.sort_by_key(|e| e.line);
        for edge in includes {
            visit(&edge.to, tree, graph, seen, order);
        }
    }
    visit(&graph.entry, tree, graph, &mut seen, &mut order);
    order
}

/// Every section of the target, in reading order, with global order
/// indices and ids derived like the one-file case.
pub fn sections_for_tree(
    tree: &ProjectTree,
    target: &Target,
    graph: &BuildGraph,
    document_id: Uuid,
) -> Vec<TreeSection> {
    let format = match tree.format.as_str() {
        "latex" => Some(SectionFormat::Latex),
        "typst" => Some(SectionFormat::Typst),
        _ => None,
    };
    let _ = target;
    let mut out = Vec::new();
    let mut global = 0usize;
    for path in reading_order(tree, graph) {
        let Some(text) = tree.text_of(&path) else {
            continue;
        };
        let file_format = tree
            .file(&path)
            .and_then(|f| f.format.as_deref())
            .and_then(|f| match f {
                "latex" => Some(SectionFormat::Latex),
                "typst" => Some(SectionFormat::Typst),
                _ => None,
            })
            .or(format);
        for mut section in crate::sections::extract(text, document_id, file_format) {
            section.order_index = global;
            section.id = section_id(document_id, &section.title, global);
            global += 1;
            out.push(TreeSection {
                path: path.clone(),
                section,
            });
        }
    }
    out
}

/// Every cite key usage in the target's reachable text files, reading
/// order first, then source order within a file.
pub fn citations_for_tree(tree: &ProjectTree, graph: &BuildGraph) -> Vec<TreeCitation> {
    let mut out = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut paths = reading_order(tree, graph);
    // Reachable text files that are not spliced in (a style file with a
    // `\cite` in a macro) still count, after the reading order.
    let mut rest: Vec<String> = graph
        .reachable
        .iter()
        .filter(|p| tree.text_of(p).is_some() && !paths.contains(p))
        .cloned()
        .collect();
    rest.sort();
    paths.append(&mut rest);
    for path in paths {
        if !seen.insert(path.clone()) {
            continue;
        }
        let Some(file) = tree.file(&path) else {
            continue;
        };
        let Some(text) = file.bytes.as_text() else {
            continue;
        };
        let syntax = match file.format.as_deref() {
            Some("latex") => CitationSyntax::Latex,
            Some("typst") | Some("markdown") => CitationSyntax::Typst,
            _ => continue,
        };
        let scanned = match file.format.as_deref() {
            Some("latex") => super::scan::blank_latex_comments(text),
            Some("typst") => {
                super::scan::blank_typst_strings(&super::scan::blank_typst_comments(text))
            }
            _ => super::scan::blank_markdown_comments(text),
        };
        for usage in extract_cite_keys(&scanned, syntax) {
            out.push(TreeCitation {
                path: path.clone(),
                usage,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::model::{FileRole, ProjectFile};

    #[test]
    fn sections_for_a_one_file_tree_match_extract() {
        let body = "= Intro\ntext\n== Sub\nmore\n= Methods\n";
        let doc = Uuid::new_v4();
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text("main.typ", FileRole::Main, body),
            vec![],
            vec![],
        );
        let graph = BuildGraph::derive(&tree, tree.default_target());
        let ours = sections_for_tree(&tree, tree.default_target(), &graph, doc);
        let theirs = crate::sections::extract(body, doc, Some(SectionFormat::Typst));
        assert_eq!(ours.len(), theirs.len());
        for (a, b) in ours.iter().zip(theirs.iter()) {
            assert_eq!(a.path, "main.typ");
            assert_eq!(&a.section, b, "byte-identical to the one-file extractor");
        }
    }

    #[test]
    fn chapters_are_spliced_in_reading_order_with_global_indices() {
        let doc = Uuid::new_v4();
        let tree = ProjectTree::new(
            "m",
            "T",
            "typst",
            ProjectFile::text(
                "main.typ",
                FileRole::Main,
                "= Title\n#include \"b.typ\"\n#include \"a.typ\"\n= Conclusion\n@last",
            ),
            vec![
                ProjectFile::text("a.typ", FileRole::Chapter, "== A section\n@ka"),
                ProjectFile::text(
                    "b.typ",
                    FileRole::Chapter,
                    "== B section\n#include \"c.typ\"\n@kb",
                ),
                ProjectFile::text("c.typ", FileRole::Chapter, "=== C deep\n@kc"),
                ProjectFile::text("orphan.typ", FileRole::Chapter, "== Never\n@never"),
            ],
            vec![],
        );
        let graph = BuildGraph::derive(&tree, tree.default_target());
        assert_eq!(
            reading_order(&tree, &graph),
            vec!["main.typ", "b.typ", "c.typ", "a.typ"]
        );

        let sections = sections_for_tree(&tree, tree.default_target(), &graph, doc);
        let titles: Vec<(String, String, usize)> = sections
            .iter()
            .map(|s| {
                (
                    s.path.clone(),
                    s.section.title.clone(),
                    s.section.order_index,
                )
            })
            .collect();
        // The entry's own sections keep their positions; included files
        // continue the count in the order they are read.
        assert_eq!(
            titles,
            vec![
                ("main.typ".into(), "Title".into(), 0),
                ("main.typ".into(), "Conclusion".into(), 1),
                ("b.typ".into(), "B section".into(), 2),
                ("c.typ".into(), "C deep".into(), 3),
                ("a.typ".into(), "A section".into(), 4),
            ]
        );
        assert_eq!(sections[3].section.id, section_id(doc, "C deep", 3));

        let cites: Vec<(String, String)> = citations_for_tree(&tree, &graph)
            .into_iter()
            .map(|c| (c.path, c.usage.key))
            .collect();
        assert_eq!(
            cites,
            vec![
                ("main.typ".into(), "last".into()),
                ("b.typ".into(), "kb".into()),
                ("c.typ".into(), "kc".into()),
                ("a.typ".into(), "ka".into()),
            ],
            "the orphan's key is not the manuscript's"
        );
    }
}
