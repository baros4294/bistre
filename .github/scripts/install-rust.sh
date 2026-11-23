#!/usr/bin/env bash
# Install the pinned Rust toolchain ($RUST_VERSION) and make it the default.
#
# Extra rustup arguments pass through, e.g. `--component rustfmt,clippy` or
# `--target aarch64-linux-android`.
set -euo pipefail

: "${RUST_VERSION:?RUST_VERSION must be set by the workflow}"
rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update "$@"
rustup default "$RUST_VERSION"
