//! Smoke tests for the OpenAlex source client.

use impress_sources::{openalex::OpenAlexSource, SearchQuery, SourcePlugin};
use std::path::Path;

#[tokio::test]
async fn openalex_parses_search_response_from_fixture() {
    let fixture = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/openalex_search.json"),
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

    let source = OpenAlexSource::with_base_url(server.url());
    let query = SearchQuery::new("supernova").with_limit(10);
    let result = source.search(&query, None).await.expect("search ok");

    assert_eq!(result.source, "openalex");
    assert_eq!(result.total_estimated, Some(1));
    assert_eq!(result.next_cursor.as_deref(), Some("abc123"));
    assert_eq!(result.items.len(), 1);

    let item = &result.items[0];
    assert_eq!(item.source_id, "W2106883861");
    assert_eq!(item.doi.as_deref(), Some("10.1086/300499"));
    assert_eq!(item.year, Some(1998));
    assert_eq!(item.venue.as_deref(), Some("The Astronomical Journal"));
    assert_eq!(item.authors.len(), 2);
    assert_eq!(item.authors[0].family_name, "Riess");
    assert_eq!(item.authors[0].given_name.as_deref(), Some("Adam G."));
    assert_eq!(
        item.authors[0].orcid.as_deref(),
        Some("https://orcid.org/0000-0002-6124-1196")
    );
    assert_eq!(
        item.pdf_url.as_deref(),
        Some("https://example.org/riess1998.pdf")
    );
    // Abstract gets reconstructed from inverted index.
    assert_eq!(
        item.abstract_text.as_deref(),
        Some("We present observations of supernovae.")
    );
}
