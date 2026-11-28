//! Video jobs a restart cut off (ADR-0009, ADR-0019). A submitted job's id is kept until its
//! turn ends, so the next launch books the job's cost (the provider bills a job it accepted)
//! and Try again on that message fetches the same job instead of paying for a new one.

use std::sync::Arc;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, MoneyMicros};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};

use crate::media_wire::VideoApi;

const JOBS_KEY: &str = "media.video_jobs";

/// Most jobs kept; a newer one pushes out the oldest.
const MAX_VIDEO_JOBS: usize = 16;

/// How long after its start a cut-off job is fetched on Try again; an older one is dropped
/// at launch (its cost stays booked).
const MAX_RESUME_AGE_MS: i64 = 24 * 60 * 60 * 1000;

/// One submitted video job, keyed by the user message it answers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct VideoJob {
    pub(crate) run_id: String,
    pub(crate) thread_id: String,
    pub(crate) parent_id: String,
    pub(crate) provider_id: String,
    pub(crate) model: String,
    pub(crate) api: VideoApi,
    pub(crate) job: String,
    /// The reservation the job was sent under, booked as its cost when a restart cuts it off.
    pub(crate) booked_micros: i64,
    pub(crate) started_ms: i64,
    /// Whether a launch already booked the cost; only a booked job is resumed.
    #[serde(default)]
    pub(crate) booked: bool,
}

fn load(storage: &StorageHandle) -> BistreResult<Vec<VideoJob>> {
    let Some(raw) = storage.get_kv_meta(JOBS_KEY)? else {
        return Ok(Vec::new());
    };
    serde_json::from_str(&raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageIoError, "video_jobs_parse"))
}

fn save(storage: &StorageHandle, jobs: &[VideoJob]) -> BistreResult<()> {
    if jobs.is_empty() {
        return storage.delete_kv_meta(JOBS_KEY.to_owned());
    }
    let raw = serde_json::to_string(jobs)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageIoError, "video_jobs_write"))?;
    storage.set_kv_meta(JOBS_KEY.to_owned(), raw)
}

/// Keeps `job` until [`forget`]; it replaces any job kept for the same message.
pub(crate) fn keep(storage: &StorageHandle, job: VideoJob) -> BistreResult<()> {
    let mut jobs = load(storage)?;
    jobs.retain(|j| j.parent_id != job.parent_id);
    jobs.push(job);
    let extra = jobs.len().saturating_sub(MAX_VIDEO_JOBS);
    jobs.drain(..extra);
    save(storage, &jobs)
}

/// Drops the job kept for the message `parent_id`, once its turn has ended.
pub(crate) fn forget(storage: &StorageHandle, parent_id: &str) -> BistreResult<()> {
    let mut jobs = load(storage)?;
    let before = jobs.len();
    jobs.retain(|j| j.parent_id != parent_id);
    if jobs.len() == before {
        return Ok(());
    }
    save(storage, &jobs)
}

/// Marks the job kept for `parent_id` as booked: its turn settled the cost as it stopped.
pub(crate) fn mark_booked(storage: &StorageHandle, parent_id: &str) -> BistreResult<()> {
    let mut jobs = load(storage)?;
    let Some(job) = jobs
        .iter_mut()
        .find(|j| j.parent_id == parent_id && !j.booked)
    else {
        return Ok(());
    };
    job.booked = true;
    save(storage, &jobs)
}

/// A booked job a stop or restart cut off that answers the same message with the same model.
pub(crate) fn resumable(
    storage: &StorageHandle,
    parent_id: &str,
    provider_id: &str,
    model: &str,
    now_ms: i64,
) -> BistreResult<Option<VideoJob>> {
    Ok(load(storage)?.into_iter().find(|j| {
        j.booked
            && j.parent_id == parent_id
            && j.provider_id == provider_id
            && j.model == model
            && now_ms.saturating_sub(j.started_ms) < MAX_RESUME_AGE_MS
    }))
}

/// At launch, after the stale reservations are released: books each cut-off job's cost under
/// its turn's request id (so a turn that settled before the restart is not booked twice) and
/// drops jobs past [`MAX_RESUME_AGE_MS`]. Returns how many were booked.
pub(crate) fn book_cut_off(storage: &Arc<StorageHandle>, now_ms: i64) -> BistreResult<usize> {
    let mut jobs = load(storage)?;
    if jobs.is_empty() {
        return Ok(0);
    }
    let mut booked = 0;
    for job in jobs.iter_mut().filter(|j| !j.booked) {
        let cost = MoneyMicros::from_micros(job.booked_micros);
        // No ceiling: the provider already accepted the job, so the cost is owed.
        crate::wallet::SpendReservation::reserve(
            storage,
            Some(job.thread_id.clone()),
            job.provider_id.clone(),
            job.model.clone(),
            cost,
            None,
            0,
        )?
        .settle_for_request(
            Some(format!("{}:media:0", job.run_id)),
            cost,
            0,
            0,
            "unconfirmed".to_owned(),
        )?;
        job.booked = true;
        booked += 1;
    }
    jobs.retain(|j| now_ms.saturating_sub(j.started_ms) < MAX_RESUME_AGE_MS);
    save(storage, &jobs)?;
    Ok(booked)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(parent: &str, started_ms: i64) -> VideoJob {
        VideoJob {
            run_id: format!("run-{parent}"),
            thread_id: "t".to_owned(),
            parent_id: parent.to_owned(),
            provider_id: "p".to_owned(),
            model: "v".to_owned(),
            api: VideoApi::Videos,
            job: format!("job-{parent}"),
            booked_micros: 400_000,
            started_ms,
            booked: false,
        }
    }

    /// A cut-off job is booked once at launch, even across two launches, becomes resumable
    /// for its own message and model only, and is dropped after its turn or once too old.
    #[test]
    fn a_cut_off_video_job_is_booked_once_then_resumed() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("jobs.sqlite"))?;
        let now = 10 * MAX_RESUME_AGE_MS;
        keep(&storage, job("u1", now - 1_000))?;
        keep(&storage, job("old", now - MAX_RESUME_AGE_MS))?;
        assert_eq!(
            resumable(&storage, "u1", "p", "v", now)?,
            None,
            "not booked yet"
        );
        assert_eq!(book_cut_off(&storage, now)?, 2);
        assert_eq!(
            book_cut_off(&storage, now)?,
            0,
            "a second launch books nothing"
        );
        assert_eq!(
            storage.sum_wallet_spend_since_micros(0)?,
            MoneyMicros::from_micros(800_000)
        );
        let resumed = resumable(&storage, "u1", "p", "v", now)?;
        assert_eq!(resumed.map(|j| j.job), Some("job-u1".to_owned()));
        assert_eq!(resumable(&storage, "u1", "p", "other", now)?, None);
        assert_eq!(resumable(&storage, "old", "p", "v", now)?, None, "dropped");
        forget(&storage, "u1")?;
        assert_eq!(resumable(&storage, "u1", "p", "v", now)?, None);
        assert_eq!(storage.get_kv_meta(JOBS_KEY)?, None);
        Ok(())
    }

    /// A turn that settled before the restart keeps a single booking.
    #[test]
    fn a_job_settled_before_the_restart_is_not_booked_twice()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("jobs.sqlite"))?;
        let cut = job("u2", 0);
        crate::wallet::SpendReservation::reserve(
            &storage,
            Some("t".to_owned()),
            "p".to_owned(),
            "v".to_owned(),
            MoneyMicros::from_micros(400_000),
            None,
            0,
        )?
        .settle_for_request(
            Some(format!("{}:media:0", cut.run_id)),
            MoneyMicros::from_micros(400_000),
            0,
            0,
            "settled".to_owned(),
        )?;
        keep(&storage, cut)?;
        book_cut_off(&storage, 1)?;
        assert_eq!(
            storage.sum_wallet_spend_since_micros(0)?,
            MoneyMicros::from_micros(400_000)
        );
        Ok(())
    }
}
