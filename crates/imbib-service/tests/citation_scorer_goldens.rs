//! The 98 goldens recorded from imbib's Swift scorer (work package S2a,
//! `fixtures/citation-scorer-goldens.json`; the decisions that look wrong are
//! in `fixtures/citation-scorer-NOTES.md`) reproduce through the path
//! `imbib-sources-service_resolve-citation` runs: koine's cascade
//! (`koine_sources::cascade::resolve`) with `Scorer::legacy()` over the
//! sources, as `imbib_service::sources::resolve_citation` drives it. The
//! Swift scorer is deleted; this is what proves the Rust path matches it.
//! koine's own `scorer_goldens.rs` pins the scorer alone; this pins the
//! cascade's step 3 (search, score, accept, keep) around it.

use std::collections::BTreeMap;

use koine_sources::cascade::{self, Identifier, LocalLookup, RemoteSearch, Via};
use koine_sources::kind::{Author, Issued, Provenance, Work};
use koine_sources::{CitationInput, Scorer};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct GoldenCandidate {
    title: String,
    authors: Vec<String>,
    year: Option<i32>,
    venue: Option<String>,
    doi: Option<String>,
    arxiv: Option<String>,
    bibcode: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Case {
    name: String,
    citation: CitationInput,
    candidates: Vec<GoldenCandidate>,
    scores: Vec<f64>,
    accepted: Option<usize>,
    rule: Option<String>,
    #[serde(default)]
    kept: Vec<usize>,
}

fn cases() -> Vec<Case> {
    let cases: Vec<Case> =
        serde_json::from_str(include_str!("fixtures/citation-scorer-goldens.json")).unwrap();
    assert_eq!(cases.len(), 98);
    cases
}

fn author(s: &str) -> Author {
    match s.split_once(',') {
        Some((f, g)) => Author {
            family: Some(f.trim().to_string()),
            given: Some(g.trim().to_string()),
            orcid: None,
        },
        None => Author {
            family: Some(s.to_string()),
            given: None,
            orcid: None,
        },
    }
}

/// The candidate as a source would answer it; its position travels in the
/// provenance so a kept row maps back to the golden's index.
fn work(index: usize, c: &GoldenCandidate) -> Work {
    let mut ids = BTreeMap::new();
    for (k, v) in [
        ("doi", &c.doi),
        ("arxiv", &c.arxiv),
        ("bibcode", &c.bibcode),
    ] {
        if let Some(v) = v {
            ids.insert(k.to_string(), v.clone());
        }
    }
    Work {
        ty: "article-journal".into(),
        title: Some(c.title.clone()),
        author: c.authors.iter().map(|a| author(a)).collect(),
        issued: c.year.map(|y| Issued {
            date_parts: vec![vec![y]],
        }),
        container_title: c.venue.clone(),
        doi: c.doi.clone(),
        ids,
        provenance: Some(Provenance {
            fetched_at: String::new(),
            source: "golden".into(),
            source_id: index.to_string(),
            query: None,
            sources: vec![],
        }),
        ..Work::default()
    }
}

/// An empty library: the goldens are the search step's.
struct NoLibrary;

impl LocalLookup for NoLibrary {
    fn by_identifier(&self, _id: &Identifier) -> Option<Work> {
        None
    }
    fn search_text(&self, _query: &str, _limit: usize) -> Vec<Work> {
        vec![]
    }
}

/// The sources answer the golden's candidates to any search and have no
/// record for an identifier (so a citation that names one falls through to
/// the search step, as the goldens recorded it).
struct GoldenSources {
    works: Vec<Work>,
}

impl RemoteSearch for GoldenSources {
    fn fetch(&self, _id: &Identifier) -> Option<Work> {
        None
    }
    fn search(&self, _citation: &CitationInput, _limit: usize) -> Vec<Work> {
        self.works.clone()
    }
}

fn index_of(w: &Work) -> usize {
    w.provenance
        .as_ref()
        .and_then(|p| p.source_id.parse().ok())
        .expect("a golden index")
}

#[test]
fn the_cascade_with_the_legacy_scorer_reproduces_every_golden_decision() {
    let scorer = Scorer::legacy();
    for c in cases() {
        let works: Vec<Work> = c
            .candidates
            .iter()
            .enumerate()
            .map(|(i, cand)| work(i, cand))
            .collect();
        let remote = GoldenSources { works };
        let resolution = cascade::resolve(&scorer, &c.citation, &NoLibrary, &remote);

        // What the cascade kept, in rank order, as golden indices.
        let kept: Vec<usize> = resolution
            .candidates
            .iter()
            .map(|k| index_of(&k.work))
            .collect();
        assert_eq!(kept, c.kept, "{} kept", c.name);
        for k in &resolution.candidates {
            let i = index_of(&k.work);
            assert!(
                (k.score - c.scores[i]).abs() < 1e-12,
                "{}: candidate {i} scored {} (golden {})",
                c.name,
                k.score,
                c.scores[i]
            );
        }
        match c.accepted {
            Some(golden_top) => {
                assert_eq!(resolution.via, Via::Search, "{} via", c.name);
                assert_eq!(resolution.accepted, Some(0), "{} accepted", c.name);
                assert_eq!(kept.first().copied(), Some(golden_top), "{} top", c.name);
            }
            None => {
                assert_eq!(resolution.accepted, None, "{} accepted", c.name);
                assert!(
                    matches!(resolution.via, Via::Search | Via::NotFound),
                    "{} via {:?}",
                    c.name,
                    resolution.via
                );
            }
        }
        assert_eq!(
            resolution.rule.map(|r| r.as_str().to_string()),
            c.rule,
            "{} rule",
            c.name
        );
    }
}
