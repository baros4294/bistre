//! Exact offline multi-encoding BPE tokenizer (`tiktoken 5.1.1`, pure Rust + `ruzstd`).
//!
//! Covers `OpenAI` (`o200k_base`, `o200k_harmony`, `cl100k_base`), Alibaba Qwen (v2 and v3.5),
//! and Zhipu GLM (`glm4`, `glm5`) with zero runtime network calls, zero C dependencies, and zero
//! background worker threads (`parallel` feature disabled; honors Spec 11 zero idle threads).
//! All bundled vocabularies use strictly permissive SPDX licenses (`MIT` / `Apache-2.0`) and
//! decompress lazily on first use.

/// Exact BPE encoding families embedded in Bistre.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BpeEncoding {
    /// 200k multilingual BPE (default general-purpose tokenizer and modern `OpenAI` lineup).
    O200kBase,
    /// 200k harmony-format `OpenAI` BPE.
    O200kHarmony,
    /// 100k BPE (legacy `OpenAI` chat/embeddings, Llama 3 base vocabulary, close Claude proxy).
    Cl100kBase,
    /// Alibaba Qwen 2 / 2.5 / 3 / `QwQ` 151k BPE.
    Qwen2,
    /// Alibaba Qwen 3.5 248k BPE.
    Qwen35,
    /// Zhipu GLM-4 151k BPE.
    Glm4,
    /// Zhipu GLM-5 BPE.
    Glm5,
}

impl BpeEncoding {
    /// Resolves the canonical encoding name from [`tiktoken::list_encodings`].
    #[must_use]
    pub fn as_str(self) -> &'static str {
        let find_matching = |prefix: &str, suffix: &str| -> &'static str {
            tiktoken::list_encodings()
                .iter()
                .copied()
                .find(|name| name.starts_with(prefix) && name.ends_with(suffix))
                .unwrap_or("o200k_base")
        };
        match self {
            Self::O200kBase => "o200k_base",
            Self::O200kHarmony => "o200k_harmony",
            Self::Cl100kBase => "cl100k_base",
            Self::Qwen2 => find_matching("qwen", "2"),
            Self::Qwen35 => find_matching("qwen", "3_5"),
            Self::Glm4 => "glm4",
            Self::Glm5 => "glm5",
        }
    }
}

/// Normalizes a provider-qualified or tagged model identifier to its bare lowercase stem.
fn normalize_model_stem(raw: &str) -> &str {
    let trimmed = raw.trim();
    let without_ft = trimmed.strip_prefix("ft:").unwrap_or(trimmed);
    let after_slash = without_ft
        .rsplit_once('/')
        .map_or(without_ft, |(_, tail)| tail);
    let before_at = after_slash
        .split_once('@')
        .map_or(after_slash, |(head, _)| head);
    // Strip OpenRouter/Ollama tags like `:free` or `:latest` while keeping base model id.
    before_at
        .split_once(':')
        .map_or(before_at, |(head, _)| head)
}

/// Selects the closest exact embedded BPE encoding for `model_id`.
///
/// Delegates concrete model lookup to [`tiktoken::model_to_encoding`] so Bistre never hardcodes
/// volatile model IDs in runtime code, then falls back by generic vendor family before defaulting
/// to [`BpeEncoding::O200kBase`] (200k multilingual BPE).
#[must_use]
pub fn encoding_for_model(model_id: Option<&str>) -> BpeEncoding {
    let Some(raw) = model_id.map(str::trim).filter(|s| !s.is_empty()) else {
        return BpeEncoding::O200kBase;
    };
    let lower = normalize_model_stem(raw).to_ascii_lowercase();
    if let Some(name) = tiktoken::model_to_encoding(&lower) {
        return match name {
            "o200k_harmony" => BpeEncoding::O200kHarmony,
            "cl100k_base" => BpeEncoding::Cl100kBase,
            "glm5" => BpeEncoding::Glm5,
            "glm4" => BpeEncoding::Glm4,
            other if other.starts_with("llama") && other.ends_with('3') => BpeEncoding::Cl100kBase,
            other if other.starts_with("qwen") && other.ends_with("3_5") => BpeEncoding::Qwen35,
            other if other.starts_with("qwen") => BpeEncoding::Qwen2,
            _ => BpeEncoding::O200kBase,
        };
    }

    if lower.contains("harmony") {
        return BpeEncoding::O200kHarmony;
    }
    if lower.contains("qwen") || lower.contains("qwq") {
        return if lower.contains("3.5") || lower.contains("3_5") {
            BpeEncoding::Qwen35
        } else {
            BpeEncoding::Qwen2
        };
    }
    if lower.contains("glm") {
        return if lower.contains("glm5") || lower.contains("glm-5") {
            BpeEncoding::Glm5
        } else {
            BpeEncoding::Glm4
        };
    }
    if lower.contains("claude") {
        return BpeEncoding::Cl100kBase;
    }
    BpeEncoding::O200kBase
}

/// Counts exact tokens in `text` using the specified embedded BPE encoding (zero allocation).
#[must_use]
pub fn count_tokens_with(text: &str, encoding: BpeEncoding) -> u64 {
    if text.is_empty() {
        return 0;
    }
    let count = tiktoken::get_encoding(encoding.as_str())
        .map_or_else(|| text.chars().count().div_ceil(4), |bpe| bpe.count(text));
    u64::try_from(count).unwrap_or(u64::MAX)
}

/// Counts exact tokens in `text` using the default `o200k_base` 200k multilingual BPE tokenizer.
#[must_use]
pub fn count_tokens(text: &str) -> u64 {
    count_tokens_with(text, BpeEncoding::O200kBase)
}

/// Counts exact tokens in `text` using the best embedded BPE tokenizer for `model_id`.
#[must_use]
pub fn count_tokens_for_model(text: &str, model_id: Option<&str>) -> u64 {
    count_tokens_with(text, encoding_for_model(model_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_o200k_and_cl100k_counts_match_canonical_bpe() {
        // Canonical OpenAI tiktoken reference counts:
        // "hello world" -> [24912, 2375] (2 tokens in o200k_base and cl100k_base)
        assert_eq!(count_tokens("hello world"), 2);
        assert_eq!(count_tokens_with("hello world", BpeEncoding::Cl100kBase), 2);
        assert_eq!(count_tokens(""), 0);

        // Repeated common English word `"words ".repeat(400)` splits as `"words"` + 399 ×
        // `" words"` + trailing `" "` = 401 exact tokens in o200k_base (vs 600 under legacy len/4).
        let repeated = "words ".repeat(400);
        let bpe_count = count_tokens(&repeated);
        assert_eq!(bpe_count, 401);
    }

    #[test]
    fn multilingual_cjk_vietnamese_arabic_and_code_tokenize_accurately() {
        // Vietnamese with diacritics & Arabic & CJK produce real BPE subwords rather than
        // naive char/4 underestimation.
        let vi = "Xin chào thế giới! Hệ thống đang hoạt động bình thường.";
        let ar = "مرحباً بالعالم! هذا اختبار دقيق لعد الرموز.";
        let cjk = "こんにちは世界、今日は良い天気ですね。";
        let emoji = "🚀✨📚🦀";

        assert!(count_tokens(vi) > 10, "vi={}", count_tokens(vi));
        assert!(count_tokens(ar) > 10, "ar={}", count_tokens(ar));
        assert!(count_tokens(cjk) > 6, "cjk={}", count_tokens(cjk));
        // 4 multi-byte emoji take >= 4 BPE tokens (legacy chars/4 returned 1!).
        assert!(count_tokens(emoji) >= 4, "emoji={}", count_tokens(emoji));
    }

    #[test]
    fn model_family_routing_picks_vendor_exact_encodings() {
        assert_eq!(
            encoding_for_model(Some("openai/gpt-4o")),
            BpeEncoding::O200kBase
        );
        assert_eq!(encoding_for_model(Some("gpt-4")), BpeEncoding::Cl100kBase);
        assert_eq!(
            encoding_for_model(Some("anthropic/claude-sonnet-4")),
            BpeEncoding::Cl100kBase
        );
        assert_eq!(
            encoding_for_model(Some("qwen/qwen2.5-72b-instruct:free")),
            BpeEncoding::Qwen2
        );
        assert_eq!(
            encoding_for_model(Some("qwen/qwen3.5-plus")),
            BpeEncoding::Qwen35
        );
        assert_eq!(
            encoding_for_model(Some("z-ai/glm-4-plus")),
            BpeEncoding::Glm4
        );
        assert_eq!(encoding_for_model(Some("z-ai/glm-5")), BpeEncoding::Glm5);
        assert_eq!(
            encoding_for_model(Some("meta-llama/llama-3.3-70b-instruct")),
            BpeEncoding::Cl100kBase
        );
        assert_eq!(encoding_for_model(None), BpeEncoding::O200kBase);
    }

    #[test]
    fn all_embedded_encodings_are_available_offline() {
        let sample = "fn main() { println!(\"hello, world! 123456\"); }";
        for enc in [
            BpeEncoding::O200kBase,
            BpeEncoding::O200kHarmony,
            BpeEncoding::Cl100kBase,
            BpeEncoding::Qwen2,
            BpeEncoding::Qwen35,
            BpeEncoding::Glm4,
            BpeEncoding::Glm5,
        ] {
            assert!(
                tiktoken::get_encoding(enc.as_str()).is_some(),
                "missing embedded encoding {}",
                enc.as_str()
            );
            let n = count_tokens_with(sample, enc);
            assert!((8..=30).contains(&n), "{enc:?} counted {n}");
        }
    }
}
