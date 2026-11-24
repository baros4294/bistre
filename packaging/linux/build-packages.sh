#!/usr/bin/env bash
# Builds Linux x64 release packages from a staged Flutter + Rust bundle:
#   - bistre-<tag>-linux-x64.tar.gz   (portable archive)
#   - bistre-<tag>-linux-x64.deb      (Debian/Ubuntu package installing to /opt/bistre)
#   - bistre-<tag>-linux-x64.AppImage (self-contained AppImage via checksum-pinned appimagetool 1.9.1)
#
# Usage: bash packaging/linux/build-packages.sh <release_tag> <stage_dir> <dist_dir>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <release_tag> <stage_dir> <dist_dir>" >&2
  exit 2
fi

RELEASE_TAG="$1"
STAGE_DIR="$2"
DIST_DIR="$3"
VERSION="${RELEASE_TAG#v}"
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"

mkdir -p "$DIST_DIR"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# 1. Portable tar.gz archive
tar -czf "${DIST_DIR}/bistre-${RELEASE_TAG}-linux-x64.tar.gz" -C "$STAGE_DIR" .

# 2. Debian/Ubuntu .deb package (installs cleanly under /opt/bistre with /usr/bin/bistre symlink)
deb_root="${work_dir}/deb"
mkdir -p \
  "${deb_root}/DEBIAN" \
  "${deb_root}/opt/bistre" \
  "${deb_root}/usr/bin" \
  "${deb_root}/usr/share/applications" \
  "${deb_root}/usr/share/icons/hicolor/scalable/apps" \
  "${deb_root}/usr/share/icons/hicolor/256x256/apps"

cp -a "${STAGE_DIR}/." "${deb_root}/opt/bistre/"
ln -s /opt/bistre/bistre_app "${deb_root}/usr/bin/bistre"
cp apps/bistre_app/linux/assets/bistre.svg "${deb_root}/usr/share/icons/hicolor/scalable/apps/bistre.svg"
cp apps/bistre_app/linux/assets/bistre.png "${deb_root}/usr/share/icons/hicolor/256x256/apps/bistre.png"

cat > "${deb_root}/usr/share/applications/bistre.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Bistre
Comment=Local-first AI workspace
Exec=/usr/bin/bistre %U
Icon=bistre
Terminal=false
Categories=Utility;Office;Development;
StartupWMClass=bistre_app
DESKTOP

installed_kb="$(du -sk "${deb_root}/opt/bistre" | awk '{print $1}')"
cat > "${deb_root}/DEBIAN/control" <<CONTROL
Package: bistre
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: ${installed_kb}
Depends: libgtk-3-0 | libgtk-3-0t64, liblzma5, libstdc++6
Maintainer: Bistre Contributors <https://github.com/baros4294/bistre>
Homepage: https://github.com/baros4294/bistre
Description: Local-first, zero-telemetry AI workspace
 Bistre is an MIT-licensed, local-first AI client powered by a pure-Rust
 engine and a thin pure-Widgets Flutter UI.
CONTROL

chmod 0755 "${deb_root}/DEBIAN"
dpkg-deb --build --root-owner-group "$deb_root" "${DIST_DIR}/bistre-${RELEASE_TAG}-linux-x64.deb"

# 3. Universal Linux x86_64 AppImage (checksum-pinned appimagetool 1.9.1)
appdir="${work_dir}/Bistre.AppDir"
mkdir -p "${appdir}/usr/bin"
cp -a "${STAGE_DIR}/." "${appdir}/usr/bin/"
cp apps/bistre_app/linux/assets/bistre.png "${appdir}/bistre.png"
cp apps/bistre_app/linux/assets/bistre.png "${appdir}/.DirIcon"

cat > "${appdir}/bistre.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Bistre
Comment=Local-first AI workspace
Exec=bistre_app
Icon=bistre
Terminal=false
Categories=Utility;Office;Development;
StartupWMClass=bistre_app
DESKTOP

cat > "${appdir}/AppRun" <<'APPRUN'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/bin/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
exec "${HERE}/usr/bin/bistre_app" "$@"
APPRUN
chmod 0755 "${appdir}/AppRun"

tool_bin="${work_dir}/appimagetool-x86_64.AppImage"
bash .github/scripts/with-download-retry.sh curl -fsSL \
  "https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/appimagetool-x86_64.AppImage" \
  -o "$tool_bin"
echo "${APPIMAGETOOL_SHA256}  ${tool_bin}" | sha256sum -c -
chmod 0755 "$tool_bin"

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool_bin" --no-appstream \
  "$appdir" "${DIST_DIR}/bistre-${RELEASE_TAG}-linux-x64.AppImage"
chmod 0755 "${DIST_DIR}/bistre-${RELEASE_TAG}-linux-x64.AppImage"
