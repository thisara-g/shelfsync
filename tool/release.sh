#!/usr/bin/env bash
# Builds the downloadable release files into dist/:
#   shelfsync_<version>_amd64.deb   Linux package (installs to /opt/shelfsync)
#   shelfsync-<version>.apk         Android APK signed with the release key
#   SHA256SUMS
#
# Usage: tool/release.sh            build only
#        tool/release.sh --publish  build, then create the GitHub release v<version>
#
# Needs config/google_oauth.json (the official OAuth client) and
# android/key.properties (the release signing key). Bump `version:` in
# pubspec.yaml before each release; the part after + must always increase.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
export PATH="$HOME/development/flutter/bin:$PATH"

APP_ID=io.github.thisarag.shelfsync
PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  *) echo "Usage: $0 [--publish]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

[[ -f config/google_oauth.json ]] || die "config/google_oauth.json is missing; release builds would have sync disabled."
[[ -f android/key.properties ]] || die "android/key.properties is missing; the APK would be signed with the debug key."
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes; commit them so the release matches a git tag."

FULL_VERSION="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
VERSION="${FULL_VERSION%%+*}"
TAG="v$VERSION"
echo "Building ShelfSync $VERSION ($FULL_VERSION)"

flutter build linux --release
flutter build apk --release

DIST="$REPO/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# --- .deb -------------------------------------------------------------------
ROOT="$REPO/build/deb/root"
rm -rf "$REPO/build/deb"
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/shelfsync" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
cp -a build/linux/x64/release/bundle/. "$ROOT/opt/shelfsync/"
ln -s /opt/shelfsync/shelfsync "$ROOT/usr/bin/shelfsync"

for px in 48 64 128 256 512; do
  dir="$ROOT/usr/share/icons/hicolor/${px}x${px}/apps"
  mkdir -p "$dir"
  python3 -c "from PIL import Image; import sys; Image.open(sys.argv[1]).resize((int(sys.argv[3]),)*2, Image.LANCZOS).save(sys.argv[2])" \
    assets/icons/shelfsync.png "$dir/$APP_ID.png" "$px"
done

cat > "$ROOT/usr/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ShelfSync
Comment=Read PDFs and keep your place in sync across devices
Exec=shelfsync %f
Icon=$APP_ID
Categories=Office;Viewer;
MimeType=application/pdf;
StartupWMClass=$APP_ID
Terminal=false
EOF

cat > "$ROOT/DEBIAN/control" <<EOF
Package: shelfsync
Version: $VERSION
Architecture: amd64
Maintainer: Thisara Gunawardana <https://github.com/thisara-g/shelfsync/issues>
Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)
Depends: libc6 (>= 2.34), libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libstdc++6
Recommends: xdg-desktop-portal, xdg-desktop-portal-gtk | xdg-desktop-portal-gnome | xdg-desktop-portal-kde, xdg-utils
Section: text
Priority: optional
Homepage: https://thisara-g.github.io/shelfsync/
Description: PDF reader that syncs books and reading position via Google Drive
 ShelfSync keeps your books and your place in them in sync between Linux
 and Android through your own Google Drive. Add a book on one device and it
 appears on the other; resume exactly where you left off. No server and no
 account beyond Google: everything is stored in your own Drive.
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
fi
EOF
cp "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"
sed -i 's/if \[ "$1" = configure \]; then/if [ "$1" = remove ] || [ "$1" = purge ]; then/' "$ROOT/DEBIAN/postrm"
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

DEB="$DIST/shelfsync_${VERSION}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB" >/dev/null

# --- APK --------------------------------------------------------------------
APK="$DIST/shelfsync-$VERSION.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$APK"
APKSIGNER="$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/build-tools/*/ | sort -V | tail -1)apksigner"
SIGNER_SHA1="$("$APKSIGNER" verify --print-certs "$APK" | awk '/certificate SHA-1/{print $NF; exit}')"
DEBUG_SHA1="$(keytool -list -v -keystore ~/.android/debug.keystore -storepass android 2>/dev/null \
  | awk '/SHA1:/{gsub(":", "", $2); print tolower($2); exit}')"
[[ "$SIGNER_SHA1" != "$DEBUG_SHA1" ]] || die "APK is signed with the debug key."

(cd "$DIST" && sha256sum -- *.deb *.apk > SHA256SUMS)

echo
echo "Release files in dist/:"
ls -lh "$DIST" | tail -n +2
echo "APK signer SHA-1: $SIGNER_SHA1"

if (( PUBLISH )); then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "ShelfSync $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "$DEB" "$APK" "$DIST/SHA256SUMS" \
    --title "ShelfSync $VERSION" --notes-file "${RELEASE_NOTES:-/dev/null}" ${PRERELEASE:+--prerelease}
fi
