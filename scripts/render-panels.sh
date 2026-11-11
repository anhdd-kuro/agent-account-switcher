#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_BUILD_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/account-switcher-render.XXXXXX")"
trap '/bin/rm -rf "$RENDER_BUILD_DIR"' EXIT
SOURCES=()
for source in "$ROOT_DIR"/Sources/*Panel*.swift; do
  [[ "$(basename "$source")" == AppDelegate* ]] || SOURCES+=("$source")
done
for name in Models AppPreferences CodexModels CodexUsageText UsageDateFormatters ClaudeModels ClaudeResets AuthenticationSupport CursorModels AnalyticsModels AnalyticsSupport; do
  SOURCES+=("$ROOT_DIR/Sources/$name.swift")
done
/usr/bin/xcrun swiftc "${SOURCES[@]}" "$ROOT_DIR/Tests/PanelRendering.swift" \
  -target arm64-apple-macosx14.0 -framework AppKit -framework UserNotifications -o "$RENDER_BUILD_DIR/PanelRendering"
cp "$ROOT_DIR"/Sources/logo-*.svg "$RENDER_BUILD_DIR/"
"$RENDER_BUILD_DIR/PanelRendering" "${1:-$ROOT_DIR/build/panel-render}"
