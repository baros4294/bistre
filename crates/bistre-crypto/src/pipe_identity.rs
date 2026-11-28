//! Audited identity checks for the local daemon IPC channel (ADR-0003).
//!
//! The daemon endpoint name is derived from the data directory, so another local user can
//! predict it. Two checks keep the channel private to the signed-in user:
//! - **Server**: [`OwnerOnlyPipeSecurity`] is a security descriptor that grants the pipe only
//!   to the current user and `SYSTEM` (protected DACL, so nothing is inherited), passed to
//!   every pipe instance the daemon creates.
//! - **Client**: [`pipe_server_is_current_user`] asks the kernel which process serves the pipe
//!   and compares that process's user SID with ours, so a pipe squatted by another account is
//!   refused before any request (and its steering text) is written. On Unix,
//!   [`current_uid`] lets the client compare the socket peer's uid.

#[cfg(windows)]
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

#[cfg(windows)]
fn denied(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::DaemonUnavailable, detail)
}

/// A self-relative security descriptor granting the pipe to the current user and `SYSTEM`.
#[cfg(windows)]
pub struct OwnerOnlyPipeSecurity {
    /// `PSECURITY_DESCRIPTOR` from `LocalAlloc`, freed exactly once in `Drop`.
    descriptor: usize,
    /// Boxed so the pointer handed to the kernel stays stable for this value's lifetime.
    attributes: Box<windows_sys::Win32::Security::SECURITY_ATTRIBUTES>,
}

#[cfg(windows)]
impl core::fmt::Debug for OwnerOnlyPipeSecurity {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("OwnerOnlyPipeSecurity")
            .finish_non_exhaustive()
    }
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited: the owned security descriptor is immutable and freed once (R29)."
)]
// SAFETY: the descriptor is an immutable heap block owned by this value and only read by the
// kernel; it is freed once, in `Drop`.
unsafe impl Send for OwnerOnlyPipeSecurity {}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 token/SDDL FFI for owner-only daemon pipes (R29, ADR-0003)."
)]
impl OwnerOnlyPipeSecurity {
    /// Builds `D:P(A;;GA;;;<current user SID>)(A;;GA;;;SY)`.
    pub fn new() -> BistreResult<Self> {
        use windows_sys::Win32::Security::Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
        };
        use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;

        let sid = current_user_sid_string()?;
        let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)")
            .encode_utf16()
            .chain(core::iter::once(0))
            .collect();
        let mut descriptor: *mut core::ffi::c_void = core::ptr::null_mut();
        // SAFETY: `sddl` is a NUL-terminated UTF-16 string that outlives the call; the
        // descriptor out-pointer is valid and the size out-pointer may be null.
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &raw mut descriptor,
                core::ptr::null_mut(),
            )
        };
        if ok == 0 || descriptor.is_null() {
            return Err(denied("pipe_security_descriptor"));
        }
        let len = u32::try_from(size_of::<SECURITY_ATTRIBUTES>())
            .map_err(|_| denied("pipe_security_descriptor"))?;
        Ok(Self {
            descriptor: descriptor as usize,
            attributes: Box::new(SECURITY_ATTRIBUTES {
                nLength: len,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            }),
        })
    }

    /// The `SECURITY_ATTRIBUTES*` for `CreateNamedPipeW`, valid while `self` lives.
    pub fn as_raw_attributes(&mut self) -> *mut core::ffi::c_void {
        (&raw mut *self.attributes).cast()
    }
}

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited: frees the LocalAlloc'd security descriptor exactly once (R29)."
)]
impl Drop for OwnerOnlyPipeSecurity {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::LocalFree;
        // SAFETY: `descriptor` came from ConvertStringSecurityDescriptorToSecurityDescriptorW
        // (LocalAlloc) and is freed only here.
        unsafe { LocalFree(self.descriptor as *mut core::ffi::c_void) };
    }
}

/// Owned Win32 `HANDLE`, closed on drop.
#[cfg(windows)]
struct OwnedHandle(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited: closes an owned Win32 handle exactly once."
)]
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: the handle was returned open by OpenProcess/OpenProcessToken and is owned here.
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

/// The `TOKEN_USER` of `process`'s primary token, in an 8-byte-aligned buffer.
#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 token query FFI for daemon pipe identity (R29)."
)]
fn token_user(process: windows_sys::Win32::Foundation::HANDLE) -> BistreResult<Vec<u64>> {
    use windows_sys::Win32::Security::{GetTokenInformation, TOKEN_QUERY, TokenUser};
    use windows_sys::Win32::System::Threading::OpenProcessToken;

    let mut token: windows_sys::Win32::Foundation::HANDLE = core::ptr::null_mut();
    // SAFETY: `process` is a live process handle with query access; `token` is a valid out-pointer.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &raw mut token) } == 0 {
        return Err(denied("pipe_token_open"));
    }
    let token = OwnedHandle(token);
    let mut needed = 0_u32;
    // SAFETY: a null buffer with length 0 asks only for the required size.
    unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            core::ptr::null_mut(),
            0,
            &raw mut needed,
        )
    };
    if needed == 0 || needed > 4096 {
        return Err(denied("pipe_token_size"));
    }
    // `u64` words keep the TOKEN_USER header aligned.
    let words = (needed as usize).div_ceil(8);
    let mut buf = vec![0_u64; words];
    let byte_len = u32::try_from(words * 8).map_err(|_| denied("pipe_token_size"))?;
    // SAFETY: `buf` is writable, 8-byte aligned, and at least `needed` bytes long.
    let ok = unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buf.as_mut_ptr().cast(),
            byte_len,
            &raw mut needed,
        )
    };
    if ok == 0 {
        return Err(denied("pipe_token_query"));
    }
    Ok(buf)
}

/// The current user's SID in string form (`S-1-5-21-...`).
#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 SID-to-string FFI for the owner-only pipe DACL (R29)."
)]
fn current_user_sid_string() -> BistreResult<String> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::TOKEN_USER;
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    // SAFETY: GetCurrentProcess returns a pseudo-handle that needs no closing.
    let aligned = token_user(unsafe { GetCurrentProcess() })?;
    // SAFETY: the buffer holds a TOKEN_USER written by GetTokenInformation and is aligned.
    let user = unsafe { &*aligned.as_ptr().cast::<TOKEN_USER>() };
    let mut wide: *mut u16 = core::ptr::null_mut();
    // SAFETY: `user.User.Sid` points into `aligned`, which is alive; `wide` is a valid out-pointer.
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &raw mut wide) } == 0 || wide.is_null() {
        return Err(denied("pipe_sid_string"));
    }
    let mut len = 0_usize;
    // SAFETY: ConvertSidToStringSidW returns a NUL-terminated UTF-16 string.
    while unsafe { *wide.add(len) } != 0 && len < 256 {
        len += 1;
    }
    // SAFETY: `len` UTF-16 units starting at `wide` were just walked and are initialized.
    let text = String::from_utf16(unsafe { core::slice::from_raw_parts(wide, len) })
        .map_err(|_| denied("pipe_sid_string"));
    // SAFETY: the string was allocated by ConvertSidToStringSidW with LocalAlloc.
    unsafe { LocalFree(wide.cast()) };
    text
}

/// Whether the process serving `pipe` runs as the current user.
///
/// Fails closed: any lookup error is an `Err`, which the caller treats as "do not talk".
#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited Win32 named-pipe server identity FFI (R29, ADR-0003)."
)]
pub fn pipe_server_is_current_user(pipe: std::os::windows::io::RawHandle) -> BistreResult<bool> {
    use windows_sys::Win32::Security::{EqualSid, TOKEN_USER};
    use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    let mut server_pid = 0_u32;
    // SAFETY: `pipe` is the live client end of a named pipe; `server_pid` is a valid out-pointer.
    if unsafe { GetNamedPipeServerProcessId(pipe.cast(), &raw mut server_pid) } == 0 {
        return Err(denied("pipe_server_pid"));
    }
    // SAFETY: OpenProcess with limited query rights on a PID; null means failure.
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, server_pid) };
    if process.is_null() {
        return Err(denied("pipe_server_open"));
    }
    let process = OwnedHandle(process);
    let theirs = token_user(process.0)?;
    // SAFETY: GetCurrentProcess returns a pseudo-handle that needs no closing.
    let mine = token_user(unsafe { GetCurrentProcess() })?;
    let (a, b) = (theirs, mine);
    // SAFETY: both buffers hold aligned TOKEN_USER values that stay alive for these reads.
    let same = unsafe {
        let ua = &*a.as_ptr().cast::<TOKEN_USER>();
        let ub = &*b.as_ptr().cast::<TOKEN_USER>();
        EqualSid(ua.User.Sid, ub.User.Sid)
    };
    Ok(same != 0)
}

/// The calling process's real user id (Unix), for comparing a socket peer's credentials.
#[cfg(unix)]
#[expect(
    unsafe_code,
    reason = "Audited: getuid has no preconditions and cannot fail."
)]
pub fn current_uid() -> u32 {
    // SAFETY: getuid takes no arguments, has no preconditions, and always succeeds.
    unsafe { libc::getuid() }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn the_owner_only_descriptor_names_the_current_user() -> BistreResult<()> {
        let sid = current_user_sid_string()?;
        assert!(sid.starts_with("S-1-"), "{sid}");
        let mut security = OwnerOnlyPipeSecurity::new()?;
        assert!(!security.as_raw_attributes().is_null());
        Ok(())
    }
}
