//! Safe Linear-Time Rust `regex` pipeline (`display_only` | `prompt_outgoing` | `incoming_commit`).
//!
//! Guaranteed linear time via Rust's `regex` DFA/NFA engine (zero backtracking `ReDoS`) and
//! zero HTML/CSS/JS DOM injection (renders strictly as plain text / Sepia `TextSpan`).

use bistre_protocol::RegexRuleRecord;
use regex::Regex;

/// Applies all enabled `RegexRuleRecord` entries matching `scope` in deterministic `order_index` order.
/// Invalid user regex patterns are safely skipped without crashing or panicking.
pub fn apply_regex_pipeline(input: &str, rules: &[RegexRuleRecord], scope: &str) -> String {
    let mut ordered: Vec<&RegexRuleRecord> = rules
        .iter()
        .filter(|r| r.enabled && r.scope == scope && !r.pattern.trim().is_empty())
        .collect();
    ordered.sort_by_key(|r| r.order_index);

    let mut current = input.to_owned();
    for rule in ordered {
        if let Ok(re) = Regex::new(&rule.pattern) {
            current = re
                .replace_all(&current, rule.replacement.as_str())
                .into_owned();
        }
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_scoped_linear_time_regex_rules_safely() {
        let rules = vec![
            RegexRuleRecord {
                id: "r1".to_owned(),
                name: "Strip OOC".to_owned(),
                pattern: r"\(\(OOC:[^)]*\)\)".to_owned(),
                replacement: String::new(),
                scope: "display_only".to_owned(),
                enabled: true,
                order_index: 1,
            },
            RegexRuleRecord {
                id: "r2".to_owned(),
                name: "Invalid regex ignored".to_owned(),
                pattern: "[unclosed".to_owned(),
                replacement: "x".to_owned(),
                scope: "display_only".to_owned(),
                enabled: true,
                order_index: 2,
            },
        ];

        let out = apply_regex_pipeline("Hello ((OOC: pause)) world", &rules, "display_only");
        assert_eq!(out, "Hello  world");

        // Non-matching scope leaves text untouched.
        let untouched =
            apply_regex_pipeline("Hello ((OOC: pause)) world", &rules, "prompt_outgoing");
        assert_eq!(untouched, "Hello ((OOC: pause)) world");
    }
}
