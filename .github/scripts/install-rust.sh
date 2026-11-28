#!/usr/bin/env bash
# Install the pinned Rust toolchain ($RUST_VERSION) and make it the default.
#
# Extra rustup arguments pass through, e.g. `--component rustfmt,clippy` or
# `--target aarch64-linux-android`.
#
# Hosted runners ship rustup. A bare Linux container (the glibc 2.31 release build) does not:
# there a checksum-pinned rustup-init is fetched first.
set -euo pipefail

: "${RUST_VERSION:?RUST_VERSION must be set by the workflow}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v rustup >/dev/null 2>&1; then
  if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
    echo "ERROR: rustup is missing and can only be bootstrapped on Linux x86_64" >&2
    exit 1
  fi
  rustup_version="1.29.3"
  rustup_sha256="b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  bash "${script_dir}/with-download-retry.sh" curl --proto '=https' --tlsv1.2 -fsSL \
    "https://static.rust-lang.org/rustup/archive/${rustup_version}/x86_64-unknown-linux-gnu/rustup-init" \
    -o "${tmp_dir}/rustup-init"
  echo "${rustup_sha256}  ${tmp_dir}/rustup-init" | sha256sum -c -
  chmod 0755 "${tmp_dir}/rustup-init"
  "${tmp_dir}/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
  cargo_bin="${CARGO_HOME:-${HOME}/.cargo}/bin"
  export PATH="${cargo_bin}:${PATH}"
  if [ -n "${GITHUB_PATH:-}" ]; then echo "$cargo_bin" >> "$GITHUB_PATH"; fi
fi

rustup toolchain install "$RUST_VERSION" --profile minimal --no-self-update "$@"
rustup default "$RUST_VERSION"
