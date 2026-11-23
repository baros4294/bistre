#!/usr/bin/env bash
# Installs a pinned, checksum-verified actionlint into $HOME/.local/bin (Linux x64 runners).
set -euo pipefail
version="1.7.12"
sha256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
archive="actionlint_${version}_linux_amd64.tar.gz"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${script_dir}/with-download-retry.sh" curl -fsSL \
  "https://github.com/rhysd/actionlint/releases/download/v${version}/${archive}" -o "${tmp_dir}/${archive}"
echo "${sha256}  ${tmp_dir}/${archive}" | sha256sum -c -
mkdir -p "$HOME/.local/bin"
tar -xzf "${tmp_dir}/${archive}" -C "$HOME/.local/bin" actionlint
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
"$HOME/.local/bin/actionlint" -version
