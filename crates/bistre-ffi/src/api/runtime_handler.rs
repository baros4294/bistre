//! Bounded Tokio runtime and FRB handler configuration (`Spec 11`).
//!
//! FRB's default `SimpleAsyncRuntime` calls `tokio::runtime::Runtime::new()`, which spawns one
//! worker thread per logical CPU core (8+ on modern phones, each reserving a stack and allocator
//! arena). Bistre is a single-user client whose SQLite writes serialize through one dedicated
//! writer thread, so capping workers to 2 on Android and 4 on desktop cuts idle threads and memory
//! with no throughput loss.

use std::panic::AssertUnwindSafe;
use std::sync::LazyLock;

use flutter_rust_bridge::for_generated::SimpleThreadPool;
use flutter_rust_bridge::handler::{NoOpErrorListener, SimpleExecutor};
use flutter_rust_bridge::rust_async::SimpleAsyncRuntime;
use flutter_rust_bridge::DefaultHandler;

/// Worker threads for the embedded Tokio runtime.
const TOKIO_WORKERS: usize = if cfg!(target_os = "android") { 2 } else { 4 };
/// Maximum blocking-pool threads for `off_worker` file and backup work.
const MAX_BLOCKING_THREADS: usize = if cfg!(target_os = "android") { 4 } else { 16 };

fn build_async_runtime() -> SimpleAsyncRuntime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(TOKIO_WORKERS)
        .max_blocking_threads(MAX_BLOCKING_THREADS)
        .thread_name("bistre-rt")
        .enable_all()
        .build()
        .map_or_else(
            |_| SimpleAsyncRuntime::default(),
            |rt| SimpleAsyncRuntime(AssertUnwindSafe(rt)),
        )
}

/// Custom `flutter_rust_bridge` handler picked up automatically by `just codegen-frb`.
pub static FLUTTER_RUST_BRIDGE_HANDLER: LazyLock<DefaultHandler<SimpleThreadPool>> =
    LazyLock::new(|| {
        DefaultHandler::new(
            SimpleExecutor::new(
                NoOpErrorListener,
                SimpleThreadPool::default(),
                build_async_runtime(),
            ),
            NoOpErrorListener,
        )
    });
