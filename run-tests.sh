#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_BUILD_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-account-switcher-tests.XXXXXX")"
trap '/bin/rm -rf "$TEST_BUILD_DIR"' EXIT

PURE_SOURCES=()
for name in AppInfrastructure HTTPClient AuthenticationSupport RefreshPolicy LimitResetWatcher CodexAuthSupport CodexModels CodexUsageText UsageDateFormatters CodexAuthStore CodexClient CodexCommands CodexAuthListTable DesktopApplication AppPreferences; do
  PURE_SOURCES+=("$ROOT_DIR/Sources/$name.swift")
done
for source in "$ROOT_DIR"/Sources/Analytics*.swift; do
  [[ "$(basename "$source")" == AnalyticsPanel* ]] || PURE_SOURCES+=("$source")
done
PURE_SOURCES+=("$ROOT_DIR/Sources/CursorModels.swift" "$ROOT_DIR/Sources/CursorUsage.swift")
for source in "$ROOT_DIR"/Sources/Claude*.swift; do
  PURE_SOURCES+=("$source")
done

for suite in Infrastructure Analytics Provider Codex; do
  test_source="$ROOT_DIR/Tests/${suite}Tests.swift"
  test_binary="$TEST_BUILD_DIR/${suite}Tests"
  /usr/bin/xcrun swiftc "${PURE_SOURCES[@]}" "$test_source" \
    -target arm64-apple-macosx14.0 -o "$test_binary"
  "$test_binary"
done
