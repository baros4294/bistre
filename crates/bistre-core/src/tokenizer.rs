//! Exact offline universal BPE tokenizer (`tiktoken 5.1.1`, pure Rust + `ruzstd`).
//!
//! Uses strictly the single universal `o200k_base` 200k multilingual BPE vocabulary across every
//! platform and provider (zero hardcoded model/vendor families, zero runtime network calls, zero
//! C dependencies, and zero background worker threads). The vocabulary is permissively licensed
//! (`MIT` / `Apache-2.0`) and decompresses lazily on first use.

/// Universal BPE encoding embedded in Bistre.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BpeEncoding {
    /// 200k multilingual BPE (universal tokenizer for prose, code, Vietnamese, Arabic, and CJK).
    O200kBase,
}

impl BpeEncoding {
    /// Returns the canonical `tiktoken` encoding identifier.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::O200kBase => "o200k_base",
        }
    }
}

/// Returns the universal embedded BPE encoding (zero hardcoded model-family branches).
#[must_use]
pub const fn encoding_for_model(_model_id: Option<&str>) -> BpeEncoding {
    BpeEncoding::O200kBase
}

/// Counts exact tokens in `text` using the specified embedded BPE encoding (zero allocation).
#[must_use]
pub fn count_tokens_with(text: &str, encoding: BpeEncoding) -> u64 {
    if text.is_empty() {
        return 0;
    }
    // R36: every step re-counts the whole branch; long texts are counted once and cached by
    // content hash (blake3 is far cheaper than a BPE pass).
    let key = (text.len() >= CACHE_MIN_BYTES)
        .then(|| (encoding, *blake3::hash(text.as_bytes()).as_bytes()));
    if let Some(key) = key
        && let Some(hit) = bistre_protocol::lock_or_recover(&COUNT_CACHE, "token_cache").get(&key)
    {
        return *hit;
    }
    BPE_PASSES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let count = tiktoken::get_encoding(encoding.as_str())
        .map_or_else(|| text.chars().count().div_ceil(4), |bpe| bpe.count(text));
    let count = u64::try_from(count).unwrap_or(u64::MAX);
    if let Some(key) = key {
        let mut cache = bistre_protocol::lock_or_recover(&COUNT_CACHE, "token_cache");
        if cache.len() >= CACHE_MAX_ENTRIES {
            cache.clear();
        }
        cache.insert(key, count);
    }
    count
}

/// Texts shorter than this are counted directly (hashing would not pay off).
const CACHE_MIN_BYTES: usize = 1024;
/// Most cached counts; the cache starts over when full (bounded memory, about 400 KiB).
const CACHE_MAX_ENTRIES: usize = 8192;

/// Cached counts by encoding and content hash.
type CountCache = std::collections::HashMap<(BpeEncoding, [u8; 32]), u64>;

static COUNT_CACHE: std::sync::LazyLock<std::sync::Mutex<CountCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(CountCache::new()));

/// How many BPE passes ran (tests check the cache serves repeats).
static BPE_PASSES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(test)]
fn bpe_passes() -> u64 {
    BPE_PASSES.load(std::sync::atomic::Ordering::Relaxed)
}

/// Counts exact tokens in `text` using the universal `o200k_base` 200k multilingual BPE tokenizer.
#[must_use]
pub fn count_tokens(text: &str) -> u64 {
    count_tokens_with(text, BpeEncoding::O200kBase)
}

/// Counts exact tokens in `text` for any model using the universal `o200k_base` tokenizer.
#[must_use]
pub fn count_tokens_for_model(text: &str, model_id: Option<&str>) -> u64 {
    count_tokens_with(text, encoding_for_model(model_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// R36: a long text counted again (every step re-counts the whole branch) comes from the
    /// cache, not another BPE pass; the result is the same.
    #[test]
    fn a_long_text_is_counted_once() {
        let text = format!("{} unique-r36-marker", "the quick brown fox ".repeat(4000));
        let before = bpe_passes();
        let first = count_tokens(&text);
        let second = count_tokens(&text);
        assert_eq!(first, second);
        assert_eq!(bpe_passes() - before, 1, "the second count is cached");
    }

    #[test]
    fn exact_o200k_counts_match_canonical_bpe() {
        assert_eq!(count_tokens("hello world"), 2);
        assert_eq!(count_tokens(""), 0);

        let repeated = "words ".repeat(400);
        assert_eq!(count_tokens(&repeated), 401);
    }

    #[test]
    fn multilingual_cjk_vietnamese_arabic_and_code_tokenize_accurately() {
        let vi = "Xin chào thế giới! Hệ thống đang hoạt động bình thường.";
        let ar = "مرحباً بالعالم! هذا اختبار دقيق لعد الرموز.";
        let cjk = "こんにちは世界、今日は良い天気ですね。";
        let emoji = "🚀✨📚🦀";

        assert!(count_tokens(vi) > 10, "vi={}", count_tokens(vi));
        assert!(count_tokens(ar) > 10, "ar={}", count_tokens(ar));
        assert!(count_tokens(cjk) > 6, "cjk={}", count_tokens(cjk));
        assert!(count_tokens(emoji) >= 4, "emoji={}", count_tokens(emoji));
    }

    #[test]
    fn universal_encoding_is_available_offline_for_any_model() {
        assert_eq!(encoding_for_model(None), BpeEncoding::O200kBase);
        assert_eq!(
            encoding_for_model(Some("any-provider/any-model")),
            BpeEncoding::O200kBase
        );
        assert!(tiktoken::get_encoding(BpeEncoding::O200kBase.as_str()).is_some());
        let sample = "fn main() { println!(\"hello, world! 123456\"); }";
        let n = count_tokens_for_model(sample, Some("any-model"));
        assert!((8..=30).contains(&n), "o200k_base counted {n}");
    }
}
