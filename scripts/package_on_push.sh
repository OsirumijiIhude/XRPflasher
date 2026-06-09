#!/usr/bin/env bash
set -euo pipefail

if [ "${SKIP_PACKAGE_ON_PUSH:-}" = "1" ]; then
  echo "Skipping package-on-push because SKIP_PACKAGE_ON_PUSH=1."
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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
export FLUTTER_BIN

"$FLUTTER_BIN" pub get
"$FLUTTER_BIN" test

case "$(uname -s)" in
  Linux*)
    "$FLUTTER_BIN" build linux --release
    "$ROOT/scripts/package_linux_appimage.sh"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    powershell.exe -ExecutionPolicy Bypass -File "$ROOT/scripts/package_windows.ps1"
    ;;
  *)
    echo "Local packaging is not configured for $(uname -s)."
    echo "GitHub Actions will still build Windows and Linux packages after push."
    ;;
esac
