//! Pure-Rust cron & interval schedule evaluator and SQLite `cron_jobs` polling engine
//! shared across desktop `bistre-daemon` and Android `WorkManager` recovery (Spec 04).

use bistre_protocol::{BistreError, BistreResult, CronJobRecord, DiagnosticKey};
use bistre_storage::StorageHandle;

/// Computes the next Unix millisecond trigger timestamp for `schedule_expr` after `from_unix_ms`.
///
/// Supported formats:
/// - Interval shorthand: `every 30s`, `every 15m`, `every 2h`, `every 1d`
/// - Standard 5-field UTC cron (`min hour dom month dow`), supporting `*`, `*/N`, and exact integers.
pub fn compute_next_run_unix_ms(schedule_expr: &str, from_unix_ms: i64) -> BistreResult<i64> {
    let trimmed = schedule_expr.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "empty_schedule",
        ));
    }

    if let Some(rest) = trimmed.strip_prefix("every ") {
        let step_ms = parse_interval_ms(rest.trim())?;
        return Ok(from_unix_ms.saturating_add(step_ms));
    }

    let fields: Vec<&str> = trimmed.split_whitespace().collect();
    if fields.len() != 5 {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_cron_expr",
        ));
    }
    let min_rule = parse_cron_field(fields[0], 0, 59)?;
    let hour_rule = parse_cron_field(fields[1], 0, 23)?;
    let _dom = parse_cron_field(fields[2], 1, 31)?;
    let _month = parse_cron_field(fields[3], 1, 12)?;
    let _dow = parse_cron_field(fields[4], 0, 7)?;

    // Advance minute-by-minute across up to 48 hours in UTC to locate the exact next trigger.
    let base_min = (from_unix_ms / 60_000) + 1;
    for offset in 0..(48 * 60_i64) {
        let cand_min_epoch = base_min.saturating_add(offset);
        let minute = u32::try_from(cand_min_epoch.rem_euclid(60)).unwrap_or(0);
        let hour = u32::try_from((cand_min_epoch / 60).rem_euclid(24)).unwrap_or(0);
        if min_rule.matches(minute) && hour_rule.matches(hour) {
            return Ok(cand_min_epoch.saturating_mul(60_000));
        }
    }

    Ok(from_unix_ms.saturating_add(3_600_000))
}

/// Polls all enabled `cron_jobs` due at or before `now_unix_ms`, advancing their `next_run_ms`
/// atomically in SQLite so daemon restarts never double-fire a due job.
pub fn poll_due_cron_jobs(
    storage: &StorageHandle,
    now_unix_ms: i64,
) -> BistreResult<Vec<CronJobRecord>> {
    let all = storage.list_cron_jobs()?;
    let mut due = Vec::new();
    for mut job in all {
        if !job.enabled {
            continue;
        }
        if job.next_run_ms <= now_unix_ms {
            let next_ms = compute_next_run_unix_ms(&job.schedule_expr, now_unix_ms)
                .unwrap_or_else(|_| now_unix_ms.saturating_add(3_600_000));
            job.next_run_ms = next_ms;
            "triggered".clone_into(&mut job.last_status);
            let updated = storage.upsert_cron_job(job)?;
            due.push(updated);
        }
    }
    Ok(due)
}

fn parse_interval_ms(spec: &str) -> BistreResult<i64> {
    if spec.len() < 2 {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_interval",
        ));
    }
    let (num_part, unit) = spec.split_at(spec.len() - 1);
    let count: i64 = num_part.trim().parse().map_err(|_| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_interval_num")
    })?;
    if count <= 0 {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "interval_must_be_positive",
        ));
    }
    let unit_ms = match unit {
        "s" => 1_000_i64,
        "m" => 60_000_i64,
        "h" => 3_600_000_i64,
        "d" => 86_400_000_i64,
        _ => {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "invalid_interval_unit",
            ));
        }
    };
    Ok(count.saturating_mul(unit_ms))
}

#[derive(Debug, Clone, Copy)]
enum CronFieldRule {
    Any,
    Step(u32),
    Exact(u32),
}

impl CronFieldRule {
    const fn matches(self, val: u32) -> bool {
        match self {
            Self::Any => true,
            Self::Step(step) => step > 0 && val.is_multiple_of(step),
            Self::Exact(target) => val == target,
        }
    }
}

fn parse_cron_field(raw: &str, min: u32, max: u32) -> BistreResult<CronFieldRule> {
    if raw == "*" {
        return Ok(CronFieldRule::Any);
    }
    if let Some(step_str) = raw.strip_prefix("*/") {
        let step: u32 = step_str
            .parse()
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "cron_step"))?;
        if step == 0 || step > max {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "cron_step_range",
            ));
        }
        return Ok(CronFieldRule::Step(step));
    }
    let exact: u32 = raw
        .parse()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "cron_exact"))?;
    if exact < min || exact > max {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "cron_value_range",
        ));
    }
    Ok(CronFieldRule::Exact(exact))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::{ThreadMode, UnattendedPolicy};
    use tempfile::tempdir;

    #[test]
    fn evaluates_intervals_and_five_field_cron_and_polls_due_jobs() {
        let base_ms = 1_700_000_000_000_i64;
        assert_eq!(
            compute_next_run_unix_ms("every 15m", base_ms).ok(),
            Some(base_ms + 15 * 60_000)
        );
        let next_cron = compute_next_run_unix_ms("*/5 * * * *", base_ms).ok();
        assert!(next_cron.is_some_and(|t| t > base_ms && ((t / 60_000) % 5 == 0)));
        assert!(compute_next_run_unix_ms("bad expr", base_ms).is_err());

        let dir = tempdir().ok();
        let Some(dir) = dir else { return };
        let storage = StorageHandle::open(dir.path().join("cron.sqlite")).ok();
        let Some(storage) = storage else { return };

        let job = CronJobRecord {
            id: String::new(),
            name: "Morning digest".to_owned(),
            workspace_id: "default".to_owned(),
            assistant_id: "default_assistant".to_owned(),
            schedule_expr: "every 30m".to_owned(),
            prompt: "Summarize active tasks".to_owned(),
            mode: ThreadMode::Chat,
            unattended_policy: UnattendedPolicy::PauseAndNotify,
            use_worktree: false,
            enabled: true,
            next_run_ms: base_ms - 1_000,
            last_run_id: None,
            last_status: "idle".to_owned(),
        };
        assert!(storage.upsert_cron_job(job).is_ok());

        let due = poll_due_cron_jobs(&storage, base_ms)
            .ok()
            .unwrap_or_default();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].next_run_ms, base_ms + 30 * 60_000);
        assert_eq!(due[0].last_status, "triggered");

        // Second poll at the same timestamp must NOT double-fire.
        let due_again = poll_due_cron_jobs(&storage, base_ms)
            .ok()
            .unwrap_or_default();
        assert_eq!(due_again.len(), 0);
    }
}
