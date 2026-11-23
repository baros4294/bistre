//! Windows Modern Standby (S0ix) & S3 power-request inhibitor and suspend/resume listener.
//!
//! Uses `PowerCreateRequest` with BOTH `PowerRequestSystemRequired` (`[SYSTEM]`) and
//! `PowerRequestExecutionRequired` (`[EXECUTION]`), plus opt-in `PowerRequestDisplayRequired`
//! when the user explicitly enables `windows_keep_awake_on_battery` in Settings.
//! Subscribes to `PowerRegisterSuspendResumeNotification` for `PBT_APMSUSPEND` /
//! `PBT_APMRESUMEAUTOMATIC` events so active runs flush to SQLite WAL before forced lid-close
//! sleep and reconcile immediately on wake.

#![cfg(windows)]

use std::sync::{Arc, Mutex};

use bistre_core::power::{PowerCoordinator, PowerGuardBackend, PowerLeasePolicy};
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, SystemPowerEvent};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Power::{
    DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS, GetSystemPowerStatus, HPOWERNOTIFY, POWER_REQUEST_TYPE,
    PowerClearRequest, PowerCreateRequest, PowerRegisterSuspendResumeNotification,
    PowerRequestDisplayRequired, PowerRequestExecutionRequired, PowerRequestSystemRequired,
    PowerSetRequest, PowerUnregisterSuspendResumeNotification, SYSTEM_POWER_STATUS,
};
use windows_sys::Win32::System::SystemServices::POWER_REQUEST_CONTEXT_VERSION;
use windows_sys::Win32::System::Threading::{
    POWER_REQUEST_CONTEXT_SIMPLE_STRING, REASON_CONTEXT, REASON_CONTEXT_0,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DEVICE_NOTIFY_CALLBACK, PBT_APMRESUMEAUTOMATIC, PBT_APMRESUMESUSPEND, PBT_APMSUSPEND,
};

#[derive(Debug)]
struct ActiveHandle {
    raw: isize,
    display_held: bool,
}

/// Win32 power-request inhibitor registered into `bistre-core`'s `PowerCoordinator`.
#[derive(Debug, Default)]
pub(crate) struct Win32PowerGuard {
    active: Mutex<Option<ActiveHandle>>,
}

impl Win32PowerGuard {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

impl Drop for Win32PowerGuard {
    fn drop(&mut self) {
        self.release();
    }
}

impl PowerGuardBackend for Win32PowerGuard {
    fn platform_name(&self) -> &'static str {
        "windows"
    }

    #[expect(
        unsafe_code,
        reason = "Audited Win32 PowerCreateRequest/PowerSetRequest FFI shim isolated to bistre-daemon."
    )]
    fn acquire(&self, policy: PowerLeasePolicy, reason: &str) -> BistreResult<bool> {
        self.release();
        if !policy.keep_awake_while_running {
            return Ok(false);
        }

        let mut wide_reason: Vec<u16> = reason.encode_utf16().chain(core::iter::once(0)).collect();
        let ctx = REASON_CONTEXT {
            Version: POWER_REQUEST_CONTEXT_VERSION,
            Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
            Reason: REASON_CONTEXT_0 {
                SimpleReasonString: wide_reason.as_mut_ptr(),
            },
        };

        // SAFETY: `ctx` points to a valid NUL-terminated UTF-16 string buffer `wide_reason`
        // that lives across the `PowerCreateRequest` call. Returned handle is owned by `ActiveHandle`
        // and freed deterministically on `release()` / `Drop`.
        let handle: HANDLE = unsafe { PowerCreateRequest(&raw const ctx) };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(BistreError::new(DiagnosticKey::PowerGuardDegraded));
        }

        // SAFETY: `handle` was just returned valid by `PowerCreateRequest`.
        let sys_ok = unsafe { PowerSetRequest(handle, PowerRequestSystemRequired) } != 0;
        // SAFETY: `handle` is valid; ExecutionRequired prevents PLM process suspension on Modern Standby.
        let exec_ok = unsafe { PowerSetRequest(handle, PowerRequestExecutionRequired) } != 0;
        let display_held = if policy.windows_keep_awake_on_battery {
            // SAFETY: Opt-in battery override requested explicitly by user Settings toggle.
            let ok = unsafe { PowerSetRequest(handle, PowerRequestDisplayRequired) };
            ok != 0
        } else {
            false
        };

        if !sys_ok && !exec_ok {
            // SAFETY: Close unused handle on total failure.
            unsafe {
                if CloseHandle(handle) == 0 {
                    tracing::debug!("power request handle close failed");
                }
            }
            return Err(BistreError::new(DiagnosticKey::PowerGuardDegraded));
        }

        if let Ok(mut guard) = self.active.lock() {
            *guard = Some(ActiveHandle {
                raw: handle as isize,
                display_held,
            });
        }
        Ok(true)
    }

    #[expect(
        unsafe_code,
        reason = "Audited Win32 PowerClearRequest/CloseHandle FFI cleanup isolated to bistre-daemon."
    )]
    fn release(&self) {
        let taken = self.active.lock().ok().and_then(|mut g| g.take());
        if let Some(active) = taken {
            let handle = active.raw as HANDLE;
            // SAFETY: `handle` is a valid non-null power request handle owned exclusively by `active`.
            unsafe {
                clear_if_set(handle, PowerRequestSystemRequired);
                clear_if_set(handle, PowerRequestExecutionRequired);
                if active.display_held {
                    clear_if_set(handle, PowerRequestDisplayRequired);
                }
                if CloseHandle(handle) == 0 {
                    tracing::debug!("power request handle close failed");
                }
            }
        }
    }

    #[expect(
        unsafe_code,
        reason = "Audited Win32 GetSystemPowerStatus read-only query isolated to bistre-daemon."
    )]
    fn is_on_ac_power(&self) -> bool {
        let mut status = SYSTEM_POWER_STATUS {
            ACLineStatus: 255,
            BatteryFlag: 0,
            BatteryLifePercent: 255,
            SystemStatusFlag: 0,
            BatteryLifeTime: u32::MAX,
            BatteryFullLifeTime: u32::MAX,
        };
        // SAFETY: `status` is a properly aligned, stack-allocated `SYSTEM_POWER_STATUS` struct.
        let ok = unsafe { GetSystemPowerStatus(&raw mut status) };
        if ok == 0 {
            return true;
        }
        // `1` = Online (AC), `0` = Offline (DC battery), `255` = Unknown (desktop).
        status.ACLineStatus != 0
    }
}

#[expect(
    unsafe_code,
    reason = "Helper invoking Win32 PowerClearRequest on an owned handle."
)]
unsafe fn clear_if_set(handle: HANDLE, req: POWER_REQUEST_TYPE) {
    // SAFETY: Caller guarantees `handle` is a live handle returned by `PowerCreateRequest`.
    unsafe {
        if PowerClearRequest(handle, req) == 0 {
            tracing::debug!("power request was not set");
        }
    }
}

/// RAII registration guard delivering Windows suspend/resume broadcasts to `PowerCoordinator`.
#[derive(Debug)]
pub(crate) struct Win32SuspendWatcher {
    reg_handle: isize,
    ctx_ptr: usize,
}

impl Win32SuspendWatcher {
    /// Registers a Win32 suspend/resume callback forwarding `PBT_APMSUSPEND` & `PBT_APMRESUME*`.
    #[expect(
        unsafe_code,
        reason = "Audited Win32 PowerRegisterSuspendResumeNotification callback isolated to bistre-daemon."
    )]
    pub(crate) fn register(coordinator: Arc<PowerCoordinator>) -> Option<Self> {
        let boxed = Box::new(coordinator);
        let ctx_raw = Box::into_raw(boxed);
        let mut params = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
            Callback: Some(suspend_resume_callback),
            Context: ctx_raw.cast(),
        };
        let mut reg_handle: *mut core::ffi::c_void = core::ptr::null_mut();

        // SAFETY: `params.Context` points to `ctx_raw` which remains heap-allocated until
        // `Win32SuspendWatcher::drop` unregisters the callback first and then reclaims the Box.
        let status = unsafe {
            PowerRegisterSuspendResumeNotification(
                DEVICE_NOTIFY_CALLBACK,
                (&raw mut params).cast(),
                &raw mut reg_handle,
            )
        };
        if status != 0 || reg_handle.is_null() {
            // SAFETY: Registration failed, so Windows will never invoke the callback; reclaim now.
            unsafe {
                drop(Box::from_raw(ctx_raw));
            }
            return None;
        }

        Some(Self {
            reg_handle: reg_handle as HPOWERNOTIFY,
            ctx_ptr: ctx_raw as usize,
        })
    }
}

impl Drop for Win32SuspendWatcher {
    #[expect(
        unsafe_code,
        reason = "Unregisters Win32 power callback before dropping its heap context."
    )]
    fn drop(&mut self) {
        let handle: HPOWERNOTIFY = self.reg_handle;
        // SAFETY: Unregister completes synchronously before we reclaim the context Box below.
        unsafe {
            if PowerUnregisterSuspendResumeNotification(handle) != 0 {
                tracing::debug!("suspend/resume notification was already unregistered");
            }
            let ctx = self.ctx_ptr as *mut Arc<PowerCoordinator>;
            if !ctx.is_null() {
                drop(Box::from_raw(ctx));
            }
        }
    }
}

#[expect(
    unsafe_code,
    reason = "Extern system callback invoked by Windows Power Manager on suspend/resume."
)]
unsafe extern "system" fn suspend_resume_callback(
    context: *const core::ffi::c_void,
    event_type: u32,
    _setting: *const core::ffi::c_void,
) -> u32 {
    if context.is_null() {
        return 0;
    }
    // SAFETY: `context` is the valid `Box<Arc<PowerCoordinator>>` allocated in `register` and
    // kept alive strictly until `PowerUnregisterSuspendResumeNotification` finishes.
    let coord = unsafe { &*context.cast::<Arc<PowerCoordinator>>() };
    match event_type {
        PBT_APMSUSPEND => coord.notify_system_event(SystemPowerEvent::WillSuspend),
        PBT_APMRESUMEAUTOMATIC | PBT_APMRESUMESUSPEND => {
            coord.notify_system_event(SystemPowerEvent::DidResume);
        }
        _ => {}
    }
    0
}
