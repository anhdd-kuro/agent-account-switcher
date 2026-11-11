#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/app-bundle.sh"
APP_PATH="$(/bin/bash "$ROOT_DIR/build.sh")"
DEST_DIR="/Applications"
DEST_APP="$DEST_DIR/$(basename "$APP_PATH")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
cp -R "$APP_PATH" "$DEST_APP"

sign_app_bundle "$DEST_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

"$DEST_APP/Contents/MacOS/$APP_EXECUTABLE" --install-lifecycle-monitor >/dev/null

echo "$DEST_APP"
