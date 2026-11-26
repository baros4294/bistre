//! Audited OS child-process containment shims (`ADR-0010`, Spec 04).
//!
//! `bistre-core` forbids `unsafe`, so the kernel calls that bind a child's lifetime to Bistre's
//! live here:
//! - **Windows**: [`KillOnCloseJob`] owns one anonymous Job Object per spawned child with
//!   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Descendants inherit the job, so terminating or dropping
//!   it kills the whole tree, and a crashed Bistre (whose handles the kernel closes) never leaves
//!   children running.
//! - **Linux / Android**: [`kill_with_parent`] installs `PR_SET_PDEATHSIG(SIGKILL)` between `fork`
//!   and `exec`, plus a parent-PID re-check so a parent that died during `fork` never leaves an
//!   orphan. The signal follows the spawning *thread*, so children must be spawned from
//!   long-lived runtime threads (Tokio workers), never from short-lived blocking-pool threads.

/// Exit code reported by processes killed through [`KillOnCloseJob::terminate`].
#[cfg(windows)]
pub const JOB_TERMINATED_EXIT_CODE: u32 = 1;

/// An owned anonymous Win32 Job Object whose members die when it is terminated or dropped.
#[cfg(windows)]
#[derive(Debug)]
pub struct KillOnCloseJob {
    /// Job `HANDLE` stored as an integer so the guard is `Send + Sync`; closed exactly once in `Drop`.
    handle: usize,
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 Job Object FFI for KILL_ON_JOB_CLOSE child containment (ADR-0010)."
)]
impl KillOnCloseJob {
    /// Creates a job configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and
    /// `JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION` (G5: a crashing child dies instead of
    /// showing the Windows fault dialog and hanging the run until its timeout).
    pub fn new() -> Option<Self> {
        use windows_sys::Win32::System::JobObjects::{
            CreateJobObjectW, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JobObjectExtendedLimitInformation, SetInformationJobObject,
        };

        // SAFETY: null attributes (non-inheritable) and a null name create an anonymous job.
        let raw = unsafe { CreateJobObjectW(core::ptr::null(), core::ptr::null()) };
        if raw.is_null() {
            return None;
        }
        let job = Self {
            handle: raw as usize,
        };
        // SAFETY: an all-zero JOBOBJECT_EXTENDED_LIMIT_INFORMATION is a valid "no limits" value
        // (plain integers, sizes, and a null affinity); only `LimitFlags` is set below.
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { core::mem::zeroed() };
        info.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        let len = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()).ok()?;
        // SAFETY: `raw` is a live job handle and `info` is a correctly sized
        // JOBOBJECT_EXTENDED_LIMIT_INFORMATION for the `JobObjectExtendedLimitInformation` class.
        let ok = unsafe {
            SetInformationJobObject(
                raw,
                JobObjectExtendedLimitInformation,
                (&raw const info).cast(),
                len,
            )
        };
        // On failure `job` drops here and closes the handle.
        (ok != 0).then_some(job)
    }

    /// The job's limit flags, as the kernel reports them (tests only).
    #[cfg(test)]
    fn limit_flags(&self) -> Option<u32> {
        use windows_sys::Win32::System::JobObjects::{
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            QueryInformationJobObject,
        };
        // SAFETY: all-zero is a valid value of this plain-data struct; the kernel fills it.
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { core::mem::zeroed() };
        let len = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()).ok()?;
        // SAFETY: a live job handle and a correctly sized buffer for this information class.
        let ok = unsafe {
            QueryInformationJobObject(
                self.raw(),
                JobObjectExtendedLimitInformation,
                (&raw mut info).cast(),
                len,
                core::ptr::null_mut(),
            )
        };
        (ok != 0).then_some(info.BasicLimitInformation.LimitFlags)
    }

    fn raw(&self) -> windows_sys::Win32::Foundation::HANDLE {
        self.handle as windows_sys::Win32::Foundation::HANDLE
    }

    /// Assigns a freshly spawned child (`tokio::process::Child::raw_handle`) to this job.
    /// Returns `false` when the kernel refuses (for example a parent job that forbids nesting).
    #[expect(
        clippy::not_unsafe_ptr_arg_deref,
        reason = "A process HANDLE is an opaque kernel token the kernel validates; it is never dereferenced."
    )]
    pub fn assign(&self, process_handle: std::os::windows::io::RawHandle) -> bool {
        use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;

        if process_handle.is_null() {
            return false;
        }
        // SAFETY: `self.raw()` is this guard's live job handle and `process_handle` is the caller's
        // open handle to a child that has not been reaped yet.
        unsafe { AssignProcessToJobObject(self.raw(), process_handle) != 0 }
    }

    /// Reports whether `process_handle` is a member of this job.
    #[expect(
        clippy::not_unsafe_ptr_arg_deref,
        reason = "A process HANDLE is an opaque kernel token the kernel validates; it is never dereferenced."
    )]
    pub fn contains(&self, process_handle: std::os::windows::io::RawHandle) -> bool {
        use windows_sys::Win32::System::JobObjects::IsProcessInJob;

        let mut result: windows_sys::core::BOOL = 0;
        // SAFETY: both handles are live for the call and `result` is a valid out-pointer.
        let ok = unsafe { IsProcessInJob(process_handle, self.raw(), &raw mut result) };
        ok != 0 && result != 0
    }

    /// Kills every process in the job (the child and all of its descendants).
    pub fn terminate(&self) -> bool {
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;

        // SAFETY: `self.raw()` is this guard's live job handle.
        unsafe { TerminateJobObject(self.raw(), JOB_TERMINATED_EXIT_CODE) != 0 }
    }
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited CloseHandle for the owned Job Object handle (ADR-0010)."
)]
impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;

        // SAFETY: the handle came from CreateJobObjectW and is closed exactly once, here. Closing
        // the last handle applies KILL_ON_JOB_CLOSE to any member still running.
        let closed = unsafe { CloseHandle(self.raw()) };
        debug_assert_ne!(closed, 0, "CloseHandle failed for an owned job handle");
    }
}

/// Installs `PR_SET_PDEATHSIG(SIGKILL)` on `cmd` so the child is killed when the spawning thread
/// (and therefore Bistre) dies, and refuses to `exec` if the parent already exited.
#[cfg(any(target_os = "linux", target_os = "android"))]
#[expect(
    unsafe_code,
    reason = "Audited pre_exec hook calling async-signal-safe prctl/getppid (ADR-0010)."
)]
pub fn kill_with_parent(cmd: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;

    let Ok(parent) = libc::pid_t::try_from(std::process::id()) else {
        return;
    };
    // SAFETY: the hook runs in the forked child before `exec` and only calls the async-signal-safe
    // `prctl` and `getppid`, allocating nothing (`from_raw_os_error` stores an integer).
    unsafe {
        cmd.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent {
                return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
            }
            Ok(())
        });
    }
}

#[cfg(test)]
mod tests {
    /// G5 (codex #63645): a child that crashes must not show the Windows fault dialog and hang
    /// the bounded run until its timeout; the job makes every process in it die instead.
    #[cfg(windows)]
    #[test]
    fn a_crashing_child_dies_instead_of_showing_a_fault_dialog() {
        use windows_sys::Win32::System::JobObjects::{
            JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };
        let flags = super::KillOnCloseJob::new().and_then(|j| j.limit_flags());
        let want = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        assert_eq!(flags.map(|f| f & want), Some(want), "{flags:?}");
    }

    #[cfg(windows)]
    #[test]
    fn job_objects_are_independent_and_reject_null_handles() {
        let a = super::KillOnCloseJob::new();
        let b = super::KillOnCloseJob::new();
        assert!(a.is_some() && b.is_some());
        assert_ne!(a.as_ref().map(|j| j.handle), b.as_ref().map(|j| j.handle));
        assert!(a.is_some_and(|j| !j.assign(core::ptr::null_mut()) && j.terminate()));
    }
}
