//! The `X-Crw-Paid-Rescue` header is what lets the search backend spend money
//! on a metered rescue tier. It must appear ONLY when the request carries the
//! entitlement, because the backend gate is a positive opt-in: a header that
//! leaks onto ordinary traffic bills for searches nobody authorised, and a
//! header that goes missing silently turns the rescue off with no error.
//!
//! Asserted against a real HTTP server rather than the request builder, so a
//! refactor that drops the header (or moves it to a query param, which would
//! also corrupt the backend's cache key) fails here.

use crw_search::{PAID_RESCUE_HEADER, SearxngClient, SearxngParams};
use std::sync::Arc;
use std::time::Duration;
use wiremock::matchers::{header_exists, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn body() -> serde_json::Value {
    serde_json::json!({"query": "q", "results": [], "unresponsive_engines": []})
}

fn params(paid_rescue: bool) -> SearxngParams {
    SearxngParams {
        q: "rust async".into(),
        paid_rescue,
        ..Default::default()
    }
}

#[tokio::test]
async fn header_is_sent_when_the_request_is_entitled() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search"))
        .and(header_exists(PAID_RESCUE_HEADER))
        .respond_with(ResponseTemplate::new(200).set_body_json(body()))
        .expect(1)
        .mount(&server)
        .await;

    let client = SearxngClient::new(
        Arc::new(reqwest::Client::new()),
        server.uri(),
        Duration::from_secs(5),
    );
    client
        .fetch(&params(true))
        .await
        .expect("fetch should succeed");
    // `expect(1)` is verified on drop.
}

#[tokio::test]
async fn header_is_absent_by_default() {
    // The default path must be byte-identical to before this feature existed —
    // that is what keeps self-host, the CLI, MCP and the research legs off a
    // metered tier.
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body()))
        .expect(1)
        .mount(&server)
        .await;

    let client = SearxngClient::new(
        Arc::new(reqwest::Client::new()),
        server.uri(),
        Duration::from_secs(5),
    );
    client
        .fetch(&params(false))
        .await
        .expect("fetch should succeed");

    let requests = server.received_requests().await.expect("recorded requests");
    assert_eq!(requests.len(), 1);
    assert!(
        requests[0].headers.get(PAID_RESCUE_HEADER).is_none(),
        "an unentitled request must not carry the paid-rescue header"
    );
}

#[tokio::test]
async fn entitlement_never_becomes_a_query_parameter() {
    // If it ever leaked into the query string it would split the backend cache
    // per caller class and stop two identical searches from sharing one answer.
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search"))
        .and(query_param("q", "rust async"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body()))
        .mount(&server)
        .await;

    let client = SearxngClient::new(
        Arc::new(reqwest::Client::new()),
        server.uri(),
        Duration::from_secs(5),
    );
    client
        .fetch(&params(true))
        .await
        .expect("fetch should succeed");

    let requests = server.received_requests().await.expect("recorded requests");
    let url = requests[0].url.as_str();
    assert!(
        !url.contains("paid_rescue") && !url.to_lowercase().contains("paid-rescue"),
        "entitlement must travel as a header only, got url: {url}"
    );
}
