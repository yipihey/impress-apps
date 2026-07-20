//! Smoke tests for the arXiv source client.
//!
//! Uses `mockito` to intercept the HTTP call so CI never hits arXiv.

use impress_sources::{arxiv::ArxivSource, SearchQuery, SourcePlugin};
use std::path::Path;

#[tokio::test]
async fn arxiv_parses_atom_feed_from_recorded_fixture() {
    let fixture = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/arxiv_search.xml"),
    )
    .expect("fixture present");

    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", mockito::Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/atom+xml")
        .with_body(fixture)
        .create_async()
        .await;

    let url = format!("{}/api/query", server.url());
    let source = ArxivSource::with_base_url(url);

    let query = SearchQuery::new("supernova").with_limit(2);
    let result = source.search(&query, None).await.expect("search ok");

    assert_eq!(result.source, "arxiv");
    assert_eq!(result.items.len(), 2);

    let first = &result.items[0];
    assert_eq!(first.arxiv_id.as_deref(), Some("2301.12345v1"));
    assert_eq!(first.doi.as_deref(), Some("10.1234/example.2023.001"));
    assert!(first.title.starts_with("A Study of Type Ia Supernovae"));
    assert_eq!(first.year, Some(2023));
    assert_eq!(first.authors.len(), 2);
    assert_eq!(first.authors[0].family_name, "Perlmutter");
    assert_eq!(first.authors[0].given_name.as_deref(), Some("Saul"));
    assert_eq!(
        first.pdf_url.as_deref(),
        Some("http://arxiv.org/pdf/2301.12345v1")
    );

    let second = &result.items[1];
    // Old-style hep-th id
    assert_eq!(second.arxiv_id.as_deref(), Some("hep-th/9901001"));
}
