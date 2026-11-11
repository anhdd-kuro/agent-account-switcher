#!/usr/bin/env bash

APP_NAME="AI Account Switcher"
APP_EXECUTABLE="CodexAccountSwitcher"
APP_BUNDLE_IDENTIFIER="com.mohamedfuad.codexaccountswitcher"
MONITOR_EXECUTABLE="CodexLifecycleMonitor"

clear_bundle_metadata() {
  local app_path="$1"
  if command -v xattr >/dev/null 2>&1; then
    /usr/bin/xattr -cr "$app_path"
    /usr/bin/xattr -d com.apple.FinderInfo "$app_path" 2>/dev/null || true
    /usr/bin/xattr -d 'com.apple.fileprovider.fpfs#P' "$app_path" 2>/dev/null || true
  fi
}

sign_app_bundle() {
  local app_path="$1"
  if ! command -v codesign >/dev/null 2>&1; then
    clear_bundle_metadata "$app_path"
    return 0
  fi
  # File-provider metadata can reappear during signing; clear it before each attempt.
  local attempt
  for attempt in 1 2 3 4 5; do
    clear_bundle_metadata "$app_path"
    if /usr/bin/codesign --force --deep --sign - "$app_path" >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "Could not ad-hoc sign the build bundle after five metadata-cleanup attempts." >&2
  return 1
}
