# Support and Recovery

TaskScope is currently distributed as source with local-development packaging.
There is no guaranteed support response time and no published production binary
support channel.

## Before requesting help

Record:

- the exact version and build from About TaskScope;
- macOS version and Mac architecture;
- whether the app was source-built, ad-hoc signed, Apple Development-signed, or
  obtained from a published release;
- the failing action and its exact user-visible result;
- whether notification, Accessibility, login-item, or built-in GlobalProtect
  administrator approval was denied.

Sanitize all logs and screenshots. Process names, commands, usernames, app and
plist paths, job labels, ports, and organization details can be sensitive.

Use a GitHub bug report for a reproducible non-security defect. Do not use a
public issue for a vulnerability or private conduct report; follow
[SECURITY.md](SECURITY.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Preview and export support diagnostics

Open **Settings > Support**, choose the preset involved in the failure, and
choose **Preview Diagnostics**. Choose **No preset** for app and permission
information only. The preset picker shows local display names so you can choose
the right entry; those names are not part of the report. A screenshot of the
picker or an ordinary lifecycle report can still expose private information.

The preview shows the complete, read-only JSON snapshot. **Copy JSON** copies
that exact text to the clipboard. **Save JSON…** asks for a destination and writes
one UTF-8 file, named `TaskScope-diagnostics.json` by default, containing exactly
the preview bytes. There are no extra files, logs, hidden fields, or attachments.
Canceling the save dialog writes nothing. **Done** closes the preview without
exporting. Close and generate another preview to refresh its contents; changes
to permissions, presets, or lifecycle history never silently change an open
preview. TaskScope does not send the report anywhere. Share it yourself only
after reviewing it.

Schema version 2 includes exactly these fields. `permissions.notificationsEnabledInApp`
and `selectedPreset.keepOffRequested` are booleans when saved settings are
readable and JSON `null` when settings are unreadable; the keys remain present:

| Field | What you can review and export |
| --- | --- |
| `schemaVersion`, `app` | Report format version and the fixed name `TaskScope`. |
| `version`, `build` | Numeric app version/build from the app bundle, or `unavailable` for absent or nonnumeric metadata. No bundle identifier, signing identity, team identifier, or toolchain paths. |
| `macOS`, `architecture` | Numeric macOS major/minor/patch version and the architecture of the running TaskScope binary (`arm64`, `x86_64`, or `unknown`), which can differ from hardware under translation. |
| `capturedAt` | UTC timestamp when collection completed. Status reads occur over the collection interval, not as an atomic system snapshot. |
| `permissions` | Notification authorization (`unknown`, `notRequested`, `denied`, `allowed`, or `provisional`), the app notification toggle (`notificationsEnabledInApp`: boolean or `null` when settings are unreadable), Accessibility granted boolean, and Launch at Login (`off`, `on`, `requiresApproval`, or `unavailable`). Administrator authorization explicitly says `not queried; requested per privileged action`; it is not a persistent grant or a claim that approval was given. |
| `selectedPreset` | Omitted when no preset is chosen. Otherwise: the report-local reference `selected-preset`, kind (`builtInGlobalProtect` or `custom`), app-bundle found boolean, Keep Off requested value (`keepOffRequested`: boolean or `null` when settings are unreadable), and the user launch-agent entries below. Custom preset names and saved UUIDs are omitted; the reference has meaning only within this report. |
| `selectedPreset.userLaunchAgents` | Each configured user agent's one-based number in preset order, required boolean, plist-found boolean, and current state (`loaded`, `notLoaded`, or `unknown`). An empty array means no user agents are configured. No labels or paths are included. |
| `recentLifecycleFailures` | Newest first, only for the selected preset: UTC event time, action (`open`, `quitApp`, `quitHelpers`, `close`, or `keepOff`), background-enforcement boolean, fixed reason category, failed-job count, and missing-job count. An empty array means no retained failures for that selection. |

Failure reasons are `disconnectFailed`, `appBundleMissing`, `inventoryUnavailable`,
`systemServiceFailed`, `userLaunchAgentFailed`, `launchFailed`, `signalRejected`,
`verificationUnavailable`, `stillRunning`, or the fallback `incomplete`.
`disconnectFailed` means automatic GlobalProtect disconnect could not be verified.
Turning Keep Off off is recorded as `open`; in-app GlobalProtect Quit All and
Stop Services Anyway are recorded as `keepOff`. A custom preset's **Quit All
Killable** button, which result messages call Close, and Stop Watched App are
recorded as `close`.

Counts refer to job results in that action attempt; an early failure can have
zero job failures. They do not contain job labels or raw error details, and
cannot identify a particular organization's managed-service policy.

Collection reads notification, Accessibility, and login-item state without
requesting permission. It checks configured file existence and reads the
selected preset's user launch-agent load status without changing any jobs,
opening apps, signaling processes, requesting administrator access, or reading
the process inventory or logs. Failed, canceled, and timed-out status reads
remain `unknown`. A false file-found value can also mean the path is inaccessible.
Loaded does not guarantee a process is healthy. Keep Off reports TaskScope's
saved intent, not verification of launchd's persistent disable override. When
settings are unreadable, Keep Off and the app notification toggle remain `null`,
even if in-memory fallback values change during the session. No
protected system-daemon inspection is performed by diagnostics.

The session history retains the latest **20 failed lifecycle actions across all
presets**, then filters to the selected preset for export. It includes actions
executed through the UI and automation, and marks background Keep Off
enforcement. Successful actions, skipped enforcement, individual process stops,
auto-stop event history, and failures from earlier app sessions are excluded.
New entries evict the oldest. **Clear Failure History** or quitting TaskScope
clears this in-memory history. Clearing history does not change an existing
preview, clipboard content, or saved file. Delete saved reports yourself and
replace clipboard contents if you want to remove those copies.

There is no unredacted diagnostics mode. Usernames, commands, organization
identifiers, process names/PIDs/full process lists, preset names/UUIDs, app/plist
paths, launch-job labels, raw errors, Unified Logs, preference payloads, and
recovery backups are excluded. Ordinary **Watched Apps > Export** is a separate
preset backup feature and includes configured names and paths; it is not a
privacy-safe support report.

## Permission and installation health

Open **Settings > Health** for one local view of notifications, Accessibility,
Launch at Login, code signing, App Intents/Shortcuts, every saved preset's app
and launch-plist paths, and the running app's bundle identity. **Refresh Health**
repeats the read-only checks. The view also refreshes on opening and when
TaskScope becomes active, including after a visit to System Settings. Changes
to presets or the app notification preference trigger another collection.

Results show when collection began. They become **Stale** after one minute,
when TaskScope becomes inactive, or while a newer collection is pending.
Observations occur over the collection interval, not atomically. A late or
canceled collection cannot overwrite a newer result. Refresh remains available
for every failed or unverified result; it never requests permission.

| State | Meaning and next step |
| --- | --- |
| Verified | The described local check passed. Read its scope: notification authorization does not guarantee delivery, a login registration does not prove login execution, and signature integrity does not establish notarization or Gatekeeper acceptance. |
| Off / Not requested / Requires approval | Respectively, login registration is off, notification authorization has not been requested, or macOS requires login-item approval. These are distinct from denial. |
| Denied | macOS explicitly denies notification authorization. Review Notifications in System Settings. |
| Unavailable | A required service, readable file, metadata artifact, or supported signing mode is unavailable. An unreadable path is not reported as missing. A bare SwiftPM executable cannot provide bundled notification/login-item checks. Login-item `notFound` is Unavailable and alone does not prove a stale registration. |
| Stale | The observation expired, a configured required path is missing, or the on-disk app no longer matches the running instance. Refresh; review the relevant preset or installation before a manual relaunch. |
| Unverified | Evidence is incomplete or cannot establish readiness. Accessibility's false trust value cannot distinguish denial from never-requested access; the view says access is not granted without inventing that distinction. |

Recovery buttons only navigate: **Open System Settings** opens a verified local
System Settings app (follow the pane directions in the row), **Reveal App
Location** asks Finder to show the verified existing bundle location, and
**Review Watched Apps** selects that Settings tab. Unavailable destinations are
omitted. Targets and result freshness are rechecked on click; opening failures
are reported and never treated as a repair. Finder has no completion callback,
so TaskScope reports a navigation request rather than confirmed presentation.
Closing the destination reverses this navigation. Refresh if a target changes.

The health view never resets TCC, registers/unregisters login items, toggles a
permission, edits presets, deletes/moves apps, re-signs or reinstalls software,
loads/unloads jobs, or runs a Shortcut. Use the existing explicit controls or
the source packaging instructions below after reviewing the result.

Signature checks validate local sealed content with network access disabled;
they do not query signing identities in the keychain. Intact ad-hoc signing is
reported as an App Intents blocker. Even a valid non-ad-hoc signature plus the
expected metadata remains **Unverified** for actual Shortcuts discovery and
execution. Bundle identity accepts valid custom identifiers and compares the
running code with disk; it does not scan for duplicate app copies or promise
permission continuity after replacement. A detected replacement marks the
permission/login and App Intents results stale until a new running instance
can be checked.

Preset checks read app metadata/executable presence and configured plist labels,
including the fixed built-in system plist. They never inspect arbitrary system
jobs. Symlinks to regular app metadata, executables, and configured plists are
checked through their targets. Dangling symlinks count as missing paths. Missing
optional user-agent plists are explicitly acceptable; missing required paths
are stale. Malformed files, mismatched labels, non-executable apps, and unsupported/oversized metadata are unverified. A corrupt preset store
is unverified rather than approving its fallback list. Results number presets
and plists in saved order without displaying their raw names, paths, or labels.

Health results remain in memory. They are not added to the frozen, schema-2
Support JSON report described above. Automated tests cover simulated revocation,
replacement, expiry/cancellation, destination failure, metadata validation, and
real temporary path fixtures. Live permission revocation, signed-app replacement,
login/reboot, and Shortcuts execution still require manual testing on each
supported macOS/signing combination; automated evidence does not certify them.

## Common recovery steps

### App will not start or Shortcuts cannot discover actions

1. Run `./script/build_and_run.sh --stage` and then
   `./script/build_and_run.sh --verify` from the source checkout. `--verify`
   checks the bundle that is already staged and does not rebuild it.
2. Verify the installed app, not the bare SwiftPM executable, is being launched.
3. An ad-hoc signature cannot execute TaskScope App Intents. Rebuild with an
   eligible Apple Development identity for local Shortcuts testing.
4. Reinstall using `./script/install.sh`, launch once, and retry Shortcuts.

These steps do not make the app Developer ID-signed or notarized.

### Process information is unavailable

TaskScope relies on local macOS process tools. The Presets section keeps
configured apps visible, shows read errors, and offers Retry. The header shows
Unknown before a successful watched observation and Stale after a later read
failure. The stale banner reports the last successful watched observation,
separately from the process-list update time, and includes the date for
observations before today. If inventory remains unavailable, record the exact
in-app error rather than assuming that no process is running. Extended
network/disk counters can be unavailable independently of the basic process list.

### Activity Monitor opens but does not select the PID

Allow TaskScope in **System Settings > Privacy & Security > Accessibility**, then
retry. If access is intentionally denied, Activity Monitor can still open but
exact selection is unavailable. When exact selection temporarily changes the
Activity Monitor search, process scope, or PID column, TaskScope restores the
prior state after a short handoff delay. A message that access is not granted
can also appear on the first request; it does not mean you denied access. If
TaskScope cannot verify the row's start time and kernel executable path, refresh
the process list and retry from a current row. These identity checks support
visible root-owned and other-user processes too.

### Notifications do not appear

Enable notifications inside TaskScope and allow TaskScope in macOS Notification
settings. If access was denied or revoked, use the Settings recovery link and
retry only after macOS reports permission as allowed. Enabling a watched preset
does not imply global notification authorization. Editing a watched preset's
app path or process-name assignments establishes a new notification baseline;
already-running processes are not announced as newly started.

### Launch at Login needs approval

Inspect the login-item status in Settings > Health, or use Launch at Login in
the Presets section of the main window or menu-bar popover. Requires Approval
also offers **Open Login Item Settings**. Requires Approval and Unavailable
offer **Turn Off Launch at Login**, which attempts removal and shows any error.
During uninstall, remove the registration before deleting the app.

### Stored data is unreadable

TaskScope preserves unreadable payloads under preference keys ending in
`.corruptBackup`, `.corruptBackup.2`, through `.corruptBackup.10`. Malformed Data
payloads retain their original bytes; a present value of the wrong property-list
type is archived as binary property-list data. Affected stores cannot overwrite
primary data until explicit reset. Occupied backup slots are never replaced;
if all ten slots are full, the banner explains that the original remains only
at its primary key. Preserve that value before resetting.

Unreadable preset data, including wrong-type property-list values, publishes
no default watched-app targets in Shortcuts.

Partially decoded or validation-rejected presets, rules, saved selections, and
auto-stop events use a second family: `.rejectedMigrationBackup`, then `.2`
through `.10`. These are complete copies of the original payload and can contain
names, paths, labels, and history. Valid entries remain visible in read-only
recovery; reset commits the recovered entries, not the rejected data. Preset
reset uses the built-in default if no presets remain. Rule reset commits only
safe recovered rules. Selection reset preserves recovered entries and their
unknown fields; recall remains available while mutations are locked. Event
reset commits recovered valid events plus retained session history and resumes
durable logging, within the 200-record limit.

Preserve the exact named backup before any reset. Partial preset recovery
exports only recovered entries and excludes rejected presets; if none are
recoverable, export is refused. Do not export an empty fallback list as a backup.
An intentionally empty, readable preset list can still be exported. Reset does
not remove either backup family. The domain-wide deletion command in
[uninstall](#uninstall-and-erase-local-data) removes both families and all slots.

When saving readable settings after a downgrade, TaskScope preserves unknown
top-level settings and newer schema versions. Unreadable settings require an
explicit reset before the primary payload can be replaced.

Non-dictionary hotkey settings also enter read-only recovery. Settings > Hotkey
shows the backup status and **Reset Hotkey Settings After Backup**. Preserve the
named backup or primary value first; reset enables the default ⌃⌥⌘T shortcut.
The hotkey stays disabled during recovery. Invalid but readable saved shortcuts
migrate to the default with a reason retained until dismissal or successful
shortcut recording.

Legacy name-only Auto Stop rules are retained but disabled. Add and verify the
intended absolute executable path before enabling automatic stopping.

### A watched-app lifecycle partially fails

Read the per-job lifecycle report. Healthy GlobalProtect Open reports no service
restoration and shows no service sheet when all jobs were already enabled and
loaded. User-agent stops verify removal even if bootout returned an error.
A definitive refusal gets one verification read; successful, in-progress, or
uncertain replies retain bounded waits. A final unreadable or still-loaded
state remains a failure. Partial stop messages distinguish observed completion
from an unverified outcome.
Missing app/plist paths and user launch-agent failures apply to custom presets. Administrator denial and managed-service
policy apply only to the immutable built-in GlobalProtect system-service
path. Do not repeat that privileged operation blindly; use the organization's
managed installer or IT support when its protected service cannot be restored.

### GlobalProtect keeps reopening

Turn on **Keep GlobalProtect Off** on the built-in preset, or choose **Quit
All**, which also turns that switch on. Confirm the action, and approve the
macOS administrator dialog if the system VPN service still needs to be
disabled. TaskScope first presses Disconnect and waits for a stable
disconnected state, so this can disconnect the GlobalProtect VPN. A menu-bar
action opens the regular window so its progress and result stay visible.
Choose **Open**, or turn the switch off, to restore the services and app
without reinstalling.

If the action does not finish:

- **Automatic disconnect failed or timed out.** The services keep running and
  the preset offers **Stop Services Anyway…**. After a separate confirmation it
  stops and disables the known services without a verified disconnect. It can
  leave stale VPN DNS settings or interrupt internet access; choose **Open** to
  recover. A new attempt, Open, or an app restart clears the choice.
- **Approval was cancelled or a service is still loaded.** The result reports a
  failure; **Apply Keep Off…** retries. On session-agent installations, a loaded
  or uninspectable separate system daemon is preserved even on retry; consult
  the organization managing the Mac.
- **DNS fails after stopping.** Choose **Open**, leave the VPN disconnected,
  verify normal internet access, and retry Keep Off. TaskScope does not rewrite
  DNS, routes, or vendor settings.
- **Settings are unreadable.** Quit All, Apply Keep Off, the switch, and Stop
  Services Anyway are disabled. Preserve the backup and use
  **Settings > General > Reset Settings After Backup** before changing Keep Off;
  Quit App and Quit Helpers remain available.

If GlobalProtect is stuck retrieving portal configuration after being opened
directly, choose **Open** in TaskScope. It closes a UI that runs without its VPN
service, restores the service, and starts one UI; a healthy running service is
left alone.

[GlobalProtect behavior and recovery](docs/GLOBALPROTECT.md) covers disconnect
timing, which jobs each action changes, session-agent and system-daemon
layouts, the retained system override, background enforcement, and the DNS
observations behind this advice.

### Collect GlobalProtect compatibility evidence

Choose **Compatibility Self-Check** under **Keep GlobalProtect Off** on the
built-in preset, or in **Settings > Watched Apps > GlobalProtect**. The check
runs when opened; **Refresh** collects a new observation. It does not toggle
Keep Off, write preferences, signal processes, load/unload jobs, start the VPN,
or request administrator approval. Normal TaskScope monitoring and any already
enabled Keep Off enforcement continue independently.

The preview includes the capture time, macOS version/build, TaskScope
version/build and process architecture, installed GlobalProtect bundle
version/build, and Keep Off intent. Bare SwiftPM/test executables have no
TaskScope bundle version; record the source revision separately in that case.
For each known `pangpa`, optional `pangps`, and protected system `pangpsd` job,
it shows plist presence/label validation, the launchd disabled override, and
loaded state. Missing files do not imply unloaded jobs or cleared overrides.
**No override** means the plist default applies; it does not mean explicitly
enabled. Read failures, timeouts, and unknown formats remain unknown.

Process counts distinguish the current user, root, other users, and unverified
identity/owner. A name-only match is unverified. The protected service process
is verified only when a root `PanGPS` with a kernel executable path in a known
product directory matches the system job's launchd PID. Loaded is different
from running, and neither proves VPN connectivity or policy compatibility.
Additional/relocated jobs are outside the fixed preset's detection scope.

Review the preview, then choose **Copy Summary** or **Export…**. Both share
exactly that text; export creates a UTF-8 `.txt` file at your chosen location.
The summary omits usernames, numeric UIDs/PIDs, hostnames, executable/home
paths, arguments, unrelated labels, raw command output, and organization/VPN
configuration. It retains the public GlobalProtect job labels and versions
needed to compare installations. Nothing is uploaded automatically. Delete
saved files when no longer needed and replace clipboard contents after sharing.

For a compatibility report, attach the redacted text with the failing action,
expected/actual result, source revision or release, and installation/signing
method. For an authorized managed test machine, collect separate before/after
reports for Keep Off, TaskScope relaunch, login/reboot, and Open/restoration.
Record which actions were actually tested and whether management restored an
agent. Do not publish organization names or VPN addresses. Follow the evidence
matrix and limits in [GLOBALPROTECT_COMPATIBILITY.md](GLOBALPROTECT_COMPATIBILITY.md);
a read-only observation alone is not a successful lifecycle test.

## Export and upgrade precautions

Export readable watched presets before a risky upgrade. The current development
bundle identifier is `com.local.TaskScope`; changing to a production identifier
changes the preferences, permissions, Shortcuts, URL, and login-item identity.
Do not assume local development state migrates until the release explicitly says
that migration was tested.

## Uninstall and erase local data

1. If you ever used **Keep GlobalProtect Off**, GlobalProtect **Quit All**, or
   **Stop Services Anyway**, choose **Open** or turn **Keep GlobalProtect Off**
   off before removing TaskScope; all three set the same launchd overrides. Open
   clears required user overrides and the system override on system-daemon
   layouts, even without saved intent or an installed GlobalProtect app. With
   the GlobalProtect app installed, Open also restores its required service and
   app. On login-session installations it deliberately leaves the separate
   system `pangpsd` override disabled. Whenever one of those actions was used,
   also clear that system override during uninstall, regardless of layout:

   ```bash
   sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd
   ```

   This clears the persistent disable state; it does not bootstrap a service.
   If TaskScope is already gone, clear all three overrides on every layout:

   ```bash
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps
   sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd
   ```

   Deleting preferences does not clear launchd overrides. If policy rejects a
   command or Open reports failure, use the organization's managed support path.

2. Turn off Launch at Login in the Presets section of the main window or
   menu-bar popover. For Requires Approval or Unavailable, choose **Turn Off
   Launch at Login** and resolve any reported error.
3. Quit TaskScope.
4. Delete every copy of the app: the installed `/Applications/TaskScope.app`
   (or `TaskScope.app` in the `DEST_DIR` you installed to) and, in a source
   checkout, `dist/build.noindex/TaskScope.app`. The default
   `./script/build_and_run.sh` run and its `--logs` and `--telemetry` modes open
   that staged copy and leave it registered with Launch Services. Deleting the
   checkout also removes it.
5. If desired, remove TaskScope from **System Settings > Privacy & Security >
   Accessibility** (or run `tccutil reset Accessibility com.local.TaskScope`)
   and turn off its notifications in **System Settings > Notifications**. macOS
   may keep the notification entry after the app is deleted.
6. For the current development identifier only, erase preferences with:

   ```bash
   defaults delete com.local.TaskScope
   ```

7. Optionally delete files you exported (by default `TaskScope-presets.json`,
   `TaskScope-diagnostics.json`, and `TaskScope-GlobalProtect-compatibility.txt`),
   the per-user cache directory
   `"$(getconf DARWIN_USER_CACHE_DIR)com.local.TaskScope"`, and a source
   checkout's `.build` and `dist` directories.

Step 6 is permanent and removes settings, presets, rules, saved
selections, event history, and all `.corruptBackup` and
`.rejectedMigrationBackup` copies, including numbered slots. A production release
with a different identifier requires its own documented deletion command.
