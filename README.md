# TaskScope

<img src="docs/images/taskscope-icon.png" alt="TaskScope app icon" width="96" align="right">

TaskScope is a native macOS process monitor and task controller for the window
and menu bar.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://support.apple.com/macos)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/main-window-dark.png">
  <img src="docs/images/main-window-light.png" alt="TaskScope window showing a process list sorted by CPU, with high-usage rows highlighted and two processes selected for a batch stop">
</picture>

Screenshots show synthetic process data and were rendered on macOS 27.

## What it does

Inspect running processes, manage watched apps, and automate local process
rules. TaskScope combines a searchable process list with reviewed stop actions,
saved selections, and a built-in GlobalProtect preset.

This is a source release with local-development packaging. There is no
notarized app download. Read the [limitations](#project-status-and-limitations)
before installing.

## Features

- Search, filter, sort, and explore processes in flat or tree views.
- Review captured targets before Stop or Force Stop, with identity checks before signals.
- Create watched-app presets with Open, Quit App, Quit Helpers, and Quit App
  and Helpers actions; the built-in GlobalProtect preset has Quit All instead.
- Save process selections and preview matches before recalling them.
- Create Prompt, Auto Stop, or Log Only runtime rules and review their event history.
- View CPU and memory history and opt into watched-process notifications.
- Use Shortcuts, a configurable global hotkey, and optional Launch at Login.
- Inspect permissions and installation health, and preview redacted support reports.

## Requirements

- macOS 14 or later is the deployment target; runtime coverage varies by release.
- Xcode 26 or later (full Xcode, not only the Command Line Tools) to build,
  test, and package TaskScope. `Package.swift` declares Swift tools 5.9, but the
  sources need at least Xcode 16 and the macOS 15 SDK to compile.
- Local packaging has been verified on Apple silicon (arm64) only. Scripts build
  the current architecture and do not produce a universal binary.
- An existing, writable install destination; `/Applications` may require
  administrator access.

Packaging uses `TASKSCOPE_CODE_SIGN_IDENTITY` if supplied, otherwise the first
available Apple Development identity, with ad-hoc signing as a fallback. Every
build is signed with the hardened runtime; only `--debug` adds the
`get-task-allow` entitlement that lets LLDB attach. Packaged App Intents need
an eligible development signature to execute locally; ad-hoc builds can
validate metadata but cannot run those intents. Neither is a Developer ID
signature or notarization.

## Build and run from source

```bash
git clone https://github.com/armanruzgar/TaskScope.git
cd TaskScope
./script/build_and_run.sh
```

The script builds a release executable, stages
`dist/build.noindex/TaskScope.app`, and opens it. The first release build can
take several minutes. A separate `swift build -c debug` only checks that the
package compiles; the script does not use its output. The `.noindex` location
avoids a duplicate Spotlight build result. `--stage` and `--verify` unregister
the staged copy from Launch Services; the modes that open it leave it
registered.

```bash
./script/build_and_run.sh --stage       # stage without opening
./script/build_and_run.sh --verify      # verify the staged bundle and launch it for startup verification
./script/build_and_run.sh --debug       # load the debug executable in LLDB; type run to start it
./script/build_and_run.sh --logs        # open the app and stream local process logs
./script/build_and_run.sh --telemetry   # open the app and stream local subsystem logs
```

Every restage, including `--stage`, stops verified running copies of the staged
app before replacement. Before opening or debugging another bundle path, the
scripts check for a running copy with the same identifier and ask you to quit
that copy; the launch check does not stop it. This also applies to `--logs`,
`--telemetry`, and installer launches. If a duplicate same-user, same-identifier
app starts outside the scripts, it requests that the existing instance reopen
its window, including after a quiet login-item launch, and exits before commands
or background enforcement. The existing instance is the copy that holds a
per-user lock file in `~/Library/Application Support/<bundle id>/`, so when two
copies start together exactly one keeps running. A launch while TaskScope is
quitting never hands off to the quitting copy: it starts normally, after waiting
up to about ten seconds if that copy is still finishing an action.

`--telemetry` only displays local macOS Unified Logs; it uploads nothing.
`BUILD_CONFIGURATION=debug` or `release` overrides the build configuration where
applicable, and `TASKSCOPE_OUTPUT_DIR` stages into another absolute directory
instead of `dist/build.noindex`. `./script/build_and_run.sh --help` lists every
mode and environment variable; an unknown or second argument is a usage error.
The app is built from a generated app-only package, so packaging never resolves
the test dependencies or rewrites `Package.resolved`. A bundle staged by an
older version of the script fails `--verify`; stage it again first. Finder and
About use [VERSION](VERSION) and [BUILD_NUMBER](BUILD_NUMBER).

## Install locally and uninstall

```bash
./script/install.sh
```

Before building or changing anything, the installer refuses a destination
`TaskScope.app` that is a file, a symbolic link, or another app, and, unless
you pass `--no-open`, a TaskScope with the same identifier that runs from
another location. It then stages a fresh release build, which can take several
minutes, and quits any TaskScope running from the destination before replacing
it: verified copies get `SIGTERM` and, after about two seconds, `SIGKILL`. It
then opens the new copy. Use `--no-open` to install without launching; if the
installer quit a running TaskScope, start it again yourself. If the new copy is
installed but cannot be opened, the installer warns and still succeeds; if an
upgrade fails after quitting TaskScope, it says that TaskScope was not
restarted. To choose another existing writable directory, use
`DEST_DIR="$PWD/local-apps" ./script/install.sh --no-open` after creating that
directory. Installation checks the staged bundle's Info.plist and App Intents
metadata against the checkout, as staging and releasing do, checks the signature
and identity of each copy, replaces the destination transactionally, and
restores the prior app if replacement fails;
after an interrupted run, such as a power loss, the next install or stage
restores or removes what it left. Export important presets before upgrading;
this rollback does not migrate preferences across incompatible releases.

Before removing TaskScope:

- If you ever used **Keep GlobalProtect Off**, GlobalProtect **Quit All**, or
  **Stop Services Anyway**, choose **Open** on the GlobalProtect preset or turn
  Keep GlobalProtect Off off. This clears the required GlobalProtect launchd
  overrides, even without saved intent or an installed GlobalProtect app; when
  the GlobalProtect app is installed, it also restores its VPN service and app.
  Then clear the separate system-daemon override yourself: session-agent
  installations keep it disabled after Open. If TaskScope is already gone,
  clear all three overrides, on any layout.
- Turn off Launch at Login, then delete every copy of the app, including the
  staged `dist/build.noindex/TaskScope.app` in a source checkout.

Follow the exact commands and deletion steps in [Uninstall and erase local data](SUPPORT.md#uninstall-and-erase-local-data).

If data recovery is active, preserve the named `.corruptBackup` or
`.rejectedMigrationBackup` preference (including numbered slots) before reset or
deletion. See [stored-data recovery](SUPPORT.md#stored-data-is-unreadable).

## Using TaskScope

### Window and menu bar

Use the regular window or menu-bar popover for process review and presets. The
default global shortcut is **Control-Option-Command-T (⌃⌥⌘T)**; change it in
**Settings > Hotkey**. **Help > Welcome to TaskScope** reopens the
introduction. **Launch at Login** is in the **Presets** section of the window
and popover; login launches start quietly in the menu bar, and after such a
launch, closing the last TaskScope window removes the Dock icon again. The
Requires Approval state offers **Turn Off Launch at Login**, and the
Unavailable state, where macOS has no login item for this copy, offers
**Remove Stale Login Item**; both remove the registration and report any error.

### Process list

On a new install the list stays empty until you choose **Load Processes**. With
**Settings > General > Auto-refresh process list** on, it loads and refreshes
by itself; otherwise it is a snapshot that shows when it was updated. See
[first launch](docs/USING_TASKSCOPE.md#first-launch-and-general-settings).
Search names, commands, PIDs, paths, and your own processes' command lines;
filter; and sort by CPU, memory, name, PID, parent PID, user, network, or disk,
in either direction, from the Sort menu or by clicking a column title (click it
again to reverse). The list shows up to 80 rows by default (10 to 200, or **Show all
processes**); a truncated list shows **Showing N of M**. Command-A adds the
displayed matching rows to the selection. Review every captured target before
Stop (`SIGTERM`, with which an app can quit without asking to save changes) or
explicit Force Stop (`SIGKILL`); Stop waits up to three seconds for the process
to exit and never escalates. TaskScope never signals itself, and rechecks
process identity immediately before signaling. Unavailable readings remain
unavailable. See [process actions](docs/USING_TASKSCOPE.md#process-actions-and-observations)
and the [list's keyboard keys](docs/USING_TASKSCOPE.md#keyboard).

### Presets and lifecycle actions

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-bar-presets-dark.png">
  <img src="docs/images/menu-bar-presets-light.png" width="420" alt="Menu bar popover on the Presets tab, showing the running GlobalProtect preset with Open, Quit App, Quit Helpers, and Quit All actions above a quiet Simulator preset">
</picture>

Add, edit, reorder, import, and export presets in **Settings > Watched Apps**.
Import previews every lifecycle field before saving and performs no action.
Custom presets can configure user launch agents, but cannot define privileged
system-daemon jobs. Main/helper detection, the Watched filter, and preset stops
require current-user ownership and the configured bundle boundaries. Quit App,
Quit Helpers, Quit App and Helpers, and GlobalProtect's Quit All and Keep Off
stop the main process first and then all helpers together; each step waits up
to three seconds before force stopping eligible processes, as disclosed in
confirmation. Support diagnostics record Quit App and Helpers as `close`. Read
the [preset guide](docs/USING_TASKSCOPE.md#watched-app-presets) before
importing configuration.

TaskScope reads watched status in the background only while notifications or
Keep GlobalProtect Off are on; otherwise it reads only while a TaskScope window
or the menu-bar popover is open. The stale watched-status banner appears when a
watched-status read fails and reports the last successful watched observation,
independently of the process-list update time, with the date for observations
before today. Stale single-process stops preserve displayed Net/Disk readings.

### Auto-stop rules and saved selections

Create rules in **Settings > Auto-Stop** or with **Create Auto-Stop Rule…** in
a process row's context menu, and save selections from the **Saved** menu above
the list. Start with Prompt or Log Only while checking a rule. Each process
name can have one rule, and Prompt asks in an alert even when no TaskScope
window is open. All three rule actions require current-user ownership and
exclude TaskScope and unsignalable PIDs.
Auto Stop additionally requires a trusted executable path. Saved selections
use executable paths and show a recall preview; a path-backed entry never falls
back to name-only matching. See [rules](docs/USING_TASKSCOPE.md#runtime-rules)
and [saved selections](docs/USING_TASKSCOPE.md#saved-selections) for matching,
retry, migration, and retention details. An unanswered name-only prompt follows
a still-matching process when its executable moves; an explicit Dismiss remains
attached to that lifetime. Editing a rule cancels its unsignalled automatic stop
without recording a failure. Edits that keep Auto Stop enabled and matching
preserve an accepted request's retry budget.

### Shortcuts and URLs

A properly signed, installed app exposes **Refresh TaskScope**, **Get Watched
App Status**, **Open Watched App**, and **Stop Watched App**. Get Watched App
Status is read-only: it returns whether the preset's main app is running, how
many of its helpers are running, whether Keep Off is on, and whether TaskScope
could verify that status, so a shortcut can branch on it. Open and Stop return
the same value when they complete. Stop runs the same stop as a custom preset's
Quit App and Helpers and requires system confirmation, including direct Siri,
Spotlight, and App Shortcut invocation. The confirmation names the app and the
user launch agents it unloads, and says that a process still running three
seconds after the stop request is force stopped. For GlobalProtect, Shortcuts
Stop has user-process scope and does not disconnect or stop VPN services. Cold
intent launches stay in the menu bar without an unintended window or Dock icon.

The packaged URL scheme accepts only the exact URL `taskscope://refresh`, which
refreshes watched-app status. Every other route or spelling is rejected. See
the [automation contract](docs/AUTOMATION.md) for launch, cancellation, and
administrator-approval boundaries.

## GlobalProtect support

The built-in preset's **Quit All** and explicit **Keep Off** attempt a verified
Disconnect before disabling known services. A timeout or unverifiable disconnect
leaves services running; [GlobalProtect behavior](docs/GLOBALPROTECT.md#quit-all-and-explicit-keep-off)
gives the timing. Once the disconnect is verified, Quit All also turns the
**Keep GlobalProtect Off** switch on, so TaskScope keeps GlobalProtect off until
you choose **Open** or turn the switch off.

System-daemon changes require macOS administrator approval. On session-agent
installations, a loaded or uninspectable separate system daemon is preserved,
and the stop is reported as incomplete. **Open** and turning Keep Off off
restore the required service and app; they preserve the unused system override
on session layouts. Background enforcement never requests privileges and leaves
a loaded session VPN service running.

After a failed disconnect, **Stop Services Anyway…** requires separate confirmation
and can disrupt networking or leave stale VPN DNS. **Open** is the recovery path.
TaskScope does not rewrite network settings, store credentials, or bypass management
policy. Read [GlobalProtect behavior and recovery](docs/GLOBALPROTECT.md) and the
[compatibility evidence](GLOBALPROTECT_COMPATIBILITY.md) before use.

## Permissions

- **Accessibility:** exact Activity Monitor selection and explicit GlobalProtect
  disconnect. TaskScope verifies the target identity; ordinary monitoring needs
  no Accessibility access. It never enters VPN credentials or policy responses.
- **Notifications:** off on a new install; requested only after opt-in.
- **Launch at Login:** optional, managed in Presets and macOS Login Items.
- **Administrator approval:** only fixed built-in GlobalProtect daemon operations:
  disable/bootout through explicit Keep Off, Quit All, or Stop Services Anyway;
  enable/bootstrap through Open, toggle-off, or Open Watched App. No URL or
  background enforcement requests privileges; custom presets cannot add them.

See [Privacy permissions](PRIVACY.md#permissions) and the [threat model](THREAT_MODEL.md).

## Privacy

TaskScope runs locally, with no account, analytics, cloud sync, or diagnostic
upload. Preferences and exports can contain process names, paths, and rule data;
notifications and the App Shortcuts that macOS shows in Shortcuts, Spotlight,
and Siri can also reveal process or preset names. **Settings > Support** lets
you preview a redacted report before copying or saving it. Read [PRIVACY.md](PRIVACY.md)
for stored data, retention, permissions, and deletion.

## Development and the quality gate

Follow [CONTRIBUTING.md](CONTRIBUTING.md#development-workflow) for the complete
local build, test, strict-concurrency, compiler-warning, and packaging gate. The
packaging test launches test copies of the app. GitHub Actions runs the build,
test, strict-concurrency, and compiler-warning steps on every push to `main`
and on pull requests; the packaging test and release build run only locally.
Maintainers use [RELEASE.md](RELEASE.md) for release QA, evidence, signing, and
rollback requirements.

## Project status and limitations

- Source and local-development packaging; no notarized download is provided.
- Development bundle identifier: `com.local.TaskScope`. A future identifier
  changes preferences, permissions, Shortcuts, URL registration, and login-item
  identity; no automatic migration should be assumed.
- arm64 packaging is verified; Intel, universal binaries, and every macOS 14+
  runtime combination are not verified.
- GlobalProtect layouts, language, policy, and login/reboot behavior vary. Recorded
  observations from one configuration are not a general compatibility guarantee.
- Public binaries require the complete [release gate](RELEASE.md#additional-gate-for-a-public-binary),
  including candidate-specific lifecycle evidence, real signing credentials,
  notarization, and clean-machine checks. Do not redistribute a staged local app
  as a production download.

See the [roadmap](ROADMAP.md) and [changelog](CHANGELOG.md).

## Contributing, security, and license

Contributions are welcome; read [Contributing](CONTRIBUTING.md) and the
[Code of Conduct](CODE_OF_CONDUCT.md). For help, see [Support](SUPPORT.md).
Report vulnerabilities privately using the [Security policy](SECURITY.md).
TaskScope is available under the [MIT License](LICENSE).

TaskScope is independent. GlobalProtect and Palo Alto Networks are trademarks
of their respective owners; this project is not affiliated with or endorsed by
Palo Alto Networks.
