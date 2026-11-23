#!/usr/bin/env bash
# Retry a command only when it failed on a transient download/transport error.
#
# Compile, test, verification, and checksum failures are never retried. Up to 3 retries with
# 10 s / 20 s / 30 s backoff; only the last 2 MB of each attempt's output is kept for classification.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: with-download-retry.sh <command> [args...]" >&2
  exit 64
fi

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

transient='(Connection (reset|refused|timed out)|Could not resolve host|Temporary failure in name resolution|TLS handshake timeout|SocketException|HandshakeException|Failed to download|Read timed out|HTTP(/[0-9.]+)? 5[0-9][0-9]|50[0234] (Bad Gateway|Service Unavailable|Gateway Time-?out|Internal Server Error)|unexpected EOF)'
fatal='(error\[E[0-9]+\]|error: could not compile|test result: FAILED|Some tests failed|checksum|sha256sum: WARNING|signature verification|FAILED:)'

for attempt in 1 2 3 4; do
  set +e
  "$@" 2>&1 | tee "$log_file"
  status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  tail_text="$(tail -c 2000000 "$log_file")"
  if printf '%s' "$tail_text" | grep -Eq "$fatal"; then
    echo "with-download-retry: non-transient failure (exit ${status}); not retrying." >&2
    exit "$status"
  fi
  if [ "$attempt" -eq 4 ] || ! printf '%s' "$tail_text" | grep -Eq "$transient"; then
    exit "$status"
  fi
  delay=$((attempt * 10))
  echo "with-download-retry: transient download error (attempt ${attempt}); retrying in ${delay}s." >&2
  sleep "$delay"
done
