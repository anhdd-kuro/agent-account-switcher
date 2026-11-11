# AI Account Switcher Project Notes

Terms and ownership: [GLOSSARY.md](GLOSSARY.md).

This project is a sanitized public version of Graham's local Codex Account Switcher menu-bar app.

Rules for future work:

- Do not commit local Codex auth files, account registries, tokens, account IDs, email addresses, or build artifacts.
- Keep `build/`, `.swiftpm/`, `.build/`, and module caches ignored.
- The public toolbar account label must remain generic: use the first alphanumeric character from the email address unless the user sets a custom label in the app.
- Keep switching based on account email queries, not padded numeric selectors such as `01` or `02`.
- The app depends on `codex-auth`; do not vendor or copy private `~/.codex/accounts` data into the repository.
- Build verification is `./build.sh`.
- Install verification is `./install.sh`, then confirm the app runs from `/Applications/AI Account Switcher.app` (renamed in this fork; executable and bundle id unchanged).
- Current app release is v3.0 / build 3000: a full macOS 27 Liquid Glass redesign (AccountPanelView.swift, glass components in PanelComponents.swift, PanelTheme in Models.swift), a performance pass (cached codex-auth path, state-gated panel rebuilds, event-driven relaunch and process waits, ephemeral URLSession), and removal of the retired API mode and hidden legacy menu. It keeps transactional verified switching, rollback, best-account scoring, verified reset-credit redemption, the lifecycle monitor, privacy-safe diagnostics and the non-executing Route B prototype.
- The GitHub Pages site in docs/ and the README artwork are generated from demo-mode captures (CODEX_ACCOUNT_SWITCHER_DEMO=1, CODEX_ACCOUNT_SWITCHER_DEMO_SCENARIO=two|four, CODEX_ACCOUNT_SWITCHER_APPEARANCE=dark|light).

Potential v2.5 idea:

- Consider a separate "Cheap Agent" / Route B mode instead of trying to make a third-party model fully replace Codex Desktop.
- The app could store provider profiles in Keychain and launch a local helper that exposes only a limited, tested tool set: selected MCP calls, simple file/folder checks, Ego Browser or Chrome browser reads/clicks, page scraping, and harmless draft/check workflows.
- Treat each third-party model as capability-tested rather than trusted by default. Show capability states such as chat only, MCP-safe, browser-safe, and live-ops unsafe.
- Require smoke tests before enabling browser or MCP use: open/read a page, perform a harmless click/type, call one selected MCP, process the tool result, and continue coherently.
- Keep native Codex as the fallback and default for public, irreversible, account-sensitive, or upload/send tasks such as Traxsource, Kit, Prime, SoundCloud, Bandcamp, invoices, and account switching.
- Keep all provider keys, local routing files, account emails, and actual auth state out of the public repository.
- The minimal prototype now implements profile selection only. It stores a public profile ID in `UserDefaults`; provider execution, key entry, and tool enablement remain disabled.

Claude fork notes:

- Claude support is split across `ClaudeModels`, `ClaudeKeychain`, `ClaudeAccountStore`, `ClaudeIdentityClient`, `ClaudeAPI`, `ClaudeCLI` and `ClaudeController`; UI lives in `AccountsPanelView.swift`.
- Keychain writes mirror Claude Code: `security -i` with hex on stdin when short, argv otherwise, always `-U`. Never delete-then-add the live item.
- Only replace `claudeAiOauth` in the live item; keep every other key.
- Never refresh the active profile's token; Claude Code owns it.

## Build, install, run

- `./build.sh` compiles every `Sources/*.swift` except `LifecycleMonitor.swift` (built separately) and copies the logos and `Resources/analytics-pricing.json`. A new source file needs no registration; a new resource needs a `cp` line in `build.sh`.
- `./run-tests.sh` compiles and runs the Infrastructure, Analytics, Provider and Codex suites from fresh Foundation-only production sources. Keep domain logic independent of AppKit and update the pure-source list for new domain files.
- Install: quit the running app, replace `/Applications/AI Account Switcher.app`, open it. `open` on an already-running app only activates it, so a stale binary keeps running; always `pkill -f CodexAccountSwitcher` first. After relaunch confirm the process start time.
- If the app runs but has no menu-bar item, kill and relaunch; it has happened once without a code cause.
- When the working tree is unfinished, ship through a clean worktree (`tmp/wt`), then `git update-ref refs/heads/main`, push, remove the worktree.
- Commits are conventional (`feat:`, `fix:`, `docs:`), end with the Co-Authored-By line, and are pushed to the fork's `main`.

## Verifying UI

- Verify UI changes with `./scripts/render-panels.sh`: tracked `Tests/PanelRendering.swift` renders all five modes in dark/light using synthetic data into `build/panel-render`. Inspect the images; a clean build alone does not verify layout. Older ignored `tmp/render*` harnesses may use retired APIs.
- Environment switches for the real app: `CODEX_ACCOUNT_SWITCHER_SHOW_PANEL=1`, `..._SHOW_SETTINGS=1`, `..._DEMO=1`, `..._CELEBRATE=1` (fires the reset toast and confetti once, two seconds after launch).
- A screenshot of the live panel needs the status item clicked; the menu bar has many third-party items, so find ours by its text.

## UI rules (Vitesse dark)

- Colours come from `PanelTheme` in `Models.swift`; never hard-code a colour in a view. Dark panel `#121212`, tiles `#1E1E1E`, accent `#4D9375`, text `#CECABE`.
- Accounts are flat rows (no cards, no circle letters): 22pt header, 18pt usage bars, hairline dividers, a green dot on the active account, inactive rows at 50% alpha (`TileView.restingAlpha`).
- Remaining percent is shown, not used percent. Resets show the largest unit plus hours from one day up: `45m`, `4h`, `3d 4h`.
- Dialogs must go through `NSAlert.runAbovePanel()` or they open behind the menu panel.
- Panel width is `AccountSwitcherPanelView.panelWidth` (452); everything lays out from it.
- A glass/blur background and a Glass opacity slider were tried and reverted at the user's request. Do not reintroduce them unprompted.

## Providers

- **Codex**: accounts come from `codex-auth list --skip-api --json` (`CodexAuthListJSON`; the table is only a fallback for versions without `--json`, and its columns change between versions). codex-auth must stay local-only in the poll: usage is fetched once by the app, never a second time through codex-auth. Usage from `chatgpt.com/backend-api/wham/usage`, with the token from `~/.codex/auth.json` when that file belongs to the account, else its snapshot; a token past its `exp` is not sent. `syncActiveAuthSnapshot` saves `auth.json` over the active account's snapshot only when `AuthSnapshotSync` confirms it is that account's login. `plan_type` from that response decides the 5h window: a plan type containing `pro` (ChatGPT Pro, Business premium "prolite") has no 5-hour limit and shows weekly only. `codex-auth` labels the prolite seat "Business", so the label is not enough.
- **Claude**: `api.anthropic.com/api/oauth/usage`. Every plan shows the 5h window, including Team premium seats. Keep the Keychain rules in "Claude fork notes" above.
- **Claude sign-out rule** (`ClaudeLoginPolicy`, tested): the live token expires after about 8 hours and only Claude Code renews it. An expired or 401-rejected token this app may not refresh is skipped and keeps the last reading with a "waiting" error; "Sign in" is shown only for missing credentials, an `invalid_grant` refresh, or a fresh token that is still rejected.
- **Claude resets** (`ClaudeResets.swift` pure and tested, `ClaudeResetClaim.swift` network): the usage call adds `?cedar_ember=1&skip_spend=1` and Claude Code's headers (`User-Agent: claude-cli/<version> (external, cli)`, `x-app: cli`, version from the `~/.local/share/claude/versions/<x.y.z>` symlink target); without them the server answers `ineligible_reason: "surface"`. `cedar_ember` lists grants with ids; `juniper_tide` is the once-a-week 5-hour reset. Claim is `POST /api/organizations/{org}/reset_rate_limits` with `{program, grant_id, request_id}` (`{program}` only for `juniper_tide`), never retried automatically; a manual retry after an unknown outcome reuses the same `request_id` (`ClaudeController.resetRequestIDs`) so it cannot spend twice. Usage and claims share the credential snapshot returned by `ClaudeAccountStore.synchronize()`: its owner is verified against the captured token or a matching saved login, never inferred from `.claude.json` alone. The live token is never refreshed, and an inactive one refreshes only when the live owner is known and its refresh token differs. Every claim is refused during a refresh or switch, and switches are refused during a claim.
- **Cursor** (`Sources/CursorUsage.swift`): read-only. Token from `cursorAuth/accessToken` in Cursor's `state.vscdb` (via `/usr/bin/sqlite3 -readonly`), user id from `~/.cursor/cli-config.json`, then `cursor.com/api/usage-summary` with the `WorkosCursorSessionToken` cookie. Redirects off cursor.com are refused so the cookie never leaves it. Never log the token or cookie. No switching. Token analytics come from the account usage export (`export-usage-events-csv?strategy=tokens`, `AnalyticsCursor.swift`): the export is authoritative, so Cursor buckets from the earliest exported event on are replaced (the earliest half hour never shrinks), other sources are untouched, and the sync runs at most every 15 minutes inside the analytics scan.
- Menu bar parts per provider: Codex and Claude pick Off, 5-hour, Weekly or Both (two stacked lines); Cursor picks Off, Auto, API or Both (two stacked lines) (default Off). Preferences are plain `UserDefaults` keys (`usageDisplayMode`, `claudeUsageDisplayMode`, `cursorMenuBarLane`, `toastOnReset`, `confettiOnReset`).

## Analytics

- Ported from TokenTracker (MIT, `github.com/xiufengsun/TokenTracker`); keep the credit in `README.md`. The spec we followed is `tmp/analytics-spec.md`.
- Engine files are `Analytics*.swift` (Controller, Scanner, parsers, SnapshotBuilder, Pricing, Projects, State, Support, Zstd); the panel contract is `AnalyticsModels.swift` (`AnalyticsProviding`, `AnalyticsSnapshot`). The UI only talks to the contract.
- State lives in `~/Library/Application Support/AI Account Switcher/analytics/state.plist` (version 2; a version bump forces a full rescan, about 100 s). First scan peaks near 1 GB; incremental scans take 2 to 20 s.
- Tokens are bucketed per UTC half hour keyed `source|model`; files keep inode/offset cursors with head/tail fingerprints; duplicates are removed with hashed sets. `.jsonl.zst` rollouts use the built-in zstd decoder, which must never trap on corrupt input (it was fuzzed with 20,000 corrupt files).
- Numbers differ from TokenTracker on purpose: Claude is about 40% higher because Agent SDK lines are counted, and edit-session counts are higher because TokenTracker's duplicate-id bug is fixed here. Codex matches on most days.
- The tab shows: total tokens with source split, summary tiles, top 5 models, a 6-month activity heatmap, usage trend, daily/projects breakdown. Retired session-efficiency computation and state fields are removed; version-2 stores ignore their old keys without a full rescan.
- Arithmetic on log-derived integers uses saturating helpers; a plain `+` on file data can trap.

## Limit reset celebration

- `LimitResetWatcher` (pure, tested) tracks the lowest remaining percent per window since the last reset and reports a reset when it was at or below 20% and has refilled by 50 points. First observation never fires. `Celebration` shows the toast and confetti as click-through windows anchored under the status item. Both are toggles in Settings > Automation, on by default.

## Review workflow

- Non-trivial changes get a cross-provider read-only review through T3 `delegate_task` (codex, `gpt-6.1-sol`), then every finding is verified before being fixed. Two rounds found integer traps, zstd overflows, unbounded line memory, dedup eviction and stale-period bugs.

## Open items

- T3 Code and Cursor keep using the old Codex account after a switch: their long-running `codex app-server` processes load the account once. Needs a restart strategy the user has not chosen.

## Desktop (Space) restore on relaunch

`restartCodexApp` remembers the Space of the Codex window (`SpaceRestorer`, private CGS calls), switches that display to it while `open` launches the app, then switches back. Setting "Reopen on same desktop" (`reopenOnSameDesktop`, default on) turns it off. macOS blocks moving another process's windows between Spaces (`CGSMoveWindowsToManagedSpace` is a no-op), so switching the visible Space is the only working route.

## Ownership after the refactor

- `main.swift` starts the app. `AppDelegate.swift` owns lifecycle and refresh coordination; `AppDelegate+*.swift` groups the UI workflows by feature.
- `CodexAuthStore` owns registry/snapshot files, `CodexCommands` owns CLI discovery/execution, `CodexClient` owns HTTP/parsing, and `CodexModels` owns usage/reset rules. Percent fields are remaining values.
- `AccountPanelState` is the complete render input and rebuild key; callbacks live in `AccountPanelActions`. Feature views consume that state rather than reading preferences themselves.
- `AppPreferences` owns persisted setting keys and labels. `HTTPClient`, `AuthenticationSupport` and `RefreshPolicy` are shared Foundation infrastructure.
- `DesktopApplication` owns the ChatGPT desktop identity used by both the app and lifecycle monitor. Shell bundle identity and signing are in `scripts/app-bundle.sh`.
- See `docs/untangle-decisions.md` for the refactor's compatibility decisions and validation evidence.
