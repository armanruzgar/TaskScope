# Privacy

TaskScope is a local macOS utility. It has no TaskScope account, analytics
service, advertising SDK, telemetry upload, cloud synchronization, or automatic
diagnostic upload. It does not transmit process information to a TaskScope
service.

This policy describes the source/development release. If a future updater,
website integration, crash reporter, or other network feature is added, this
document and the in-app disclosure must be updated before that feature ships.

## Data TaskScope reads

TaskScope can read local information exposed by macOS process tools, including:

- PID, parent PID, process owner UID, process/executable name, command path,
  start and elapsed time;
- for the process whose **Show Detail** sheet you open, the owner's account
  name and the full command line (**Command Line**), and for the row whose
  **Copy Command Line** you choose, its command line. A command line can
  contain secrets such as tokens. Command lines are read only on these
  requests, and only while the PID still has the row's start time and
  executable path. They are shown only in that sheet or placed on the
  clipboard, and are never stored, logged, or included in diagnostics,
  reports, exports, or notifications;
- while the process search field has text, the command lines of your own
  listed processes, read in memory once per refresh only to match the search.
  They are never shown (a matching row only carries a mark), stored, logged,
  or included in diagnostics, reports, exports, or notifications, and they are
  dropped with the list they were read for;
- observed CPU and resident memory usage;
- extended per-process network byte counters (from `nettop`) and cumulative
  disk I/O byte counters (from the kernel's per-process resource usage) when
  available;
- configured application and launch-job status;
- macOS notification, Accessibility, and login-item authorization state.

Some values can be unavailable because of macOS permissions or tool behavior.
TaskScope should represent them as unavailable rather than inventing a value.
Watched-read freshness is held in memory, and truncated-result totals are
computed from the local process inventory. These indicators introduce no new
persistent data or transmission.

**Settings > Health** additionally reads local app-bundle metadata, bounded App
Intents metadata, code-signature integrity and running/on-disk code identity,
and configured preset app/executable/plist presence and plist labels. Signature
validation explicitly disables network access and does not enumerate keychain
signing identities. Destination checks locate System Settings and Finder for
optional navigation. The check does not request permissions, change login
registration, run Shortcuts, or modify files, preferences, or launch jobs.

Health observations are kept only in memory, are refreshed on demand and when
the visible view becomes active, and expire after one minute or app inactivity.
They display fixed explanations and numbered preset/plist references rather
than raw paths, labels, signing certificates, or team identifiers. They are not
persisted, copied, uploaded, or included in the separate Support JSON export.
Recovery buttons only open verified local destinations or select Watched Apps;
they do not automatically repair or reset permissions or installation state.

## Data stored on the Mac

TaskScope uses standard macOS preferences for:

- refresh, display, search, sorting, threshold, notification, and the explicit
  Keep GlobalProtect Off preference;
- watched-app presets, including app paths, user launch-agent plist paths and
  labels, process names, and notification choices; the immutable built-in
  GlobalProtect definition also contains its fixed protected-daemon fields;
- saved selections, including process names, executable/command paths, and the
  PID and process start time captured when saved;
- auto-stop rules, including an optional executable path (required for enabled
  automatic stopping) and their run-time, CPU, and memory conditions, and up to
  200 recent event records, which can include process name, PID, time,
  outcome, result detail, and the conditions the rule acted on;
- global hotkey and onboarding state, including a pending hotkey migration
  notice retained until dismissal or successful shortcut recording;
- preserved `.corruptBackup` payloads for unreadable stored data and
  `.rejectedMigrationBackup` payloads for partially rejected presets, rules,
  saved selections, and events. Each family has ten slots: the base suffix,
  then `.2` through `.10`. They can retain full names, paths, labels, and history.
  Malformed Data retains its bytes; wrong-type values are archived as binary
  property lists. A non-dictionary hotkey value is preserved this way and stays
  untouched at its primary key until explicit reset in Settings > Hotkey.
  Recovery disables the hotkey; reset enables the default shortcut.

Preferences are not encrypted by TaskScope. Other software running with the
same user's access may be able to read or modify them.

Startup verification and rejected duplicate launches use fresh volatile defaults
for settings, presets, rules/events, saved selections, and onboarding. These
values are discarded at exit; those launches do not read or update normal stored
values or enforce the stored Keep Off preference.

The running TaskScope also keeps a single-instance lock file,
`~/Library/Application Support/<bundle id>/Instance.lock`, so that it runs once
per user. While TaskScope runs, the file holds its process ID, its start time,
and whether it is quitting. TaskScope empties the file when it quits; after a
crash the last record stays until the next launch replaces it. Startup
verification never creates or reads the file.

Packaging tests use a unique test bundle identifier per run. They reject
startup-verification preference plists in the user's normal or host-specific
preferences directories and remove that test domain and its plists at cleanup.
A temporary `CFFIXED_USER_HOME` alone does not isolate preferences.

The process-history chart keeps at most 60 samples in memory and does not
persist them. Pending prompts, current process inventory, and separate watched
and displayed-list observation timestamps are also transient. Rule edits that
cancel an automatic stop before signalling do not add a failure event. Accepted
requests retain their event history; edits that keep Auto Stop enabled and
matching also retain their retry budget.
Shared inventory cache freshness uses monotonic elapsed time, including sleep;
clock changes do not extend reuse. The Watched filter limits main/helper rows to
the current user's configured bundle boundaries; protected names retain display
classification across users. All continues to show process rows exposed by macOS.
Support diagnostics keep at most 20 recent failed lifecycle actions in memory
across all presets. Entries contain only a local preset UUID for filtering,
time, action/reason categories, a background-enforcement flag, and failed/missing
job counts. Raw job labels and error text are discarded at capture. This
history disappears on app exit or when cleared in Settings > Support.
Cancelled Open and commands cancelled before execution are not retained as
lifecycle failures. An admitted preset Stop completes and retains only actual
failures under the existing policy.

## Exports, notifications, and logs

**Settings > Support > Preview Diagnostics** creates a local, redacted JSON
preview. Only an explicit **Copy JSON** or **Save JSON…** exports its contents;
both use the exact frozen preview. The report contains TaskScope version/build,
numeric macOS version and binary architecture, UTC collection/event timestamps,
permission/login-item status, the app notification toggle and saved Keep Off
intent, anonymous selected-preset identity, file-found booleans, configured
user launch-agent status, and recent lifecycle failure categories/counts for
that preset (including `disconnectFailed`). In schema version 2, the app
notification toggle and Keep Off intent are `null` when persisted settings
are unreadable; unreadable preference contents are not exported. The canonical
built-in preset is identified as GlobalProtect; custom display names and saved preset UUIDs are excluded.

Diagnostics exclude usernames, commands, organization identifiers, process
lists/names/PIDs, raw preset paths, job labels, raw errors, logs, signing/team
identifiers, raw preference payloads, and both recovery-backup families. They do
not request permissions, run lifecycle actions, or upload anything. The picker itself shows
local preset names, so screenshots of it are not redacted. See
[SUPPORT.md](SUPPORT.md#preview-and-export-support-diagnostics) for the exact
field inventory, status limitations, export behavior, and deletion steps.

The GlobalProtect Compatibility Self-Check reads only the known product plists
and version metadata, launchd status, macOS versions, and a fresh basic process
inventory. It does not read VPN configuration or collect extended network/disk
metrics. Its preview, clipboard copy, and text export contain the same selected
fields: capture time, versions/process architecture, Keep Off intent, public
job labels and state, process counts by owner category, and protected-service
verification. Raw output, usernames, numeric UIDs/PIDs, hostnames, executable
paths, arguments, unrelated jobs, and organization/VPN configuration are
omitted. Unexpected metadata is replaced with an unavailable/redacted state.
The report remains in memory until the sheet closes; copying uses the system
clipboard, and exporting writes only to a user-selected destination. Nothing
is uploaded. Delete saved summaries and replace clipboard contents to remove
those copies; TaskScope does not manage their later retention or sharing.

A preset export is created only after the user chooses a destination. It
contains configured preset fields and can reveal organization-specific app
paths, user launch-agent labels and paths, or process names. The immutable
built-in GlobalProtect entry also contains its fixed service fields. Inspect and
sanitize an export before sharing.

TaskScope gives macOS the display name of every valid preset, custom names
included, as the choices for the **Get Watched App Status**, **Open Watched
App**, and **Stop Watched App** App Shortcuts. These names can appear in the
Shortcuts app, Spotlight, and Siri. TaskScope updates them once a launch has
settled and whenever a preset is added, renamed, or deleted. Get Watched App
Status, and a completed Open or Stop, return the chosen preset's name, whether
its main app is running, how many of its helpers are running, whether Keep Off
is on, and whether that status is current, stale, or unknown, to the shortcut,
Siri, or Spotlight request that ran them. They return no process IDs, paths, or
command lines, and TaskScope sends the value nowhere else.

TaskScope writes to the clipboard only when you ask: **Copy JSON** in Support
diagnostics, **Copy Summary** in the GlobalProtect self-check, **Copy Executable
Path** and **Copy Command Line** in a process row's context menu, and **Copy
Report** in a Stop or service results report. Copy Executable Path replaces the
clipboard contents with the process's kernel executable path, or with its `ps`
command name when that path is unavailable. Copy Command Line replaces them
with the process's command line, marked confidential
(`org.nspasteboard.ConcealedType`) so that clipboard-history tools that honor
that marker do not keep it; its status message says only whether it was
copied. Copy Report copies the report as shown, which can include process
names and PIDs or launch-job labels and their results. Text you select in the
Process Detail sheet, including a command line, is copied only by your own
Copy command. TaskScope does not read the clipboard.

When notifications are enabled, process and preset names can appear in
Notification Center, which keeps them even when they arrive while TaskScope is
in front.

TaskScope writes these entries to the macOS Unified Log, under its bundle
identifier as the subsystem (`com.local.TaskScope` for local builds), and keeps
no separate journal:

- in the `Actions` category, a record of every `SIGTERM` or `SIGKILL` it sends,
  with the signal and PID public and the process name private, and of every
  launchd change (`launchctl bootout`, `bootstrap`, `disable`, `enable`,
  `kickstart`, and similar), app `open`, and administrator request it runs,
  with the exit status public and the command line private. Failures are
  logged as errors;
- in the `AutoStop` category, a debug-level line for each auto-stop engine
  pass with the number of processes it read, or that the process list could
  not be read. macOS does not store debug lines by default; they appear while
  they are being streamed;
- for failed handling of `taskscope://` URLs, a fixed message for a malformed
  URL and, logged with private visibility, the error text of a failed refresh
  or a rejected URL. A rejected URL's text repeats the URL's action word;
  refresh failures name no preset or process.

macOS shows private values as `<private>` unless a logging profile on the Mac
reveals them. The `build_and_run.sh --logs` and `--telemetry` modes display
local Unified Logs; `--telemetry` does not upload them.

Never attach an unsanitized process list, command line, preset export, log, or
screenshot to a public issue.

## Permissions

- **Notifications:** requested only after the user opts in. macOS controls
  delivery and stores displayed notifications.
- **Accessibility:** requested for exact PID selection in Activity Monitor.
  TaskScope does not need it for ordinary process monitoring. Handoff identity
  checks read local kernel start-time and executable-path evidence for visible
  processes, including processes owned by other users. To select a row,
  TaskScope may change Activity Monitor's search text, process scope, or PID
  column. After a successful selection it keeps the search and scope that show
  the row and hides a PID column it showed again about four seconds later;
  after a failed one it restores what it changed. For root-owned and other
  users' processes the search text is the executable's file name.
  Explicit GlobalProtect Quit All and Keep Off actions also use Accessibility
  to read the fixed vendor app's connection status and press Disconnect.
  Recognizing a failed connection reads its Connection Failed text and
  Connect/Disconnect controls. These UI reads are not stored or exported;
  credentials and authentication challenges are never filled.
  The vendor app may be brought forward to reveal its status panel. A failed
  disconnect enables a separately confirmed service-stop recovery using a
  one-use random identifier held only in memory; it is not exported or saved.
- **Administrator authorization:** requested to stop, re-enable, or restore the fixed system
  daemon in the immutable built-in GlobalProtect definition. Custom presets
  cannot add privileged daemon jobs, and TaskScope does not store the password.
- **Launch at Login:** optional and controlled in the Presets section of the
  main window and menu-bar popover, and in macOS Login Items. Requires Approval
  and Unavailable states offer **Turn Off Launch at Login** to remove the
  registration.

Keep GlobalProtect Off stores launchd disable overrides for the fixed user-agent
labels and, after explicit administrator approval, the fixed system VPN service.
Turning it off performs the same service and app restoration as Open. Both
preserve the unused system-daemon override when the installed session agent
provides the VPN service. Background enforcement never requests
administrator authorization. Fixed local launchd job PID and kernel executable
path checks attribute VPN services before automatic disconnect and final Keep Off
verification. These observations and duplicate-failure state stay in memory;
no new preferences, credentials, network data, or export fields are introduced.

Revoking a permission in System Settings can limit the related feature without
deleting TaskScope's preferences.

## Retention and deletion

- Auto-stop events retain the newest 200 records. Mixed arrays retain valid
  events and preserve the original payload in a `.rejectedMigrationBackup`
  slot. The store stays read-only until explicit reset commits recovered events
  and retained session history, and resumes durable logging.
- Process chart history retains the newest 60 in-memory samples and disappears
  when the app exits. Changing the cadence reschedules the next sample without
  adding an immediate sample.
- Other preferences remain until changed, reset, or deleted by the user.
- Both recovery-backup families and their numbered slots remain until the
  preferences domain is removed or they are deliberately deleted. Reset does
  not erase them. Wrong-type values use binary property-list archives; partially
  rejected arrays preserve the original payload bytes. These copies stay local
  and are excluded from support diagnostics. Reset commits recovered entries;
  preset reset supplies the built-in default if no presets remain. See
  [recovery details](SUPPORT.md#stored-data-is-unreadable).
- Preset export files remain wherever the user saved them.
- Unified Log entries, including the `Actions` record, age out under macOS's
  own log retention; deleting TaskScope or its preferences does not remove
  them.
- Support diagnostics history retains the latest 20 failures in memory until
  cleared in Settings > Support or the app exits. Saved diagnostics files and
  clipboard copies remain under the user's control; clearing history does not
  erase them or alter an already-open preview.
- Keep GlobalProtect Off overrides live in launchd's user and system databases,
  not TaskScope's preferences. Open can recover required overrides without saved
  intent or the app bundle. Open and toggle-off on login-session installations
  deliberately retain the separate system daemon's disable override. That
  override persists until explicitly enabled; deleting preferences does not
  clear it.

To remove the current development build and its stored data:

1. If you ever used Keep GlobalProtect Off, GlobalProtect Quit All, or Stop
   Services Anyway, choose Open or turn Keep Off off to restore required
   services, then also clear the system override with
   `sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd`, regardless of
   layout. If TaskScope is already gone, run all three enable commands in
   [Support](SUPPORT.md#uninstall-and-erase-local-data), including the system
   command. Resolve reported restoration errors before removing the app.
2. Disable Launch at Login in Presets in the window or menu-bar popover. For
   Requires Approval or Unavailable, choose **Turn Off Launch at Login** and
   resolve any reported error.
3. Quit TaskScope and delete every copy of the app, including
   `dist/build.noindex/TaskScope.app` in a source checkout. Remove its
   Accessibility and notification entries in System Settings if desired.
4. To erase local development preferences, run:

   ```bash
   defaults delete com.local.TaskScope
   ```

The last step permanently removes settings, presets, rules, saved selections,
event history, and all `.corruptBackup` and `.rejectedMigrationBackup` slots.
A future production identifier uses a different preference domain; follow that
release's uninstall instructions.

## Network behavior

TaskScope invokes local macOS tools such as `ps`, `nettop`, `launchctl`, and
`open`. Reading local per-process network counters with `nettop` is not a
network transmission by TaskScope. The current app source contains no TaskScope
network service or update check.

SwiftPM and developer tooling can access dependency hosts while building; that
is build-tool behavior, not runtime app telemetry.

## Security and questions

See [THREAT_MODEL.md](THREAT_MODEL.md) for trust boundaries,
[SECURITY.md](SECURITY.md) for vulnerability reporting, and
[SUPPORT.md](SUPPORT.md) for recovery guidance.
