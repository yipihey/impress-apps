//! Smoke tests for the NASA ADS source client.

use impress_sources::{ads::AdsSource, SearchQuery, SourcePlugin};
use std::path::Path;

#[tokio::test]
async fn ads_parses_search_response_from_fixture() {
    let fixture = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ads_search.json"),
    )
    .expect("fixture present");

    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", mockito::Matcher::Any)
        .match_header("authorization", "Bearer dummy-token")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(fixture)
        .create_async()
        .await;

    let source = AdsSource::with_base_url(server.url());
    let query = SearchQuery::new("supernova").with_limit(10);
    let result = source
        .search(&query, Some("dummy-token"))
        .await
        .expect("search ok");

    assert_eq!(result.source, "ads");
    assert_eq!(result.total_estimated, Some(1));
    assert_eq!(result.items.len(), 1);

    let item = &result.items[0];
    assert_eq!(item.source_id, "1998AJ....116.1009R");
    assert_eq!(item.doi.as_deref(), Some("10.1086/300499"));
    assert_eq!(item.arxiv_id.as_deref(), Some("astro-ph/9805201"));
    assert_eq!(item.year, Some(1998));
    assert_eq!(item.venue.as_deref(), Some("The Astronomical Journal"));
    assert_eq!(item.authors.len(), 3);
    assert_eq!(item.authors[0].family_name, "Riess");
    assert_eq!(item.authors[0].given_name.as_deref(), Some("Adam G."));
}

#[tokio::test]
async fn ads_search_without_credentials_errors() {
    let source = AdsSource::with_base_url("http://127.0.0.1:1");
    let result = source.search(&SearchQuery::new("foo"), None).await;
    assert!(matches!(
        result,
        Err(impress_sources::SourceError::AuthenticationRequired(_))
    ));
}
