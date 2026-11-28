//! Unit tests for `voice.rs`.

use super::*;
use crate::live_voice::live_ws_target;

/// The app names no voice: read aloud and live voice both get the provider's default,
/// and a named voice is kept.
#[test]
fn an_unnamed_voice_is_the_providers_default() {
    assert_eq!(voice_or_default(ProviderDialect::GoogleGemini, ""), "Kore");
    assert_eq!(voice_or_default(ProviderDialect::OpenAi, " "), "alloy");
    assert_eq!(
        voice_or_default(ProviderDialect::OpenAi, " verse "),
        "verse"
    );
}

/// The Gemini key is URL-encoded into the documented `key` query, plain `ws`
/// to a public host is refused, and `OpenAI` keeps its base path with an encoded model.
#[test]
fn live_targets_encode_secrets_and_refuse_insecure_public_hosts() -> BistreResult<()> {
    let gemini = live_ws_target(
        ProviderDialect::GoogleGemini,
        "https://generativelanguage.googleapis.com/v1beta",
        "m",
        "a+b/c&d",
    )?;
    assert!(gemini.is_tls);
    assert_eq!(
        gemini.path_and_query,
        "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=a%2Bb%2Fc%26d"
    );
    assert_eq!(gemini.headers.len(), 0);

    let insecure = live_ws_target(
        ProviderDialect::GoogleGemini,
        "http://proxy.example.com/v1beta",
        "m",
        "secret",
    );
    assert_eq!(
        insecure.err().and_then(|e| e.detail_code).as_deref(),
        Some("live_insecure_transport")
    );
    assert!(
        live_ws_target(
            ProviderDialect::GoogleGemini,
            "http://127.0.0.1:9000",
            "m",
            "k"
        )
        .is_ok(),
        "a loopback test server may use plain ws"
    );

    let openai = live_ws_target(
        ProviderDialect::OpenAi,
        "https://gateway.example.com/openai/v1/",
        "gpt realtime&x",
        "sk",
    )?;
    assert_eq!(
        openai.path_and_query,
        "/openai/v1/realtime?model=gpt+realtime%26x"
    );
    Ok(())
}
