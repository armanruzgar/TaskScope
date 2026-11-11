# Changelog

All notable changes to TaskScope are documented in this file. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added a confirmed, persistent Keep GlobalProtect Off switch to the built-in GlobalProtect preset. It disables and unloads the fixed `pangpa` and optional `pangps` user launch agents and, with macOS administrator approval, disables and boots out the fixed `system/com.paloaltonetworks.gp.pangpsd` VPN daemon; GlobalProtect Quit All and Stop Services Anyway use the same path. Open or turning the switch off restores the services.
- Added Settings > Health with expiring, read-only permission, signing, metadata, path, and bundle-identity checks and navigation-only recovery.
- Added previewable support diagnostics with exact JSON copy/save and at most 20 redacted lifecycle failures retained in memory.
- Added a read-only GlobalProtect Compatibility Self-Check with version, fixed-job, override, ownership, and protected-service observations.
- Added versioned preset archives, bounded reads, legacy-array import, field review, and non-mutating lifecycle previews.

### Changed

- Use diagnostics schema version 2 with `null` for unreadable saved notification and Keep Off settings; document `disconnectFailed` and shipped action mappings.
- GlobalProtect Quit All and explicit Keep Off disconnect before stopping known services, including fixed system disable/bootout with administrator approval where supported.
- Turning Keep Off off performs the same full service and app restoration as Open, preserving the unused system override on session-agent layouts.
- Limit disconnect observation to about 30 seconds (60 observations with 0.5-second waits plus reads), inside a 90-second deadline that also bounds Accessibility requests; timeout leaves services running.
- Offer separately confirmed Stop Services Anyway after disconnect failure, disclosing networking risk and Open recovery.
- Show GlobalProtect full-stop progress and results in the regular window, including actions started from the menu bar.
- Background Keep Off disables both fixed user jobs but unloads only the interface agent; preserved PanGPS does not trigger polling stops or failed background session stops.
- Preserve loaded or uninspectable system daemons on session layouts with an incomplete-stop report and advice that reflects that policy.
- Set the default hotkey to Control-Option-Command-T while retaining supported saved combinations; migrate all invalid saved shortcuts with a persistent reason.
- Show quick-rule executable or name-wide scope and disclose when adding a path enables a disabled name-only Auto Stop rule.
- Preserve unknown JSON fields and newer settings values across saves; disable and lock rules whose unknown fields may narrow their authority.
- Preserve wrong-type preferences as binary property-list backups and partially rejected data in numbered recovery slots until explicit reset.
- Recover valid saved selections and events from mixed arrays; retain unknown selection fields and commit recovered state only after reset.
- Keep configured presets visible before observations and after read failures, with Unknown/Stale status, read errors, and Retry.
- Show truncated flat/tree/search lists as Showing N of M while keeping Select All scoped to displayed matching rows.
- Refuse script launches of a different bundle path while the same identifier is running, including debug/log modes and installer launches.
- Stop verified staged copies before replacement; hold the packaging lock through verification and install copying, then recheck identifier, version, and build.
- Use unique packaging-test preference domains, reject leaked preference files, and remove test domains and plists during cleanup.
- Accept whitespace-only evidence-manifest lines and report CRLF and UTF-8 BOM errors with correction instructions.
- Require candidate-bound lifecycle evidence for public-binary releases and build numbers greater than every existing version tag.
- Keep the complete quality gate local, retain weekly dependency updates, and use a per-checkout strict-build directory.
- Reorganize public documentation, document private reporting, and clarify uninstall cleanup for persistent user and system launchd overrides.
- Ask for menu-bar confirmations in an app-modal alert that brings TaskScope forward; the regular window keeps its in-window dialogs. New lifecycle and batch reports wait until their window is in front, so the Dock icon no longer bounces after GlobalProtect on/off actions.
- Stage the app at `dist/build.noindex/TaskScope.app` instead of `dist/TaskScope.app`, so Spotlight does not index the build; release archives stay in `dist/releases`.

### Fixed

- Allow identity-verified Activity Monitor handoffs for visible root-owned and other-user processes.
- Reopen the existing TaskScope window when rejecting a duplicate launch, including quiet login-item instances.
- Suppress default App Intents watched-app targets when stored preset preferences have an unreadable property-list type.
- Retry shell child reaping after early exit notifications and command stops, including timeouts, so completed commands do not hang lifecycle actions.
- Stop shell output reads at EOF, handle interrupted reads, and preserve cancellation/exit results without leaking running children.
- Use monotonic time including sleep for shared inventory freshness and ordering, and bound Open polling with a monotonic deadline and attempt limit.
- Align watched status, the Watched filter, and preset stops with current-user ownership and main/helper executable-directory boundaries.
- Preserve UTC start evidence and UTF-8 names, parse padded timestamps, and reject incomplete, empty, or duplicate-PID inventories safely.
- Distinguish changed process identities from absent PIDs; executable moves cannot falsely produce Auto Stop Ended/Stopped events or revive dismissed prompts.
- Publish verified inventory after a stale single-process stop, preserve extended Net/Disk readings, and update the displayed-list timestamp only when its backing inventory is replaced.
- Track watched-snapshot freshness separately and include the date for stale observations before today.
- Treat defunct processes without kernel executable paths as already exited across manual, batch, and automatic stops, without signalling them.
- Preserve unanswered name-only prompts after executable moves while keeping explicit dismissals attached to the process lifetime.
- Avoid failure events for automatic stops cancelled before signalling by a rule edit; retain accepted-request retry budgets across edits that keep Auto Stop enabled and matching.
- Report definitive user-agent bootout refusals after one verification read while retaining bounded waits for in-progress or uncertain replies.
- Treat complete GlobalProtect job listings with state but no top-level PID as non-running while retaining unknown attribution for malformed output.
- Strengthen inventory-failure regressions to require unverified targets and the current verification-failure messages.
- Report explicit refresh results when joining silent reads, without treating cancellation or an unrelated prior error as the refresh result.
- Reject queued cancellations without failure diagnostics; finish admitted preset Stops and keep Open readiness cancellable with truthful partial-change messages.
- Verify Quit App, Quit Helpers, and Close against the captured preset even if its stored definition changes or is deleted.
- Verify user-agent removal after nonzero bootout exits; still-loaded or unreadable final states remain failures.
- Recover required GlobalProtect overrides on Open without saved intent or an app bundle, reporting missing-bundle and recovery failures together.
- Report service restoration only for observed changes and suppress the service sheet for healthy unchanged GlobalProtect Open.
- Avoid successful Quit claims when relaunch jobs fail and processes remain running or unverified; partial failures do not claim no signal was sent.
- Block every Keep Off intent writer while settings are unreadable, including Quit All and Stop Services Anyway, with a reset explanation.
- Block built-in preset deletion during queued/running Keep Off and recheck preset existence and writable settings after disconnect before changing intent or services.
- Attribute PanGPS through fixed launchd PID, ownership, and kernel executable path before automatic disconnect and final Keep Off verification.
- Suppress repeated unchanged background Keep Off reports, status replacement, and diagnostics, while reporting user-job and system-verification failures.
- Require five consecutive idle disconnect observations after a Connected observation resets the streak.
- Restore root-running session PanGPS through its installed job, bound readiness/shutdown waits, and retain Keep Off intent after failed user-job restoration.
- Recover orphaned GlobalProtect UI after restoring its service, preserve healthy services, and avoid duplicate UI or force-restarting loaded jobs.
- Keep ordinary GlobalProtect Quit and Shortcuts Stop scoped to interface/user processes; Quit Helpers preserves an agent running the main process.
- Limit Prompt, Auto Stop, and Log Only to current-user processes, excluding TaskScope and unsignalable PIDs, and distinguish safety refusal from kernel refusal.
- Wait a full engine cadence before the single automatic retry and retain handled state and retry budget across still-matching edits, including after signal delivery.
- Preserve delivered stop history across rule edits/removal and require durable Log Only storage before marking an occurrence handled.
- Validate quick watched presets against every selected process's owner, name, and executable directory without fabricating paths for non-bundled tools.
- Preserve rejected event payloads and recovered events plus retained session history when explicitly resetting the event log.
- Refuse preset recovery exports when no valid presets remain and explain exclusions from partial recovery exports.
- Follow Health path symlinks with bounded regular-file reads and classify dangling targets as missing.
- Preserve seven-digit and longer TaskScope build numbers in compatibility reports using a positive-integer validator up to 64 digits.
- Hand off duplicate same-user, same-bundle launches before preference writes, commands, hotkey registration, or background enforcement.
- Isolate startup-verification stores and onboarding in volatile defaults without reading or changing normal preferences.
- Route SIGTERM through normal termination so pending search saves and Activity Monitor restoration can complete.
- Keep entity queries and late intent launches in the background without demoting an already-interactive app; require Stop confirmation through Siri, Spotlight, and App Shortcuts.
- Reschedule history cadence changes without immediate sample bursts, and show the packaged icon in About and onboarding.
- Add Turn Off Launch at Login in Requires Approval and Unavailable states so removal and errors are reachable from Presets.
- Keep refused hotkey recordings separate from registration/conflict status; preserve unknown hotkey fields and disable unreadable hotkeys until explicit reset.
- Verify captured start time and kernel executable path throughout Activity Monitor handoff, and describe Accessibility as not granted without assuming denial.
- Retarget consecutive Activity Monitor handoffs while preserving original table state and respecting later user changes.
- Re-baseline watched notifications after preset identity, path, process-assignment, or notification-setting changes.
- Resolve preset card quit actions against current configuration and render unobserved/stale cards without implying a verified quiet state.
- Disable quick rule/preset creation and stop actions on TaskScope's own row and preserve identity checks during force escalation.
- Request keyboard focus on every tree-row tap, including repeated selected-row taps and recursive children.
- Preserve hidden/search selections across refresh and sort changes, reconcile against full inventory, and bind batch confirmations to captured targets.
- Recall repeated saved executable entries by group count without downgrading path-backed selections to legacy matching.
- Preserve optional preset job requirements, normalize on-disk spelling, exclude main processes from helper lists, and reject ambiguous comma-containing fields.
- Correct prompt target presentation, saved-selection read errors, stale-list recovery, settings-sheet validation, and accessibility labels.
- Judge administrator system-daemon stops by a fixed disable-phase marker and bounded final launchd inspection; report cancelled or denied approval and failed disables after one inspection, and accept a nonzero bootout once the daemon is verified gone.
- Require Prompt, Auto Stop, and Log Only thresholds to be reached on the kernel's monotonic process clock as well as `ps etime`, so a forward wall-clock step cannot make a rule act early.
- Size the process list's Sort and filter pickers to their content so the sort key no longer truncates on macOS 26, and wrap the saved-selection and stop controls onto a second row when the menu bar popover is too narrow for one.
- Keep the stale process-list banner until the list itself reloads; watched-status reads no longer clear it.
- When an automatic launch hides its window, hand activation back only while TaskScope is active, and to the app that was most recently frontmost.
- Let a command that joined a read cancelled midway run its own work instead of treating that read as delivered.
- Clear a pending preset confirmation when that preset is edited.
- Explain why renaming a saved selection that was deleted fails.
- Treat a legacy recall entry whose candidates are all claimed by other entries as unmatched.
- Clear stale Settings errors after a cancelled rule edit, a deletion refusal, or an export after reset, and show when the notification toggle is rejected.
- Look for Activity Monitor's search field in its process-table window.
- Keep an import candidate rejected as a duplicate from reserving its preset ID.
- Name a process whose command is not an absolute path but contains `/` by its leading token, for example `sshd-session` for `sshd-session: user@ttys001`.
- Drop history-chart samples taken before a pause, and keep the Unavailable state across sampling-interval changes.
- Make the packaging scripts always stop the startup-verification child, and refuse to launch while a copy running from the bundle path is an older, replaced build.

### Security

- Bind new Auto Stop rules and durable saved selections to kernel-resolved executable paths, and include that path in the final pre-signal identity check. Legacy name-only Auto Stop rules load disabled for review after an upgrade.
- Make watched-app open and close actions fail closed when a fresh process inventory cannot be read, instead of using cached process state.
- Reject presets that repeat a launch-job label or plist path, in imported and in stored data.

## [1.0.0] - 2026-08-08

First source/development release. Build metadata is `1.0.0 (2)`. This release
does not include a Developer ID-signed, notarized, universal, or public binary.

### Added

- Native macOS process monitoring in flat and process-tree views.
- Watched-app presets with lifecycle controls and per-job result reporting.
- Graceful and forced process termination with target review and identity
  revalidation.
- Saved selections, auto-stop rules, notifications, and bounded process history.
- User-selected Shortcuts actions and a refresh-only URL automation route.
- Source builds, transactional local installation, and packaging verification.
- Maintainer release, rollback, privacy, support, threat-model, and roadmap
  documentation.

### Security

- Restricted untrusted custom-URL automation to the non-destructive refresh
  action; preset open/stop and application quit URLs are rejected.
- Hardened lifecycle configuration validation and shell argument boundaries for
  local launch-job operations.
- Preserved process identity across confirmations and asynchronous work so an
  action cannot silently move to a recycled PID or a different queued prompt.
- Preserved unreadable preference payloads and required explicit reset rather
  than overwriting them with fallback data.

### Fixed

- Report process-inventory and lifecycle failures without claiming that a stop
  succeeded or that a target disappeared when it could not be verified.
- Treat an already-missing launch-agent plist as absent during unload while
  continuing to report it as blocking when restoration requires it.
- Preserve AppleScript newlines in administrator-approved daemon restoration.
- Give the built-in GlobalProtect preset a stable identity so Shortcuts survive
  relaunches.
- Re-baseline watched-process notifications when preset process names or
  notification settings change, avoiding false "started" notifications.
- Re-check auto-stop rules after suspension points and retry actions that were
  never attempted.
- Prevent extended process metrics collection from remaining active after its
  final consumer exits.
- Keep corrupt preset, rule, event, settings, and saved-selection backups from
  being clobbered by later reads.

[Unreleased]: https://github.com/armanruzgar/TaskScope/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/armanruzgar/TaskScope/releases/tag/v1.0.0
