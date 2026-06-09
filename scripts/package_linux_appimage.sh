#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="xrp_flasher"
FIRMWARE_NAME="xrp-wpilib-firmware-2.1.0-aa439f0.uf2"
if [ -z "${FLUTTER_BIN:-}" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
  elif [ -x "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_BIN="$HOME/flutter/bin/flutter"
  elif [ -x "/home/osi/flutter/bin/flutter" ]; then
    FLUTTER_BIN="/home/osi/flutter/bin/flutter"
  else
    FLUTTER_BIN="flutter"
  fi
fi
DIST_DIR="$ROOT/dist"
BUNDLE_DIR="$ROOT/build/linux/x64/release/bundle"
APPDIR="$DIST_DIR/AppDir"
APPIMAGE="$DIST_DIR/xrp_flasher-linux-x86_64.AppImage"
APPIMAGETOOL="${APPIMAGETOOL:-$DIST_DIR/appimagetool-x86_64.AppImage}"

if [ ! -x "$BUNDLE_DIR/$APP_NAME" ]; then
  "$FLUTTER_BIN" build linux --release
fi

rm -rf "$APPDIR"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps"

cp -R "$BUNDLE_DIR"/. "$APPDIR/usr/bin/"
if [ -f "$FIRMWARE_NAME" ]; then
  cp "$FIRMWARE_NAME" "$APPDIR/usr/bin/$FIRMWARE_NAME"
fi

cp "$ROOT/packaging/xrp_flasher.svg" "$APPDIR/xrp_flasher.svg"
cp "$ROOT/packaging/xrp_flasher.svg" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps/xrp_flasher.svg"

cat > "$APPDIR/xrp_flasher.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=XRP Flasher
Comment=Flash and configure XRP robots
Exec=xrp_flasher
Icon=xrp_flasher
Categories=Utility;Education;
Terminal=false
DESKTOP
cp "$APPDIR/xrp_flasher.desktop" "$APPDIR/usr/share/applications/xrp_flasher.desktop"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$HERE/usr/bin:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/xrp_flasher" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

if [ ! -x "$APPIMAGETOOL" ]; then
  mkdir -p "$DIST_DIR"
  curl -fL \
    -o "$APPIMAGETOOL" \
    "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
  chmod +x "$APPIMAGETOOL"
fi

ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL" "$APPDIR" "$APPIMAGE"
chmod +x "$APPIMAGE"
echo "Created $APPIMAGE"
