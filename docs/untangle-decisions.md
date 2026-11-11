# Untangle decision log

[Before/after architecture](diagrams/refactor-before-after.html).

Scope: whole tracked codebase; comments and tests cleanup included. Baseline: clean `c73fe41`, infrastructure 106 assertions and reset self-test passed. No account credentials, live configuration, or installed app changes are needed.

## Decisions recorded before source changes

- Give Codex authentication, commands, and HTTP their own owners, independent of AppKit.
  - `Sources/main.swift:3032,3780,3827` reads the same registry/auth schema in separate workflows; file naming and identity checks are implicit dependencies.
  - `Sources/main.swift:3474,3668,3713` repeats authenticated request headers and response handling.
  - `Sources/main.swift:1288,1472` duplicates reset confirmation rules between initial verification and follow-ups.
  - `Sources/main.swift:1338,1358` reconstructs every account field twice when applying usage.
  - `Sources/main.swift:3256,3279,3393` retains live-table usage parsing despite using local-only listings.
  - `Sources/main.swift:3580` embeds test fixtures in the production app and `run-tests.sh` can run a stale app binary.
  - `Sources/main.swift:3872-4023` mixes executable discovery, environment construction and desktop process management with UI orchestration; one pinned NVM path hides a machine-specific assumption.
- Separate application composition from preferences, panel presentation, automation, desktop integration and diagnostics.
  - `Sources/main.swift` combines all these independent reasons to change in 4,184 lines.
  - `Sources/main.swift:657,674,686` repeats panel presentation for each tab.
  - `Sources/main.swift:101-238,4130-4174` combines persisted settings/labels with application orchestration.
  - `Sources/main.swift:1816,3126` and `Sources/LifecycleMonitor.swift` share desktop identity by convention.
- Make panel state the source of render invalidation and separate its feature sections.
  - `Sources/main.swift:727` manually repeats the panel constructor's fields and omits direct usage snapshots.
  - `Sources/AccountPanelView.swift:7-143` has a flat state/callback initializer and dormant fields, including unused `toggleLaunchAtLogin`.
  - `Sources/AccountPanelView.swift:1313,1321` and `Sources/main.swift:1798,1902` duplicate ordering and login policies.
  - `Sources/PanelComponents.swift:94` contains an unused edge view and theme token.
  - `Sources/PanelComponents.swift:893` owns network and diagnostic date formatters, making domain parsing depend on UI code.
- Separate Claude models, persistence, Keychain, HTTP and orchestration; centralize token ownership.
  - `Sources/ClaudeAccounts.swift` combines all five responsibilities in 887 lines.
  - `Sources/ClaudeAccounts.swift:87` makes profile decoding depend on store implementation constants.
  - `Sources/ClaudeAccounts.swift:467` and `Sources/ClaudeResetClaim.swift:19` independently decide credential selection and refresh permission.
  - `Sources/ClaudeAccounts.swift:798,849` rebuild every summary field for updates.
- Give shared infrastructure neutral names and one implementation.
  - `Sources/AppInfrastructure.swift:89,97` duplicates refresh TTL logic.
  - `Sources/CodexAuthSupport.swift:41` and `Sources/CursorUsage.swift:106` duplicate JWT payload decoding.
  - `Sources/CodexAuthSupport.swift:103` owns Claude login policy.
  - `Sources/AppInfrastructure.swift:241` names the shared Claude/Codex transport after Codex.
  - Claude usage, Claude resets and Cursor each repeat ISO8601 parsing.
  - `Sources/CursorUsage.swift:77` bypasses the bounded process runner for sqlite.
- Remove retired session efficiency while keeping analytics state version 2 readable.
  - `Sources/AnalyticsSessions.swift`, parser session fields, scanner records, snapshot efficiency and session-only pricing all compute output with no production consumer.
  - Removed Codable keys must remain ignorable; retained cursor fields keep their existing flat names.
- Consolidate analytics data conventions.
  - `Sources/AnalyticsSnapshotBuilder.swift:133` encodes then parses a synthetic string grouping key.
  - `Sources/AnalyticsSnapshotBuilder.swift:117,271` repeats bucket accumulation.
  - `Sources/AnalyticsSnapshotBuilder.swift:196` and `Sources/AnalyticsPanelCharts.swift:8,15` duplicate the heatmap window; model comments incorrectly say 52 weeks.
  - `Sources/AnalyticsPanelFormat.swift:126,138` duplicates model-family classification; `percent` is unused.
  - Codex/Claude cursors and scanner job discovery repeat resume policy; preserve serialized shape while sharing the decision.
- Align build/release/test inputs with the actual artifacts.
  - `package-release.sh` verifies the retired bundle name instead of the bundle `build.sh` emits.
  - Shell scripts repeat app identity and source-set conventions.
  - Useful analytics regressions exist only in ignored local harnesses and are absent from the standard test command.
- Clean comments and tests last.
  - Remove implementation-restating comments; retain external protocol, ownership, arithmetic and compatibility explanations.
  - Consolidate duplicate TTL tests; retain external protocol assertions and promote synthetic analytics/auth/parser regressions.

## Required special cases retained

Provider protocol names and response variants; weekly-only plans; live-token ownership; invalid-grant versus waiting behavior; Keychain update semantics and CLI length limits; transactional rollback; reset POSTs never retried; unknown reset outcomes reuse Claude request IDs; rate-limit backoff; legacy on-disk migrations; off-domain Cursor redirect refusal; Codex/Claude log dedup, fork replay and cumulative counters; corrupt/oversized input rejection; Cursor export history floor; missing repository metadata; DST calendars; saturating arithmetic; metadata cleanup before macOS signing; Space restoration and desktop startup readiness. These follow external systems or preserve existing behavior.

## Acceptance gates

- Every decision above resolved or explicitly justified with evidence.
- Fresh build and standard tests pass; tests use synthetic data and never touch live accounts.
- Pure models/services compile without AppKit; UI rendering verified offscreen after API/layout refactors.
- Existing v2 analytics state and preference keys remain compatible.
- Independent structural/regression audits have no remaining worthwhile actionable findings.
- Final diff contains no credentials or build artifacts.

## Additional findings resolved during implementation

- Codex registry snapshot selection was keyed only by workspace id, which several members can share. Snapshot lookup now follows the registry's account key; a legacy lookup validates both workspace and member. Read-only credentials do not require a refresh token; snapshot copying remains stricter.
- macOS atomic file replacement preserves old metadata by default. Snapshot replacement now uses the new file's owner-only metadata; synthetic rotation checks verify mode `0600`.
- The shared initial/follow-up reset rule retains previously confirmed evidence when a later credit response omits its count.
- Device login depended on an untracked helper under the user's skills directory. It now invokes the app's own desktop restart entry point, reusing the regular restart workflow.
- Claude identity verification is below persistence and usage APIs, removing their dependency cycle. Keychain reads have one implementation.
- Usage-row reset text width is measured, removing the implicit fixed-width assumption for fallback weekday/time strings.
- Analytics resume validation handles truncation inside a discarded oversized record; synthetic regression added.
- Cursor's pure snapshots and menu-bar lane live in `CursorModels.swift`; the render harness no longer compiles networking, credentials or the app delegate.
- Claude grant-id validation belongs to the reset grant model and is shared by parsing and request validation.

## Verification evidence

- `./run-tests.sh`: Infrastructure 102 assertions, Analytics behavioral suite, Provider 38 assertions, Codex 42 assertions; all passed from fresh sources after the final model moves.
- `./package-release.sh`: optimized app and lifecycle helper built; archive extracted and strict deep code-signature verification passed. Archive/checksum remain ignored under `build/`.
- `./scripts/render-panels.sh`: 22 synthetic dark/light cases passed action, state invalidation and size checks. Every mode and error/confirmation/overflow states were visually inspected.
- A same-process adapter comparison against the original panel matched geometry and displayed text for all 22 cases with the same clock, screen and common controls.
- Static-site rapid tab/theme/cancellation behavior passed a fake-DOM timer check; shell syntax and JavaScript syntax checks passed.
- Independent analytics/provider/UI audits completed; every actionable finding was verified and resolved. The repository-required T3 read-only review returned three credential-selection findings; all were reproduced or mutation-tested, then resolved as recorded below.
- `git diff --check` passed; current source/tests/docs contain no retired API references. New data fixtures use synthetic identities; build artifacts remain ignored.

## Required review findings resolved

- Claude usage and reset claims consume one verified credential snapshot. The exact captured live token is paired with its verified owner, while other profiles use captured saved credentials. Raw metadata identity is private and named for metadata; it is used only to verify metadata written during switching. Profile removal uses the same synchronized profile collection and owner result, avoiding a second metadata decision or stale profile list. Saving a rotated backup no longer trusts that metadata either.
- Every reset claim is refused during refresh. A continuation-controlled test reproduces an external A-to-B switch while A is still cached as active and verifies that no reset backend is called.
- Codex live reads validate read-only identity and access-token requirements independently of snapshot-copy requirements. A fresh access-only live token beats an expired saved token and works without a snapshot; incomplete live credentials still cannot overwrite a saved login.
- The refresh-overlap and access-only tests failed on the original paths before their fixes. A separate temporary build substituting metadata ownership for token verification failed all four stale-metadata/unknown-owner assertions as expected. No mutation changes the production source tree, and no regression test accesses live accounts.

## Completion audit

| Requirement | Final ownership and evidence |
| --- | --- |
| Whole-codebase inventory and grouped redesign | Initial decisions above cover app orchestration, provider services, shared infrastructure, panel features, analytics, scripts and the static site. Three independent scoped inventories and subsequent audits were completed. |
| Codex boundaries | `CodexAuthStore`, `CodexCommands`, `CodexClient`, `CodexModels` and `CodexUsageText`; fresh Codex suite passes 42 assertions, including live/saved identity, access-only tokens, snapshot permissions, parsing, reset confirmation and preferences. |
| Claude ownership and serialization | Store returns a verified captured credential snapshot to both usage and claims; refresh blocks every claim; Provider suite passes 38 assertions, including a controlled external-switch sequence. Original ownership mutation is rejected. |
| Panel state and feature ownership | `PanelModels` and separate feature views replace the flat initializer and manual render signature. Final pure-UI render run passes 22 cases; prior same-process old/new geometry and displayed-text comparison matched all cases. |
| Analytics simplification and compatibility | Retired efficiency removed; typed grouping, common resume policy, aggregation and heatmap window. Synthetic suite passes incremental, rewrite/dedup, compaction, fork, v2 persistence, oversized/corrupt input, DST, pricing and arithmetic cases. |
| Shared infrastructure and scripts | One refresh policy, JWT decoder, timestamp parser, HTTP client and bounded process runner. Infrastructure suite passes 102 assertions. Release command builds the app/helper and verifies the extracted signed archive. Shell and site syntax checks pass. |
| Comments and tests | Redundant implementation comments and duplicate TTL tests removed. External-system explanations retained. Production reset fixtures moved into tests; all four suites compile fresh sources. |
| Independent findings | All scoped audit findings and all three required review findings are resolved. Remaining special cases are the external-system requirements listed above. |
| Delivery hygiene | Final whitespace check passes. Synthetic render, mutation and release artifacts remain ignored. Refactor checks used synthetic data and left the installed app and private configuration unchanged. The later explicit install request is recorded below. |

All acceptance gates are satisfied. The final source state passed the four suites and release packaging after the last store adjustment.

## Requested delivery

- Added `docs/diagrams/refactor-before-after.html`: a self-contained Vitesse architecture delta, with explicit ownership groups, stable component identities and a change ledger. Individual provider helpers and shared infrastructure are grouped; external systems, OS integration, scripts and individual tests are outside this overview.
- Built and installed `/Applications/AI Account Switcher.app` at the user's request, stopping the previous app and lifecycle monitor before replacement.
- `verify-install.sh` passed signature and lifecycle checks. The installed executable's SHA-256 matches the fresh build, and a new process was confirmed running from the installed path.
