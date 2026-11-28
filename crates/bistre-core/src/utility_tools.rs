//! Pure-Rust utility tools (`calc_eval`, `dice_roll`, `todo_write`, `ask_user`) with bounded
//! input/depth and fail-closed validation (Spec 04).

use std::collections::HashMap;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ThreadMode, ToolRiskTier};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::agent_tools::ToolPermission;
use crate::tools::ToolExecutionOutput;

const MAX_EXPR_LEN: usize = 512;
const MAX_EXPR_DEPTH: usize = 32;
const MAX_DICE_COUNT: u32 = 100;
const MAX_DICE_SIDES: u32 = 1_000;
const MAX_TODO_ITEMS: usize = 64;
const MAX_QUESTION_CHARS: usize = 2_000;
const MAX_ASK_OPTIONS: usize = 4;
const MAX_OPTION_CHARS: usize = 120;

/// What the model reads back after `ask_user`; the run then ends until the user writes.
pub const ASK_USER_RESULT: &str =
    "The user sees your question. Their answer arrives as their next message.";

/// A single structured task item stored per thread by `todo_write`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadTodoItem {
    pub id: String,
    pub content: String,
    pub status: String,
}

/// Collects all active built-in, workspace, skill, memory, utility, and computer-use schemas
/// for one run step (split out of `agent_tools.rs`).
pub fn collect_builtin_schemas<S: std::hash::BuildHasher>(
    storage: &StorageHandle,
    thread_mode: ThreadMode,
    has_workspace: bool,
    web_search_on: bool,
    policy_unreadable: bool,
    permissions: &HashMap<String, ToolPermission, S>,
) -> Vec<Value> {
    let mut schemas = Vec::new();
    let include_write_tools =
        has_workspace && thread_mode != ThreadMode::Plan && !policy_unreadable;
    for tool in crate::tools::builtin_tool_schemas(include_write_tools) {
        let Some(name) = tool.get("name").and_then(Value::as_str) else {
            continue;
        };
        if permissions.get(crate::agent_tools::permission_key(name)) == Some(&ToolPermission::Off) {
            continue;
        }
        let allow = match name {
            "web_search" => web_search_on,
            "web_fetch" => has_workspace || web_search_on,
            _ => has_workspace,
        };
        if allow {
            schemas.push(tool);
        }
    }
    if (has_workspace || crate::skill_install::has_app_skills(storage))
        && permissions.get("skill_load") != Some(&ToolPermission::Off)
    {
        schemas.push(crate::agent_context::skill_load_schema());
    }
    if has_workspace && permissions.get("ask_user") != Some(&ToolPermission::Off) {
        schemas.push(ask_user_schema());
    }
    if has_workspace
        && matches!(
            permissions.get("agent_delegate"),
            Some(ToolPermission::Allow | ToolPermission::Ask)
        )
    {
        schemas.push(crate::delegate::schema());
    }
    let memory_active = has_workspace
        || permissions
            .get("agent_memory")
            .is_some_and(|p| *p != ToolPermission::Off)
        || storage
            .list_memory_entries(None)
            .is_ok_and(|entries| !entries.is_empty());
    if thread_mode != ThreadMode::Write
        && memory_active
        && permissions.get("agent_memory") != Some(&ToolPermission::Off)
    {
        schemas.push(crate::agent_context::agent_memory_schema());
    }
    schemas.extend(enabled_schemas(thread_mode, permissions));
    if thread_mode != ThreadMode::Plan
        && thread_mode != ThreadMode::Write
        && !policy_unreadable
        && crate::computer_use::is_computer_use_enabled(storage)
        && permissions.get("computer_use") != Some(&ToolPermission::Off)
    {
        schemas.push(crate::computer_use::computer_use_schema(cfg!(
            target_os = "android"
        )));
    }
    schemas
}

fn ask_user_schema() -> Value {
    json!({
        "name": "ask_user",
        "description": format!("Ask the user one question and stop until they answer. Use it only when you cannot go on without their choice. Offer up to {MAX_ASK_OPTIONS} short options when the answer is one of a few."),
        "parameters": {
            "type": "object",
            "properties": {
                "question": { "type": "string", "description": "The question, in the user's language." },
                "options": { "type": "array", "items": { "type": "string" }, "description": "Optional short answers to pick from." }
            },
            "required": ["question"]
        }
    })
}

/// Returns tool schemas for enabled utility tools. Exposed only when explicitly permitted in
/// `permissions` (`Allow` or `Ask`) so default prompt-surface goldens remain stable.
pub fn enabled_schemas<S: std::hash::BuildHasher>(
    thread_mode: ThreadMode,
    permissions: &HashMap<String, ToolPermission, S>,
) -> Vec<Value> {
    let mut out = Vec::new();
    let is_on = |name: &str| {
        matches!(
            permissions.get(name),
            Some(ToolPermission::Allow | ToolPermission::Ask)
        )
    };
    if is_on("calc_eval") {
        out.push(json!({
            "name": "calc_eval",
            "description": "Evaluate a bounded arithmetic expression (+, -, *, /, ^, parentheses, sqrt, abs, floor, ceil, round, min, max).",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": { "type": "string", "description": "Arithmetic expression to evaluate." }
                },
                "required": ["expression"]
            }
        }));
    }
    if is_on("dice_roll") {
        out.push(json!({
            "name": "dice_roll",
            "description": "Roll tabletop dice using NdM[+K|-K] notation (e.g. 2d20+5, 1d100).",
            "parameters": {
                "type": "object",
                "properties": {
                    "notation": { "type": "string", "description": "Dice notation such as 2d6+3 or d20." }
                },
                "required": ["notation"]
            }
        }));
    }
    if thread_mode != ThreadMode::Write && is_on("todo_write") {
        out.push(json!({
            "name": "todo_write",
            "description": "Replace the structured task checklist for this chat (up to 64 items).",
            "parameters": {
                "type": "object",
                "properties": {
                    "items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": { "type": "string" },
                                "content": { "type": "string" },
                                "status": { "type": "string", "enum": ["pending", "in_progress", "completed"] }
                            },
                            "required": ["id", "content", "status"]
                        }
                    }
                },
                "required": ["items"]
            }
        }));
    }
    out
}

/// Dispatches `calc_eval`, `dice_roll`, `todo_write`, or `ask_user`.
pub fn dispatch(
    storage: &StorageHandle,
    thread_id: &str,
    tool_name: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    match tool_name {
        "calc_eval" => {
            let expr = args
                .get("expression")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let val = eval_expression(expr)?;
            let formatted = format_number(val);
            Ok(ToolExecutionOutput {
                tool_name: "calc_eval".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: format!("{expr} = {formatted}"),
                output_text: json!({ "expression": expr, "result": formatted }).to_string(),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "dice_roll" => {
            let notation = args
                .get("notation")
                .and_then(Value::as_str)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            let rolled = roll_dice_notation(notation)?;
            let output_text = serde_json::to_string(&rolled).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "dice_encode")
            })?;
            Ok(ToolExecutionOutput {
                tool_name: "dice_roll".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: format!("{} -> {}", rolled.notation, rolled.total),
                output_text,
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "todo_write" => {
            let raw_items = args
                .get("items")
                .and_then(Value::as_array)
                .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
            if raw_items.len() > MAX_TODO_ITEMS {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "todo_limit_exceeded",
                ));
            }
            let mut items = Vec::with_capacity(raw_items.len());
            for item in raw_items {
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                let content = item
                    .get("content")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                let status = item
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or("pending");
                if !matches!(status, "pending" | "in_progress" | "completed") {
                    return Err(BistreError::new(DiagnosticKey::InvalidInput));
                }
                items.push(ThreadTodoItem {
                    id: id.chars().take(64).collect(),
                    content: content.chars().take(512).collect(),
                    status: status.to_owned(),
                });
            }
            save_thread_todos(storage, thread_id, &items)?;
            let done = items.iter().filter(|i| i.status == "completed").count();
            Ok(ToolExecutionOutput {
                tool_name: "todo_write".to_owned(),
                risk_tier: ToolRiskTier::Tier0ReadOnly,
                ok: true,
                summary: format!("checklist updated ({done}/{})", items.len()),
                output_text: json!({
                    "count": items.len(),
                    "completed": done,
                    "items": items,
                })
                .to_string(),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
                media_attachments: Vec::new(),
            })
        }
        "ask_user" => ask_user(args),
        _ => Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "unknown_tool",
        )),
    }
}

/// Checks the question; the feed shows it and the run waits for the user's answer.
fn ask_user(args: &Value) -> BistreResult<ToolExecutionOutput> {
    let question = args
        .get("question")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|q| !q.is_empty() && q.chars().count() <= MAX_QUESTION_CHARS)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "question"))?;
    check_ask_options(args.get("options"))?;
    Ok(ToolExecutionOutput {
        tool_name: "ask_user".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: question.chars().take(MAX_OPTION_CHARS).collect(),
        output_text: ASK_USER_RESULT.to_owned(),
        diff_text: None,
        checkpoint_id: None,
        duration_ms: 0,
        media_attachments: Vec::new(),
    })
}

/// `ask_user` options: absent, or up to [`MAX_ASK_OPTIONS`] short non-empty strings.
fn check_ask_options(options: Option<&Value>) -> BistreResult<()> {
    let ok = match options {
        None | Some(Value::Null) => true,
        Some(Value::Array(items)) => {
            items.len() <= MAX_ASK_OPTIONS
                && items.iter().all(|item| {
                    item.as_str().is_some_and(|t| {
                        !t.trim().is_empty() && t.chars().count() <= MAX_OPTION_CHARS
                    })
                })
        }
        Some(_) => false,
    };
    if ok {
        Ok(())
    } else {
        Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "options",
        ))
    }
}

/// Saves structured checklist items for `thread_id` in `kv_meta`.
pub fn save_thread_todos(
    storage: &StorageHandle,
    thread_id: &str,
    items: &[ThreadTodoItem],
) -> BistreResult<()> {
    let encoded = serde_json::to_string(items)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "todo_encode"))?;
    storage.set_kv_meta(format!("thread_todos:{thread_id}"), encoded)
}

/// Loads structured checklist items for `thread_id` from `kv_meta`.
pub fn load_thread_todos(
    storage: &StorageHandle,
    thread_id: &str,
) -> BistreResult<Vec<ThreadTodoItem>> {
    let Some(raw) = storage.get_kv_meta(&format!("thread_todos:{thread_id}"))? else {
        return Ok(Vec::new());
    };
    serde_json::from_str(&raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "todo_decode"))
}

// --- Safe recursive-descent arithmetic parser ---

pub fn eval_expression(input: &str) -> BistreResult<f64> {
    let trimmed = input.trim();
    if trimmed.is_empty() || trimmed.len() > MAX_EXPR_LEN {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "calc_invalid_length",
        ));
    }
    let mut parser = ExprParser {
        bytes: trimmed.as_bytes(),
        pos: 0,
        depth: 0,
    };
    let val = parser.parse_add_sub()?;
    parser.skip_ws();
    if parser.pos != parser.bytes.len() || !val.is_finite() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "calc_syntax_error",
        ));
    }
    Ok(val)
}

struct ExprParser<'a> {
    bytes: &'a [u8],
    pos: usize,
    depth: usize,
}

impl ExprParser<'_> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn peek(&mut self) -> Option<u8> {
        self.skip_ws();
        self.bytes.get(self.pos).copied()
    }

    fn enter(&mut self) -> BistreResult<()> {
        self.depth += 1;
        if self.depth > MAX_EXPR_DEPTH {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "calc_depth_exceeded",
            ));
        }
        Ok(())
    }

    fn parse_add_sub(&mut self) -> BistreResult<f64> {
        self.enter()?;
        let mut lhs = self.parse_mul_div()?;
        loop {
            match self.peek() {
                Some(b'+') => {
                    self.pos += 1;
                    lhs += self.parse_mul_div()?;
                }
                Some(b'-') => {
                    self.pos += 1;
                    lhs -= self.parse_mul_div()?;
                }
                _ => break,
            }
        }
        self.depth -= 1;
        Ok(lhs)
    }

    fn parse_mul_div(&mut self) -> BistreResult<f64> {
        let mut lhs = self.parse_pow()?;
        loop {
            match self.peek() {
                Some(b'*') => {
                    self.pos += 1;
                    lhs *= self.parse_pow()?;
                }
                Some(b'/') => {
                    self.pos += 1;
                    let rhs = self.parse_pow()?;
                    if rhs == 0.0 {
                        return Err(BistreError::with_detail(
                            DiagnosticKey::InvalidInput,
                            "calc_divide_by_zero",
                        ));
                    }
                    lhs /= rhs;
                }
                _ => break,
            }
        }
        Ok(lhs)
    }

    fn parse_pow(&mut self) -> BistreResult<f64> {
        let base = self.parse_unary()?;
        if self.peek() == Some(b'^') {
            self.pos += 1;
            let exp = self.parse_pow()?;
            let res = base.powf(exp);
            if !res.is_finite() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "calc_overflow",
                ));
            }
            return Ok(res);
        }
        Ok(base)
    }

    fn parse_unary(&mut self) -> BistreResult<f64> {
        match self.peek() {
            Some(b'+') => {
                self.pos += 1;
                self.parse_unary()
            }
            Some(b'-') => {
                self.pos += 1;
                Ok(-self.parse_unary()?)
            }
            _ => self.parse_primary(),
        }
    }

    fn parse_primary(&mut self) -> BistreResult<f64> {
        match self.peek() {
            Some(b'(') => {
                self.pos += 1;
                let inner = self.parse_add_sub()?;
                if self.peek() != Some(b')') {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::InvalidInput,
                        "calc_unmatched_paren",
                    ));
                }
                self.pos += 1;
                Ok(inner)
            }
            Some(b) if b.is_ascii_digit() || b == b'.' => self.parse_number(),
            Some(b) if b.is_ascii_alphabetic() => self.parse_ident(),
            _ => Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "calc_unexpected_token",
            )),
        }
    }

    fn parse_number(&mut self) -> BistreResult<f64> {
        let start = self.pos;
        let mut saw_dot = false;
        while self.pos < self.bytes.len() {
            let b = self.bytes[self.pos];
            if b.is_ascii_digit() {
                self.pos += 1;
            } else if b == b'.' && !saw_dot {
                saw_dot = true;
                self.pos += 1;
            } else {
                break;
            }
        }
        let s = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| BistreError::new(DiagnosticKey::InvalidInput))?;
        s.parse::<f64>()
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "calc_bad_number"))
    }

    fn parse_ident(&mut self) -> BistreResult<f64> {
        let start = self.pos;
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_alphabetic() {
            self.pos += 1;
        }
        let ident = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| BistreError::new(DiagnosticKey::InvalidInput))?
            .to_ascii_lowercase();
        if ident == "pi" {
            return Ok(std::f64::consts::PI);
        }
        if ident == "e" {
            return Ok(std::f64::consts::E);
        }
        if self.peek() != Some(b'(') {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "calc_unknown_ident",
            ));
        }
        self.pos += 1;
        let mut args = vec![self.parse_add_sub()?];
        while self.peek() == Some(b',') {
            self.pos += 1;
            if args.len() >= 8 {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "calc_too_many_args",
                ));
            }
            args.push(self.parse_add_sub()?);
        }
        if self.peek() != Some(b')') {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "calc_unmatched_paren",
            ));
        }
        self.pos += 1;
        match (ident.as_str(), args.as_slice()) {
            ("sqrt", [x]) if *x >= 0.0 => Ok(x.sqrt()),
            ("abs", [x]) => Ok(x.abs()),
            ("floor", [x]) => Ok(x.floor()),
            ("ceil", [x]) => Ok(x.ceil()),
            ("round", [x]) => Ok(x.round()),
            ("min", [a, b]) => Ok(a.min(*b)),
            ("max", [a, b]) => Ok(a.max(*b)),
            _ => Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "calc_invalid_call",
            )),
        }
    }
}

fn format_number(val: f64) -> String {
    let rounded = val.round();
    if (val - rounded).abs() < 1e-12 && rounded.abs() < 1e15 {
        format!("{rounded:.0}")
    } else {
        let s = format!("{val:.10}");
        s.trim_end_matches('0').trim_end_matches('.').to_owned()
    }
}

// --- Safe RPG dice roller ---

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiceRollResult {
    pub notation: String,
    pub rolls: Vec<u32>,
    pub modifier: i32,
    pub total: i64,
}

/// Parses and rolls `NdM[+K|-K]` (e.g. `2d20+5`, `d6`, `4d8-1`).
pub fn roll_dice_notation(raw: &str) -> BistreResult<DiceRollResult> {
    let clean: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    let lower = clean.to_ascii_lowercase();
    let Some(d_pos) = lower.find('d') else {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "dice_invalid_notation",
        ));
    };
    let count_str = &lower[..d_pos];
    let count: u32 = if count_str.is_empty() {
        1
    } else {
        count_str.parse().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "dice_invalid_count")
        })?
    };
    if count == 0 || count > MAX_DICE_COUNT {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "dice_count_out_of_range",
        ));
    }
    let rest = &lower[d_pos + 1..];
    let mod_pos = rest.find(['+', '-']);
    let (sides_str, mod_str) = match mod_pos {
        Some(idx) => (&rest[..idx], Some(&rest[idx..])),
        None => (rest, None),
    };
    let sides: u32 = sides_str
        .parse()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "dice_invalid_sides"))?;
    if !(2..=MAX_DICE_SIDES).contains(&sides) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "dice_sides_out_of_range",
        ));
    }
    let modifier: i32 = match mod_str {
        Some(ms) => ms.parse().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "dice_invalid_modifier")
        })?,
        None => 0,
    };
    let mut rolls = Vec::with_capacity(usize::try_from(count).unwrap_or(1));
    let mut sum: i64 = 0;
    let sides_u64 = u64::from(sides);
    let zone = u64::MAX - (u64::MAX % sides_u64);
    let next_u64 = |idx: u32| -> u64 {
        let mut seed = Vec::with_capacity(20);
        seed.extend_from_slice(Uuid::now_v7().as_bytes());
        seed.extend_from_slice(&idx.to_le_bytes());
        let h = blake3::hash(&seed);
        let b = h.as_bytes();
        u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])
    };
    for i in 0..count {
        let mut raw = next_u64(i);
        let mut guard = 0_u32;
        while raw >= zone && guard < 16 {
            guard += 1;
            raw = next_u64(i.wrapping_add(guard.wrapping_mul(1_009)));
        }
        let r = u32::try_from((raw % sides_u64) + 1).unwrap_or(1);
        rolls.push(r);
        sum = sum.saturating_add(i64::from(r));
    }
    let total = sum.saturating_add(i64::from(modifier));
    Ok(DiceRollResult {
        notation: lower,
        rolls,
        modifier,
        total,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calc_eval_handles_precedence_functions_and_errors() -> Result<(), Box<dyn std::error::Error>>
    {
        assert_eq!(format_number(eval_expression("2 + 3 * 4")?), "14");
        assert_eq!(format_number(eval_expression("(2 + 3) * 4")?), "20");
        assert_eq!(format_number(eval_expression("2^3^2")?), "512");
        assert_eq!(format_number(eval_expression("sqrt(81) + abs(-3)")?), "12");
        assert_eq!(format_number(eval_expression("max(4, min(9, 7))")?), "7");
        assert!(eval_expression("10 / 0").is_err());
        assert!(eval_expression(&"(".repeat(40)).is_err());
        Ok(())
    }

    #[test]
    fn dice_roll_validates_bounds_and_sums_accurately() -> Result<(), Box<dyn std::error::Error>> {
        let r = roll_dice_notation("3d6 + 2")?;
        assert_eq!(r.rolls.len(), 3);
        assert!(r.rolls.iter().all(|&v| (1..=6).contains(&v)));
        let sum: i64 = r.rolls.iter().map(|&v| i64::from(v)).sum();
        assert_eq!(r.total, sum + 2);
        assert!(roll_dice_notation("0d6").is_err());
        assert!(roll_dice_notation("101d6").is_err());
        assert!(roll_dice_notation("2d1").is_err());
        Ok(())
    }

    #[test]
    fn todo_write_persists_and_caps_checklist_items() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("todo.sqlite"))?;
        let args = json!({
            "items": [
                { "id": "t1", "content": "Inspect WAL", "status": "completed" },
                { "id": "t2", "content": "Run checks", "status": "in_progress" }
            ]
        });
        let out = dispatch(&storage, "thread-1", "todo_write", &args)?;
        assert!(out.ok);
        let loaded = load_thread_todos(&storage, "thread-1")?;
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].status, "completed");

        let too_many: Vec<Value> = (0..65)
            .map(|i| json!({ "id": format!("t{i}"), "content": "item", "status": "pending" }))
            .collect();
        assert!(
            dispatch(
                &storage,
                "thread-1",
                "todo_write",
                &json!({ "items": too_many })
            )
            .is_err()
        );
        Ok(())
    }
}
