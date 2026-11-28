#!/usr/bin/env bash
# Install Android platform $ANDROID_COMPILE_SDK, build-tools $ANDROID_BUILD_TOOLS, and NDK
# $ANDROID_NDK_VERSION into the runner's SDK, then export ANDROID_HOME / ANDROID_SDK_ROOT /
# ANDROID_NDK_HOME to later steps. Shared by ci.yml and release.yml so the two cannot drift.
set -euo pipefail

# `--build-tools-only` installs just build-tools (zipalign/apksigner) for the release signing job.
build_tools_only=false
if [ "${1:-}" = "--build-tools-only" ]; then build_tools_only=true; fi
: "${ANDROID_BUILD_TOOLS:?}" "${GITHUB_ENV:?}"
if [ "$build_tools_only" = false ]; then : "${ANDROID_COMPILE_SDK:?}" "${ANDROID_NDK_VERSION:?}"; fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
build_tools_dir="${sdk_root}/build-tools/${ANDROID_BUILD_TOOLS}"

accept_licenses() {
  sudo mkdir -p "${sdk_root}/ndk" "${sdk_root}/platforms" "${sdk_root}/build-tools" "${sdk_root}/licenses"
  sudo chown -R "$(id -u):$(id -g)" "$sdk_root"
  # `yes` exits on SIGPIPE once sdkmanager stops reading, which pipefail would report as failure.
  set +o pipefail
  yes | "$sdkmanager_bin" --sdk_root="$sdk_root" --licenses >/dev/null
  set -o pipefail
}

if [ "$build_tools_only" = true ]; then
  if [ -x "${build_tools_dir}/apksigner" ] && [ -x "${build_tools_dir}/zipalign" ]; then
    echo "Using preinstalled Android build-tools ${ANDROID_BUILD_TOOLS}"
  else
    accept_licenses
    bash "${script_dir}/with-download-retry.sh" "$sdkmanager_bin" --sdk_root="$sdk_root" --install "build-tools;${ANDROID_BUILD_TOOLS}"
  fi
  {
    echo "ANDROID_HOME=${sdk_root}"
    echo "ANDROID_SDK_ROOT=${sdk_root}"
  } >> "$GITHUB_ENV"
  exit 0
fi

platform_dir="${sdk_root}/platforms/android-${ANDROID_COMPILE_SDK}"
ndk_dir="${sdk_root}/ndk/${ANDROID_NDK_VERSION}"
packages=()

if [ -f "${platform_dir}/android.jar" ]; then
  echo "Using existing Android platform android-${ANDROID_COMPILE_SDK}"
else
  packages+=("platforms;android-${ANDROID_COMPILE_SDK}")
fi

if [ -x "${build_tools_dir}/aapt2" ] && [ -x "${build_tools_dir}/zipalign" ]; then
  echo "Using existing Android build-tools ${ANDROID_BUILD_TOOLS}"
else
  packages+=("build-tools;${ANDROID_BUILD_TOOLS}")
fi

# A complete NDK restored from the CI cache carries its package.xml; anything else is reinstalled.
if [ -f "${ndk_dir}/package.xml" ] && [ -f "${ndk_dir}/source.properties" ]; then
  echo "Using the restored NDK ${ANDROID_NDK_VERSION}"
else
  rm -rf "$ndk_dir"
  packages+=("ndk;${ANDROID_NDK_VERSION}")
fi

if [ "${#packages[@]}" -gt 0 ]; then
  accept_licenses
  bash "${script_dir}/with-download-retry.sh" "$sdkmanager_bin" --sdk_root="$sdk_root" --install "${packages[@]}"
fi

test -f "${ndk_dir}/source.properties"
{
  echo "ANDROID_HOME=${sdk_root}"
  echo "ANDROID_SDK_ROOT=${sdk_root}"
  echo "ANDROID_NDK_HOME=${ndk_dir}"
} >> "$GITHUB_ENV"
