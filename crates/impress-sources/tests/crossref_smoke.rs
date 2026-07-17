//! Smoke tests for the Crossref source client.

use impress_sources::{crossref::CrossrefSource, SearchQuery, SourcePlugin};
use std::path::Path;

#[tokio::test]
async fn crossref_parses_search_response_from_fixture() {
    let fixture = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/crossref_search.json"),
    )
    .expect("fixture present");

    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", mockito::Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(fixture)
        .create_async()
        .await;

    let source = CrossrefSource::with_base_url(server.url());
    let query = SearchQuery::new("supernova").with_limit(5);
    let result = source.search(&query, None).await.expect("search ok");

    assert_eq!(result.source, "crossref");
    assert_eq!(result.items.len(), 2);
    assert_eq!(result.total_estimated, Some(2));

    let first = &result.items[0];
    assert_eq!(first.doi.as_deref(), Some("10.1086/300499"));
    assert_eq!(first.year, Some(1998));
    assert_eq!(first.venue.as_deref(), Some("The Astronomical Journal"));
    assert_eq!(first.authors.len(), 2);
    assert_eq!(first.authors[0].family_name, "Riess");
    assert_eq!(first.authors[0].given_name.as_deref(), Some("Adam G."));
    // Abstract JATS tags should be stripped.
    assert!(first
        .abstract_text
        .as_ref()
        .map(|s| !s.contains("<jats:"))
        .unwrap_or(false));
    assert_eq!(
        first.pdf_url.as_deref(),
        Some("https://example.org/riess1998.pdf")
    );

    let second = &result.items[1];
    assert_eq!(second.year, Some(1999));
    assert_eq!(second.authors[0].family_name, "Perlmutter");
}

#[tokio::test]
async fn crossref_doi_fast_path_goes_to_works_endpoint() {
    // Same fixture body wrapped as a single-work response for /works/{doi}.
    let single_work = serde_json::json!({
        "status": "ok",
        "message-type": "work",
        "message": {
            "DOI": "10.1086/300499",
            "type": "journal-article",
            "title": ["Observational Evidence"],
            "author": [{"given": "Adam G.", "family": "Riess"}],
            "issued": {"date-parts": [[1998]]},
            "container-title": ["The Astronomical Journal"]
        }
    });

    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", mockito::Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(single_work.to_string())
        .create_async()
        .await;

    let source = CrossrefSource::with_base_url(server.url());
    // Bare DOI activates the fast-path.
    let query = SearchQuery::new("10.1086/300499");
    let result = source.search(&query, None).await.expect("search ok");

    assert_eq!(result.items.len(), 1);
    assert_eq!(result.items[0].doi.as_deref(), Some("10.1086/300499"));
}
