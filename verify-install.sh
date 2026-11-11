#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/app-bundle.sh"
APP="/Applications/$APP_NAME.app"
[[ -d "$APP" ]]
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
/bin/launchctl print "gui/$(/usr/bin/id -u)/$APP_BUNDLE_IDENTIFIER" >/dev/null
/usr/bin/pgrep -f "$APP/Contents/Resources/$MONITOR_EXECUTABLE" >/dev/null
echo "Installed app, ad-hoc signature, and native lifecycle monitor verified."
