//! Pure-Rust cron & interval schedule evaluator and SQLite `cron_jobs` polling engine
//! shared across desktop `bistre-daemon` and Android `WorkManager` recovery (Spec 04).

use std::path::{Path, PathBuf};

use bistre_protocol::{BistreError, BistreResult, CronJobRecord, DiagnosticKey};
use bistre_storage::StorageHandle;

use crate::agent::RunApprovalPolicy;
use crate::subagents::{SubagentSandbox, cleanup_worktree_sandbox, prepare_worktree_sandbox};
use crate::{BoxFuture, InProcessEngine};

/// Most scheduled-run worktrees kept under `<data dir>/scheduled_worktrees`; making one more
/// removes the oldest, so a frequent job cannot fill the disk.
pub const MAX_SCHEDULED_WORKTREES: usize = 8;

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

    let spec = CronSpec::parse(&trimmed)?;
    spec.next_after(from_unix_ms)
        .ok_or_else(|| BistreError::with_detail(DiagnosticKey::InvalidInput, "cron_never_matches"))
}

impl InProcessEngine {
    /// Starts the run a due job asks for (jobs were only marked "triggered"): a new chat named
    /// after the job, with its assistant and mode, sent the job's prompt under the job's
    /// unattended policy. Returns the chat id. A job with `use_worktree` works in a new
    /// worktree of the first workspace folder; with no folder, or when the worktree cannot be
    /// made, it works without one, and Sandbox auto then waits for approvals.
    pub fn start_scheduled_run(&self, job: CronJobRecord) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let assistant = (!job.assistant_id.trim().is_empty()).then(|| job.assistant_id.clone());
            // A job in a project starts its chat there, with the project's folder.
            let project = self.storage.get_project(&job.workspace_id)?.map(|p| p.id);
            let thread = self
                .create_thread(project, job.name.clone(), job.mode, None, assistant)
                .await?;
            let sandbox = if job.use_worktree {
                self.scheduled_worktree(&thread.id).await
            } else {
                None
            };
            self.refresh_stale_mcp_tools();
            self.send_with_stored_attachments_inner(
                thread.id.clone(),
                None,
                &job.prompt,
                &[],
                RunApprovalPolicy {
                    policy: job.unattended_policy,
                    sandbox,
                },
            )?;
            Ok(thread.id)
        })
    }

    async fn scheduled_worktree(&self, thread_id: &str) -> Option<PathBuf> {
        let roots = match crate::projects::workspace_roots_for(&self.storage, Some(thread_id)) {
            Ok(roots) => roots,
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "chat folders unreadable; no worktree"
                );
                return None;
            }
        };
        let root = roots.into_iter().next()?;
        let scratch = self.data_dir.join("scheduled_worktrees");
        prune_worktrees(&scratch, &root, MAX_SCHEDULED_WORKTREES - 1).await;
        match prepare_worktree_sandbox(&root, &scratch).await {
            Ok(sandbox) => Some(PathBuf::from(sandbox.sandbox_path)),
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    detail = err.detail_code.as_deref().unwrap_or(""),
                    "scheduled run worktree not made; the run works without one"
                );
                None
            }
        }
    }
}

/// Removes the oldest `wt-<uuid v7>` worktrees under `scratch` until at most `keep` remain.
/// A failed removal is logged and left for the next run.
async fn prune_worktrees(scratch: &Path, source_root: &Path, keep: usize) {
    let dir = scratch.to_path_buf();
    let git_marker = source_root.join(".git");
    let listed = crate::off_worker::blocking(move || {
        let used_git_worktree = git_marker.exists();
        let mut found = Vec::new();
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Ok((found, used_git_worktree));
            }
            Err(err) => {
                tracing::warn!(error = %err, "scheduled worktrees not listed");
                return Err(BistreError::with_detail(
                    DiagnosticKey::InternalError,
                    "worktree_list",
                ));
            }
        };
        for entry in entries {
            match entry {
                Ok(entry) if entry.file_name().to_string_lossy().starts_with("wt-") => {
                    found.push(entry.path());
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(error = %err, "scheduled worktree entry unreadable"),
            }
        }
        Ok((found, used_git_worktree))
    })
    .await;
    let (mut found, used_git_worktree) = match listed {
        Ok(listed) => listed,
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "old scheduled worktrees not pruned");
            return;
        }
    };
    // Version 7 ids sort by creation time.
    found.sort();
    let excess = found.len().saturating_sub(keep);
    for path in found.into_iter().take(excess) {
        let sandbox = SubagentSandbox {
            sandbox_id: String::new(),
            source_root: source_root.display().to_string(),
            sandbox_path: path.display().to_string(),
            used_git_worktree,
        };
        if let Err(err) = cleanup_worktree_sandbox(&sandbox).await {
            tracing::warn!(key = err.key.as_key(), "old scheduled worktree not removed");
        }
    }
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
            match compute_next_run_unix_ms(&job.schedule_expr, now_unix_ms) {
                Ok(next_ms) => {
                    job.next_run_ms = next_ms;
                    "triggered".clone_into(&mut job.last_status);
                    let updated = storage.upsert_cron_job(job)?;
                    due.push(updated);
                }
                // A bad schedule is an error, never "every hour": the job is turned off
                // and says why, and it does not fire.
                Err(err) => {
                    tracing::warn!(
                        key = err.key.as_key(),
                        detail = err.detail_code.as_deref().unwrap_or(""),
                        "cron job has an invalid schedule; turned off"
                    );
                    job.enabled = false;
                    "invalid_schedule".clone_into(&mut job.last_status);
                    storage.upsert_cron_job(job)?;
                }
            }
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

/// How far ahead a schedule is searched (four years covers every Feb 29).
const MAX_SEARCH_DAYS: i64 = 4 * 366;

/// A parsed 5-field UTC cron schedule (`min hour dom month dow`): each field is a set of
/// allowed values from `*`, `*/N`, `a`, `a-b`, `a-b/N` and comma lists. Day of week takes
/// 0-7 (0 and 7 are Sunday). When both day of month and day of week are restricted, a day
/// matching either fires, as in standard cron.
#[derive(Debug, Clone, Copy)]
struct CronSpec {
    minutes: u64,
    hours: u64,
    days: u64,
    months: u64,
    weekdays: u64,
    days_restricted: bool,
    weekdays_restricted: bool,
}

impl CronSpec {
    fn parse(expr: &str) -> BistreResult<Self> {
        let fields: Vec<&str> = expr.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "invalid_cron_expr",
            ));
        }
        let mut weekdays = parse_cron_field(fields[4], 0, 7)?;
        if weekdays & (1 << 7) != 0 {
            weekdays |= 1;
        }
        Ok(Self {
            minutes: parse_cron_field(fields[0], 0, 59)?,
            hours: parse_cron_field(fields[1], 0, 23)?,
            days: parse_cron_field(fields[2], 1, 31)?,
            months: parse_cron_field(fields[3], 1, 12)?,
            weekdays: weekdays & 0x7f,
            days_restricted: fields[2] != "*",
            weekdays_restricted: fields[4] != "*",
        })
    }

    fn day_matches(&self, day: u32, weekday: u32) -> bool {
        let dom = self.days & (1 << day) != 0;
        let dow = self.weekdays & (1 << weekday) != 0;
        match (self.days_restricted, self.weekdays_restricted) {
            (true, true) => dom || dow,
            (true, false) => dom,
            (false, true) => dow,
            (false, false) => true,
        }
    }

    /// The first matching minute strictly after `from_unix_ms`, within [`MAX_SEARCH_DAYS`].
    fn next_after(&self, from_unix_ms: i64) -> Option<i64> {
        let first_min = from_unix_ms.div_euclid(60_000).saturating_add(1);
        let start_day = first_min.div_euclid(1440);
        for day_offset in 0..=MAX_SEARCH_DAYS {
            let epoch_day = start_day.saturating_add(day_offset);
            let (_, month, day) = civil_from_days(epoch_day);
            // 1970-01-01 was a Thursday (weekday 4).
            let weekday = u32::try_from((epoch_day + 4).rem_euclid(7)).ok()?;
            if self.months & (1 << month) == 0 || !self.day_matches(day, weekday) {
                continue;
            }
            let day_start_min = epoch_day.saturating_mul(1440);
            let from_min_of_day = if day_offset == 0 {
                first_min - day_start_min
            } else {
                0
            };
            for hour in 0..24_i64 {
                if self.hours & (1 << hour) == 0 || (hour + 1) * 60 <= from_min_of_day {
                    continue;
                }
                for minute in 0..60_i64 {
                    let of_day = hour * 60 + minute;
                    if of_day >= from_min_of_day && self.minutes & (1 << minute) != 0 {
                        return Some(day_start_min.saturating_add(of_day).saturating_mul(60_000));
                    }
                }
            }
        }
        None
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
#[cfg(test)]
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The `(year, month, day)` of a day count since 1970-01-01 (inverse of [`days_from_civil`]).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = u32::try_from(doy - (153 * mp + 2) / 5 + 1).unwrap_or(1);
    let month = u32::try_from(if mp < 10 { mp + 3 } else { mp - 9 }).unwrap_or(1);
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// One cron field as a bit set of allowed values in `min..=max`.
fn parse_cron_field(raw: &str, min: u32, max: u32) -> BistreResult<u64> {
    let bad = |detail: &'static str| BistreError::with_detail(DiagnosticKey::InvalidInput, detail);
    let mut set = 0_u64;
    for part in raw.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => {
                let step: u32 = s.parse().map_err(|_| bad("cron_step"))?;
                if step == 0 || step > max {
                    return Err(bad("cron_step_range"));
                }
                (r, step)
            }
            None => (part, 1),
        };
        let (lo, hi) = if range == "*" {
            (min, max)
        } else if let Some((a, b)) = range.split_once('-') {
            let a: u32 = a.parse().map_err(|_| bad("cron_exact"))?;
            let b: u32 = b.parse().map_err(|_| bad("cron_exact"))?;
            (a, b)
        } else {
            let v: u32 = range.parse().map_err(|_| bad("cron_exact"))?;
            // `5/15` means "from 5 every 15"; a lone value is just that value.
            (v, if part.contains('/') { max } else { v })
        };
        if lo < min || hi > max || lo > hi {
            return Err(bad("cron_value_range"));
        }
        let mut v = lo;
        while v <= hi {
            set |= 1 << v;
            v = v.saturating_add(step);
        }
    }
    Ok(set)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::{ThreadMode, UnattendedPolicy};
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// Pruning keeps the newest worktrees (version 7 ids sort by time) and leaves other
    /// folders alone.
    #[tokio::test]
    async fn old_scheduled_worktrees_are_removed_beyond_the_cap() -> TestResult {
        let src = tempdir()?;
        let scratch = tempdir()?;
        let mut made = Vec::new();
        for _ in 0..MAX_SCHEDULED_WORKTREES + 2 {
            let path = scratch.path().join(format!("wt-{}", uuid::Uuid::now_v7()));
            std::fs::create_dir_all(&path)?;
            made.push(path);
        }
        std::fs::create_dir_all(scratch.path().join("keep-me"))?;
        prune_worktrees(scratch.path(), src.path(), MAX_SCHEDULED_WORKTREES - 1).await;
        let left: Vec<_> = made.iter().filter(|p| p.is_dir()).collect();
        assert_eq!(left.len(), MAX_SCHEDULED_WORKTREES - 1);
        assert!(!made[0].exists() && !made[2].exists() && made[3].exists());
        assert!(scratch.path().join("keep-me").is_dir());
        Ok(())
    }

    /// Unix ms of a UTC civil time (test helper).
    fn utc(y: i64, mo: u32, d: u32, h: i64, mi: i64) -> i64 {
        (days_from_civil(y, mo, d) * 1440 + h * 60 + mi) * 60_000
    }

    /// Every field of a 5-field schedule counts (day of month, month and day of week were
    /// ignored), including ranges, lists and steps; day of month and day of week combine with
    /// OR as in standard cron; leap days are found.
    #[test]
    fn all_five_cron_fields_are_honoured() -> TestResult {
        // Saturday 2026-11-28 10:00 -> weekdays at 09:30 -> Monday 2026-11-30 09:30.
        let sat = utc(2026, 11, 28, 10, 0);
        assert_eq!(
            compute_next_run_unix_ms("30 9 * * 1-5", sat)?,
            utc(2026, 11, 30, 9, 30)
        );
        // Midnight on the first of each month.
        assert_eq!(
            compute_next_run_unix_ms("0 0 1 * *", sat)?,
            utc(2026, 12, 1, 0, 0)
        );
        // Noon on Feb 29: the next leap day.
        assert_eq!(
            compute_next_run_unix_ms("0 12 29 2 *", sat)?,
            utc(2028, 2, 29, 12, 0)
        );
        // The 13th OR a Friday (Friday 2026-12-04 comes first).
        assert_eq!(
            compute_next_run_unix_ms("0 0 13 * 5", sat)?,
            utc(2026, 12, 4, 0, 0)
        );
        // Lists and stepped ranges; 7 is Sunday too.
        assert_eq!(
            compute_next_run_unix_ms("15,45 8-18/2 * * 7", sat)?,
            utc(2026, 11, 29, 8, 15)
        );
        for bad in [
            "61 * * * *",
            "* * 32 * *",
            "* * * 13 *",
            "5-1 * * * *",
            "* * * * * *",
        ] {
            assert!(compute_next_run_unix_ms(bad, sat).is_err(), "{bad}");
        }
        Ok(())
    }

    /// A job whose schedule is invalid is turned off and never fires (it used to become
    /// "every hour").
    #[test]
    fn a_bad_schedule_turns_its_job_off() -> TestResult {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("cron.sqlite"))?;
        let now = 1_700_000_000_000_i64;
        storage.upsert_cron_job(CronJobRecord {
            id: String::new(),
            name: "Broken".to_owned(),
            workspace_id: "default".to_owned(),
            assistant_id: "default_assistant".to_owned(),
            schedule_expr: "99 * * * *".to_owned(),
            prompt: "x".to_owned(),
            mode: ThreadMode::Chat,
            unattended_policy: UnattendedPolicy::PauseAndNotify,
            use_worktree: false,
            enabled: true,
            next_run_ms: now - 1,
            last_run_id: None,
            last_status: "idle".to_owned(),
        })?;
        assert_eq!(poll_due_cron_jobs(&storage, now)?.len(), 0);
        let job = storage.list_cron_jobs()?.into_iter().next().ok_or("job")?;
        assert!(!job.enabled);
        assert_eq!(job.last_status, "invalid_schedule");
        Ok(())
    }

    #[test]
    fn evaluates_intervals_and_five_field_cron_and_polls_due_jobs() -> TestResult {
        let base_ms = 1_700_000_000_000_i64;
        assert_eq!(
            compute_next_run_unix_ms("every 15m", base_ms)?,
            base_ms + 15 * 60_000
        );
        let next_cron = Some(compute_next_run_unix_ms("*/5 * * * *", base_ms)?);
        assert!(next_cron.is_some_and(|t| t > base_ms && ((t / 60_000) % 5 == 0)));
        assert!(compute_next_run_unix_ms("bad expr", base_ms).is_err());

        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("cron.sqlite"))?;

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

        let due = poll_due_cron_jobs(&storage, base_ms)?;
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].next_run_ms, base_ms + 30 * 60_000);
        assert_eq!(due[0].last_status, "triggered");

        // Second poll at the same timestamp must NOT double-fire.
        let due_again = poll_due_cron_jobs(&storage, base_ms)?;
        assert_eq!(due_again.len(), 0);
        Ok(())
    }
}
