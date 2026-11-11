#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/app-bundle.sh"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_PATH="$MACOS_DIR/$APP_EXECUTABLE"
MODULE_CACHE_DIR="${CODEX_SWITCHER_MODULE_CACHE_DIR:-$HOME/Library/Caches/CodexAccountSwitcher/ModuleCache}"
ICON_SOURCE="$ROOT_DIR/Sources/icon.png"
TOOLBAR_ICON_SOURCE="$ROOT_DIR/Sources/toolbar-icon.png"
LIFECYCLE_MONITOR_SOURCE="$ROOT_DIR/Sources/LifecycleMonitor.swift"

rm -rf "$APP_DIR" "$BUILD_DIR/ModuleCache" "$BUILD_DIR/AI Account Switcher 2.app" "$BUILD_DIR/AI Account Switcher 3.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$RESOURCES_DIR/AccountSwitcherIcon.png"
elif [[ -f "/Applications/ChatGPT.app/Contents/Resources/icon.icns" ]]; then
  cp "/Applications/ChatGPT.app/Contents/Resources/icon.icns" "$RESOURCES_DIR/AccountSwitcherIcon.icns"
fi

cp "$ROOT_DIR/Sources/logo-openai.svg" "$ROOT_DIR/Sources/logo-claude.svg" "$ROOT_DIR/Sources/logo-cursor.svg" "$RESOURCES_DIR/"
cp "$ROOT_DIR/Resources/analytics-pricing.json" "$RESOURCES_DIR/"

if [[ -f "$TOOLBAR_ICON_SOURCE" ]]; then
  cp "$TOOLBAR_ICON_SOURCE" "$RESOURCES_DIR/ToolbarIcon.png"
fi

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc "$LIFECYCLE_MONITOR_SOURCE" "$ROOT_DIR/Sources/DesktopApplication.swift" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -o "$RESOURCES_DIR/$MONITOR_EXECUTABLE"

APP_SOURCES=()
for source in "$ROOT_DIR"/Sources/*.swift; do
  [[ "$source" == "$LIFECYCLE_MONITOR_SOURCE" ]] || APP_SOURCES+=("$source")
done

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" swiftc \
  "${APP_SOURCES[@]}" \
  -O \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework UserNotifications \
  -o "$BIN_PATH"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AccountSwitcherIcon.png</string>
  <key>NSUserNotificationUsageDescription</key>
  <string>AI Account Switcher sends low-usage reminders when your active account is near the configured threshold.</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>3.0</string>
  <key>CFBundleVersion</key>
  <string>3000</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

sign_app_bundle "$APP_DIR"

echo "$APP_DIR"
