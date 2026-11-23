#!/usr/bin/env bash
# Install Android platform $ANDROID_COMPILE_SDK, build-tools $ANDROID_BUILD_TOOLS, and NDK
# $ANDROID_NDK_VERSION into the runner's SDK, then export ANDROID_HOME / ANDROID_SDK_ROOT /
# ANDROID_NDK_HOME to later steps. Shared by ci.yml and release.yml so the two cannot drift.
set -euo pipefail

: "${ANDROID_COMPILE_SDK:?}" "${ANDROID_BUILD_TOOLS:?}" "${ANDROID_NDK_VERSION:?}" "${GITHUB_ENV:?}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
sudo mkdir -p "${sdk_root}/ndk" "${sdk_root}/platforms" "${sdk_root}/build-tools" "${sdk_root}/licenses"
sudo chown -R "$(id -u):$(id -g)" "$sdk_root"
# `yes` exits on SIGPIPE once sdkmanager stops reading, which pipefail would report as failure.
set +o pipefail
yes | "$sdkmanager_bin" --sdk_root="$sdk_root" --licenses >/dev/null
set -o pipefail
bash "${script_dir}/with-download-retry.sh" "$sdkmanager_bin" --sdk_root="$sdk_root" --install \
  "platforms;android-${ANDROID_COMPILE_SDK}" \
  "build-tools;${ANDROID_BUILD_TOOLS}" \
  "ndk;${ANDROID_NDK_VERSION}"
ndk_dir="${sdk_root}/ndk/${ANDROID_NDK_VERSION}"
test -d "$ndk_dir"
{
  echo "ANDROID_HOME=${sdk_root}"
  echo "ANDROID_SDK_ROOT=${sdk_root}"
  echo "ANDROID_NDK_HOME=${ndk_dir}"
} >> "$GITHUB_ENV"
