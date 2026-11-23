# ADR-0004: Bundled SQLite WAL Single-Writer Actor & Expand-Contract Migrations

- **Status**: Accepted
- **Date**: 2026-11-21
- **Deciders**: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Production SQLite WAL analyses (Oct–Nov 2026) confirm two dominant embedded failure modes: (a) concurrent write transactions causing `SQLITE_BUSY` errors, and (b) long-lived read transactions starving `PASSIVE` checkpoints so `-wal` grows to gigabytes.
- During Track-B OTA binary updates, a forward-migrated database combined with crash-loop rollback can brick the app if the previous `N-1` binary cannot open the `N` schema.

## Decision
1. Bundle SQLite + FTS5 via `rusqlite 0.43.0` (`features = ["bundled", "modern_sqlite"]`), compiling under NDK r30 so Android inherits 16 KB alignment automatically.
2. Serialize all writes through one dedicated OS thread (`bistre-sqlite-writer`) behind a bounded channel (`cap=256`); open short-lived read-only connections and immediately drop statements.
3. Configure `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`, `journal_size_limit=67108864`, `temp_store=MEMORY`, and run `PRAGMA wal_checkpoint(TRUNCATE)` on clean shutdown and idle windows.
4. Enforce **Expand-Contract additive-only migrations** (`BEGIN IMMEDIATE ... PRAGMA user_version = N; COMMIT;` + `PRAGMA foreign_key_check` + `PRAGMA quick_check`) so `N-1` binaries always read `N` schemas safely. Map `SQLITE_FULL` explicitly to `DiagnosticKey::StorageDiskFull`.

## Rejected Alternatives
- **System libsqlite3**: Inconsistent FTS5 builds and missing 16 KB / modern SQLite features across Linux distros and older Android OEMs.
- **Destructive in-place column drops on upgrade**: Breaks OTA crash-loop rollback.

## Consequences & Verification
- Verified in `crates/bistre-storage` unit tests: 1,000+ UTF-8/Vietnamese/Arabic branched DAG nodes, draft restore across DB reopen, FTS5 latency `<15ms`, and `wal_checkpoint(TRUNCATE)` returning `busy=0`.
