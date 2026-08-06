//! A request that never reached the provider is repeated; one that may have
//! been processed is not.

use crw_core::config::LlmConfig;
use crw_extract::llm::chat;
use serde_json::json;
use std::time::{Duration, Instant};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn responses_llm(base_url: String) -> LlmConfig {
    LlmConfig {
        provider: "openai-responses".into(),
        api_key: "test-key".into(),
        model: "test-model".into(),
        base_url: Some(base_url),
        max_tokens: 512,
        ..Default::default()
    }
}

/// A port nothing is listening on yet. Reserving and releasing a real socket is
/// the only way to name a port the OS agrees is free.
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .expect("reserve a port")
        .local_addr()
        .expect("port of the reserved socket")
        .port()
}

#[tokio::test]
async fn a_refused_connection_is_retried_and_then_succeeds() {
    let port = free_port();
    let llm = responses_llm(format!("http://127.0.0.1:{port}/v1"));

    // Nothing is listening, so the first attempt is refused. The server appears
    // while the call is backing off, well inside the ~0.5s first sleep.
    let call = tokio::spawn(async move { chat(&llm, "instructions", "input").await });

    tokio::time::sleep(Duration::from_millis(120)).await;
    let listener = std::net::TcpListener::bind(("127.0.0.1", port)).expect("bind the same port");
    let server = MockServer::builder().listener(listener).start().await;
    Mock::given(method("POST"))
        .and(path("/v1/responses"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "id": "resp_test",
            "status": "completed",
            "output": [{
                "type": "message",
                "role": "assistant",
                "content": [{ "type": "output_text", "text": "served on the retry" }]
            }]
        })))
        .mount(&server)
        .await;

    let result = call.await.expect("task joins").expect("retry recovers");
    assert_eq!(result.content, "served on the retry");
    assert_eq!(
        server.received_requests().await.unwrap().len(),
        1,
        "the refused attempt never reached the server, so exactly one request lands"
    );
}

#[tokio::test]
async fn a_dead_endpoint_still_gives_up() {
    let port = free_port();
    let llm = responses_llm(format!("http://127.0.0.1:{port}/v1"));

    let started = Instant::now();
    let err = chat(&llm, "instructions", "input")
        .await
        .expect_err("nothing ever listens, so the call fails");
    let elapsed = started.elapsed();

    assert!(
        err.to_string().contains("request failed"),
        "unexpected error: {err}"
    );
    // Two backoffs (~0.5s and ~1s, before jitter) separate the three attempts,
    // so giving up immediately would mean the retry never ran.
    assert!(
        elapsed >= Duration::from_millis(1400),
        "gave up after {elapsed:?}, so the attempts were not spaced by the backoff"
    );
}
